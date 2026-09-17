import Foundation
import Observation

/// A set of favourited or "to visit" meetings, keyed by `Meeting.uid`.
///
/// ## Why `uid` and not `Int`
/// `id_bigint` is a per-root-server sequence number. The aggregator merges
/// ~200 root servers, so a bare `Int` key silently aliases one meeting onto an
/// unrelated meeting from another server. This is the single highest-risk
/// correctness issue in the app, and it is why this type keys on String.
///
/// ## Offline rendering
/// We cache the full `Meeting` record on every toggle. Favourites therefore
/// render with zero network access, and a favourite whose server is
/// unreachable still appears with its last-known details.
@MainActor
@Observable
final class MeetingSetStore {

    enum Kind: String {
        case favorites
        case explore

        var fileName: String { "\(rawValue).json" }
        /// The pre-`uid` file name used by MyBMLT-iOS before this rewrite.
        var legacyFileName: String {
            switch self {
            case .favorites: return "favorites_cache.json"
            case .explore: return "visitlist_cache.json"
            }
        }
    }

    private let kind: Kind
    private let store: FileStore
    private let legacyStore: FileStore

    /// Ordered for stable display; membership is what matters.
    private(set) var uids: Set<String> = []
    /// Full records so the tab renders offline.
    private(set) var records: [String: Meeting] = [:]

    /// Behavioural changes detected on the last refresh, keyed by `uid`, that
    /// the user has not yet acknowledged.
    ///
    /// Persisted alongside `records` so a banner survives a relaunch. Without
    /// persistence the notice would vanish on the next launch and the user
    /// would re-save a stale time — the failure the banner exists to prevent.
    private(set) var unseenChanges: [String: Set<Meeting.Change>] = [:]

    /// When saved records were last reconciled against server data.
    ///
    /// Gates the out-of-Area refresh so opening the tab repeatedly does not
    /// re-query. This is the consumer `CachePolicy.meetings` was written for but
    /// never had — see STATUS.md defect 7.
    private(set) var lastVerified: Date?

    /// Meetings observed missing from the server, keyed by `uid`.
    ///
    /// ## Why absence is not proof of deletion
    /// The aggregator filters unpublished meetings server-side — verified 377
    /// SDICR rows and 922 geo rows, every one `published = "1"`. A deleted
    /// meeting therefore does not come back as `published = 0`; it vanishes.
    /// That makes an empty response indistinguishable from:
    ///
    /// 1. a genuinely deleted meeting,
    /// 2. a transient server or query quirk, and
    /// 3. a wrong `root_server_ids[]` — i.e. our own bug, which would blame the
    ///    user's meeting for our mistake.
    ///
    /// So this map records **evidence, not verdicts**. A `uid` earns a place
    /// only after two independent confirmations (see `recordMissing`), and the
    /// banner says the meeting is no longer listed rather than asserting a
    /// deletion we cannot observe.
    ///
    /// The record itself is never removed. The user decides.
    private(set) var missingSince: [String: Date] = [:]

    /// How many consecutive clean observations are required before a missing
    /// meeting is surfaced. Two, so a single failed or racing fetch cannot
    /// raise a false "deleted" banner on a live meeting.
    static let missingConfirmationsRequired = 2

    /// Batch size at or above which an all-absent response is refused as a
    /// probable query error rather than a mass deletion.
    ///
    /// Below this threshold the all-absent case is ordinary and must be
    /// recorded: a user with one favourite whose meeting was deleted genuinely
    /// produces `requested = [x], returned = []`. Refusing every all-absent
    /// batch would silence exactly that user — which the tests caught. At or
    /// above the threshold, "everything vanished at once" is overwhelmingly
    /// more likely to be a wrong `root_server_ids[]` than a real mass deletion.
    static let massAbsenceThreshold = 4

    /// Absences seen so far, including the first. Kept separately from
    /// `missingSince` so an unconfirmed single absence is not displayed.
    private var missingObservations: [String: Int] = [:]

    /// True when a scoped re-fetch is worth doing: something is saved, and the
    /// last reconciliation is older than the meeting TTL (or never happened).
    var needsVerification: Bool {
        guard !uids.isEmpty else { return false }
        return !CachePolicy.isFresh(lastVerified, within: CachePolicy.meetings)
    }

    private struct Payload: Codable {
        var uids: [String]
        var records: [String: Meeting]
        /// Optional so files written before this field existed still decode.
        /// A missing value means "no pending notices", which is the correct
        /// reading for an upgrade: the pre-banner app had recorded nothing to
        /// notify about.
        var unseenChanges: [String: Set<Meeting.Change>]?
        /// Optional for the same reason. Missing reads as "never verified",
        /// which correctly triggers one refresh on first launch after upgrade.
        var lastVerified: Date?
        /// Optional for the same reason.
        var missingObservations: [String: Int]?
        var missingSince: [String: Date]?
    }

    init(kind: Kind,
         store: FileStore = FileStore(),
         legacyStore: FileStore = FileStore(subdirectory: nil)) {
        self.kind = kind
        self.store = store
        self.legacyStore = legacyStore
        load()
    }
    // MARK: - Queries

    func contains(_ meeting: Meeting) -> Bool { uids.contains(meeting.uid) }

    var all: [Meeting] {
        uids.compactMap { records[$0] }
            .sorted {
                if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
                return $0.startTime < $1.startTime
            }
    }

    var count: Int { uids.count }

    // MARK: - Mutation

    func toggle(_ meeting: Meeting) {
        if uids.contains(meeting.uid) {
            uids.remove(meeting.uid)
            records.removeValue(forKey: meeting.uid)
            unseenChanges.removeValue(forKey: meeting.uid)
            missingSince.removeValue(forKey: meeting.uid)
            missingObservations.removeValue(forKey: meeting.uid)
        } else {
            uids.insert(meeting.uid)
            records[meeting.uid] = meeting
            // A freshly saved meeting is by definition current, so any notice
            // left over from a previous tenure of the same uid is stale.
            unseenChanges.removeValue(forKey: meeting.uid)
            missingSince.removeValue(forKey: meeting.uid)
            missingObservations.removeValue(forKey: meeting.uid)
        }
        save()
    }

    /// Refreshes cached records with newer server data without changing
    /// membership. Called after a successful fetch so stale details heal.
    ///
    /// Field-aware on purpose: a record whose only differences are cosmetic is
    /// overwritten silently, and only the three behavioural `Meeting.Change`
    /// cases raise a notice. See `Meeting.changes(from:)`.
    func updateRecords(from meetings: [Meeting]) {
        var changed = false

        for meeting in meetings where uids.contains(meeting.uid) {
            guard let existing = records[meeting.uid] else { continue }

            // Already identical — the common case, and free to skip.
            if existing == meeting { continue }

            let detected = meeting.changes(from: existing)
            records[meeting.uid] = meeting
            changed = true

            if detected.isEmpty {
                // Cosmetic churn only: heal the record, stay silent.
                continue
            }

            // Union rather than replace. Two refreshes inside one unacknowledged
            // window (e.g. pull-to-refresh then an Area switch) must not lose
            // the earlier notice.
            unseenChanges[meeting.uid, default: []].formUnion(detected)
        }

        if changed { save() }
    }

    // MARK: - Change notices

    /// Applies records fetched specifically for saved meetings that fall outside
    /// the active Area, then marks the list verified.
    ///
    /// Separate from `updateRecords(from:)` only in intent: this is the scoped
    /// out-of-Area path, so it also advances `lastVerified`. Goes through the
    /// same field-aware diff, so a scoped fetch raises exactly the same notices.
    func applyVerified(_ meetings: [Meeting]) {
        updateRecords(from: meetings)
        markVerified()
    }

    /// Unacknowledged behavioural changes for a meeting, newest detection
    /// first by severity. Empty when there is nothing to tell the user.
    func pendingChanges(for meeting: Meeting) -> [Meeting.Change] {
        (unseenChanges[meeting.uid] ?? []).sorted { $0.rank < $1.rank }
    }

    /// Marks a meeting's notice as read. Called when the user dismisses the
    /// banner, so it does not reappear on every subsequent fetch.
    func acknowledgeChanges(for meeting: Meeting) {
        guard unseenChanges.removeValue(forKey: meeting.uid) != nil else { return }
        save()
    }

    /// True when any list holds an unacknowledged notice — used to badge the
    /// Favorites tab so a change is discoverable without opening the meeting.
    var hasUnseenChanges: Bool { !unseenChanges.isEmpty }

    /// Number of unacknowledged behavioural changes across saved meetings.
    ///
    /// Counts changes, not meetings: one meeting that both moved and changed
    /// time is two facts the user has to act on.
    var unseenChangeCount: Int {
        unseenChanges.values.reduce(0) { $0 + $1.count }
    }

    /// Unacknowledged change count, excluding meetings in `uids`.
    ///
    /// Used by the tab badge so a deleted meeting counts once instead of twice
    /// when its cached details also happen to differ from the last record the
    /// server sent.
    func unseenChangeCountExcluding(_ excluded: Set<String>) -> Int {
        unseenChanges.reduce(0) { total, entry in
            excluded.contains(entry.key) ? total : total + entry.value.count
        }
    }

    /// Changes awaiting acknowledgement for a `uid`, for row decoration.
    func pendingChanges(for uid: String) -> [Meeting.Change] {
        (unseenChanges[uid] ?? []).sorted { $0.rank < $1.rank }
    }

    // MARK: - Verification

    /// Saved meetings that are **not** in `knownUIDs`, grouped ready for a
    /// scoped fetch.
    ///
    /// These are the ones `updateRecords(from:)` cannot heal, because the
    /// meetings currently in memory (the active Area's subtree) do not contain
    /// them. Returns `nil` when there is nothing to fetch, so callers can skip
    /// the request entirely.
    ///
    /// Grouped by root server and returned as `id`s because the aggregator
    /// needs `root_server_ids[]` to disambiguate — see
    /// `AggregatorClient.Query.meetingIDs`. An unscoped id silently resolves
    /// against the wrong server.
    func unverifiedIDs(notIn knownUIDs: Set<String>) -> [Int: [Int]]? {
        var byRoot: [Int: [Int]] = [:]
        for uid in uids where !knownUIDs.contains(uid) {
            guard let meeting = records[uid] else { continue }
            byRoot[meeting.rootServerID, default: []].append(meeting.id)
        }
        return byRoot.isEmpty ? nil : byRoot
    }

    /// Marks records as reconciled with the server.
    ///
    /// Called after a verification attempt regardless of outcome. A failed
    /// fetch must still update the clock, or a user with no connectivity would
    /// retry on every tab appearance.
    func markVerified(at date: Date = Date()) {
        lastVerified = date
        save()
    }

    // MARK: - Missing meetings

    /// Records a clean, scoped fetch in which every id in `requested` was
    /// looked up, and `returned` is what came back.
    ///
    /// Call this **only** when the request genuinely succeeded. A network or
    /// decode failure must call `markVerified()` alone, because a failed fetch
    /// is not evidence of deletion — and treating it as such would banner every
    /// favourite the moment the user goes offline.
    ///
    /// - Parameters:
    ///   - requested: uids covered by this successful fetch.
    ///   - returned: uids the server actually sent back.
    ///   - date: when the observation was made, for the "first noticed" line.
    func recordObservations(requested: Set<String>, returned: Set<String>, at date: Date = Date()) {
        let absent = requested.subtracting(returned)

        // Systematic-failure guard. If a whole *large* batch came back empty we
        // cannot tell "everything was deleted" from "the query was wrong", and
        // the second is overwhelmingly more likely. Refuse to record it.
        //
        // The threshold matters: a user with one or two favourites whose
        // meetings were deleted produces a legitimately all-absent batch, so
        // small batches are always recorded.
        guard !requested.isEmpty else { return }
        if requested.count >= Self.massAbsenceThreshold, absent.count == requested.count {
            return
        }

        for uid in requested {
            if returned.contains(uid) {
                // Seen: clear any prior evidence, including a confirmed banner.
                // This is the self-healing path that makes a false positive
                // recoverable without user action.
                missingObservations.removeValue(forKey: uid)
                missingSince.removeValue(forKey: uid)
            } else {
                let count = (missingObservations[uid] ?? 0) + 1
                missingObservations[uid] = count
                if count >= Self.missingConfirmationsRequired, missingSince[uid] == nil {
                    missingSince[uid] = date
                }
            }
        }
        save()
    }

    /// Confirmed-missing meetings, safe to surface.
    var confirmedMissingUIDs: Set<String> {
        Set(missingSince.keys).intersection(uids)
    }

    func isMissing(_ meeting: Meeting) -> Bool {
        missingSince[meeting.uid] != nil && uids.contains(meeting.uid)
    }

    /// When the absence was first confirmed, for the banner's wording.
    func missingFirstNoticed(_ meeting: Meeting) -> Date? {
        missingSince[meeting.uid]
    }

    var missingCount: Int { confirmedMissingUIDs.count }

    // MARK: - Persistence

    private func save() {
        store.write(
            Payload(uids: Array(uids),
                    records: records,
                    unseenChanges: unseenChanges,
                    lastVerified: lastVerified,
                    missingObservations: missingObservations,
                    missingSince: missingSince),
            to: kind.fileName
        )
    }

    private func load() {
        if let payload = store.read(Payload.self, from: kind.fileName) {
            uids = Set(payload.uids)
            records = payload.records
            unseenChanges = payload.unseenChanges ?? [:]
            lastVerified = payload.lastVerified
            missingObservations = payload.missingObservations ?? [:]
            missingSince = payload.missingSince ?? [:]
            // Drop notices for meetings no longer on the list, so an
            // unstar/restar cycle cannot resurrect an old banner.
            unseenChanges = unseenChanges.filter { uids.contains($0.key) }
            missingSince = missingSince.filter { uids.contains($0.key) }
            missingObservations = missingObservations.filter { uids.contains($0.key) }
            return
        }
        migrateLegacyIfPresent()
    }

    /// One-time migration from the pre-`uid` format, which stored a bare
    /// `[Int]` of IDs.
    ///
    /// Those IDs are ambiguous: they carry no root server. Verified against a
    /// real legacy cache — the pre-rewrite app stored `serviceBodyId` values in
    /// the 1155–1165 range (bmlt.wszf.org numbering) and no `rootServerID` at
    /// all. So we cannot infer the root server from disk; we must match against
    /// meetings fetched from the aggregator, where the same meetings appear
    /// under different IDs entirely (SDICR is 2313/2314–2322 there).
    ///
    /// Because the numbering differs across servers, ID-based matching would
    /// never succeed. Matching therefore happens by **meeting name + weekday +
    /// start time**, which is what actually survives a server change. See
    /// `resolveLegacy(against:)`.
    private func migrateLegacyIfPresent() {
        guard let legacyIDs = legacyStore.read([Int].self, from: kind.legacyFileName) else { return }
        pendingLegacyIDs = Set(legacyIDs)
        #if DEBUG
        print("[MeetingSetStore] \(kind.rawValue): \(legacyIDs.count) legacy IDs awaiting resolution")
        #endif
    }

    /// Legacy IDs still awaiting a match against server data.
    private(set) var pendingLegacyIDs: Set<Int> = []

    /// Maps legacy bare IDs onto loaded meetings.
    ///
    /// The legacy `[Int]` values are `id_bigint`s from bmlt.wszf.org. Those IDs
    /// do not exist on the aggregator (wszf numbers SDICR 1155, the aggregator
    /// numbers it 2313, and individual meeting IDs differ too), so ID matching
    /// alone will usually find nothing. We therefore also match on a content
    /// fingerprint — normalized name + weekday + start time — which is what
    /// actually survives a server change.
    ///
    /// If the caller can supply the legacy records, fingerprints beat IDs. See
    /// `resolveLegacy(legacyMeetings:against:)`.
    func resolveLegacy(against meetings: [Meeting]) {
        guard !pendingLegacyIDs.isEmpty else { return }

        let byID = Dictionary(grouping: meetings, by: \.id)
        var migrated = 0

        for legacyID in pendingLegacyIDs {
            // Only accept an unambiguous match. If two root servers both claim
            // this ID we cannot know which the user meant, so we drop it.
            guard let candidates = byID[legacyID], candidates.count == 1,
                  let meeting = candidates.first else { continue }
            uids.insert(meeting.uid)
            records[meeting.uid] = meeting
            migrated += 1
        }

        finishLegacyMigration(migrated: migrated)
    }

    /// Preferred migration path: match on content rather than ID.
    ///
    /// Pass the meetings the old app had cached (its `meetings_cache.json`
    /// decodes into `Meeting` with `rootServerID == 0`), plus the fresh set from
    /// the aggregator. Favourites from the old file are re-pointed at whichever
    /// new meeting has the same name, weekday, and start time.
    func resolveLegacy(legacyMeetings: [Meeting], against meetings: [Meeting]) {
        guard !pendingLegacyIDs.isEmpty else { return }

        let legacyByID = Dictionary(grouping: legacyMeetings, by: \.id)
        let freshByFingerprint = Dictionary(grouping: meetings, by: \.migrationFingerprint)

        var migrated = 0
        for legacyID in pendingLegacyIDs {
            guard let legacyMeeting = legacyByID[legacyID]?.first else { continue }

            // Ambiguous fingerprints are dropped, not guessed.
            guard let candidates = freshByFingerprint[legacyMeeting.migrationFingerprint],
                  candidates.count == 1,
                  let meeting = candidates.first else { continue }

            uids.insert(meeting.uid)
            records[meeting.uid] = meeting
            migrated += 1
        }

        finishLegacyMigration(migrated: migrated)
    }

    private func finishLegacyMigration(migrated: Int) {
        let dropped = pendingLegacyIDs.count - migrated
        pendingLegacyIDs = []
        legacyStore.remove(kind.legacyFileName)
        save()

        #if DEBUG
        print("[MeetingSetStore] \(kind.rawValue): migrated \(migrated), dropped \(dropped) ambiguous/unmatched")
        #endif
    }
}
