import SwiftUI

/// Holds both per-meeting user lists.
///
/// These cannot be two separate `@Environment(MeetingSetStore.self)` lookups —
/// the environment keys on type, so two instances of the same class would
/// collide and one tab would read the other's data. One container with two
/// named properties removes the ambiguity.
@MainActor
@Observable
final class UserLists {
    let favorites: MeetingSetStore
    let explore: MeetingSetStore

    init(favorites: MeetingSetStore? = nil,
         explore: MeetingSetStore? = nil) {
        // Default arguments are evaluated in a nonisolated context, so a
        // `@MainActor` initializer cannot be called inline there. Constructing
        // them here, inside the isolated init body, is the fix.
        self.favorites = favorites ?? MeetingSetStore(kind: .favorites)
        self.explore = explore ?? MeetingSetStore(kind: .explore)
    }

    var hasPendingMigration: Bool {
        !favorites.pendingLegacyIDs.isEmpty || !explore.pendingLegacyIDs.isEmpty
    }

    /// Heals both lists from a fresh server response.
    ///
    /// Membership is untouched — see `MeetingSetStore.updateRecords(from:)`.
    func update(from meetings: [Meeting]) {
        favorites.updateRecords(from: meetings)
        explore.updateRecords(from: meetings)
    }

    /// True when either list holds a behavioural change the user has not seen.
    var hasUnseenChanges: Bool {
        favorites.hasUnseenChanges || explore.hasUnseenChanges
    }

    // MARK: - Out-of-Area verification

    /// Heals saved meetings that the active Area's list does not contain.
    ///
    /// - Parameter knownMeetings: everything `MeetingStore` currently holds.
    ///   Anything saved and absent from this set needs its own fetch.
    ///
    /// Safe to call on every tab appearance: the per-store TTL gate means it
    /// no-ops until `CachePolicy.meetings` has elapsed. Only touches the
    /// network when something is actually missing and stale.
    ///
    /// Note that the in-Area case is deliberately **not** used to judge
    /// absence. `knownMeetings` is one Area's subtree, so a favourite in
    /// another Area is absent from it by design — treating that as deletion
    /// would banner every out-of-Area favourite. Absence is only ever recorded
    /// by `FavoriteVerifier`, which queries the specific ids it asked about.
    func verifyOutOfAreaFavorites(knownMeetings: [Meeting],
                                  client: AggregatorClient = AggregatorClient()) async {
        let known = Set(knownMeetings.map(\.uid))

        for store in [favorites, explore] {
            guard store.needsVerification else { continue }
            guard let byRoot = store.unverifiedIDs(notIn: known) else {
                // Everything saved is already in memory, so the free path
                // already covered it. Advance the clock without a request.
                store.markVerified()
                continue
            }
            await FavoriteVerifier.verify(byRoot: byRoot, store: store, client: client)
        }
    }

    /// Unacknowledged changes for a meeting, drawn from whichever list holds
    /// it. The same meeting can be starred *and* on the explore list, so the
    /// union is taken rather than picking one.
    func pendingChanges(for meeting: Meeting) -> [Meeting.Change] {
        let merged = Set(favorites.pendingChanges(for: meeting))
            .union(explore.pendingChanges(for: meeting))
        return merged.sorted { $0.rank < $1.rank }
    }

    /// True when a saved meeting was confirmed absent from the server twice.
    func isMissing(_ meeting: Meeting) -> Bool {
        favorites.isMissing(meeting) || explore.isMissing(meeting)
    }

    func missingFirstNoticed(_ meeting: Meeting) -> Date? {
        favorites.missingFirstNoticed(meeting) ?? explore.missingFirstNoticed(meeting)
    }

    /// Saved meetings confirmed missing, for the Favorites-tab badge and the
    /// row dot.
    var missingCount: Int {
        favorites.missingCount + explore.missingCount
    }

    func acknowledgeChanges(for meeting: Meeting) {
        favorites.acknowledgeChanges(for: meeting)
        explore.acknowledgeChanges(for: meeting)
    }

    /// One-time carry-over of pre-`uid` favourites. See `MIGRATION_NOTES.md`.
    func migrate(legacyMeetings: [Meeting], against fresh: [Meeting]) {
        guard hasPendingMigration else { return }
        if legacyMeetings.isEmpty {
            favorites.resolveLegacy(against: fresh)
            explore.resolveLegacy(against: fresh)
        } else {
            favorites.resolveLegacy(legacyMeetings: legacyMeetings, against: fresh)
            explore.resolveLegacy(legacyMeetings: legacyMeetings, against: fresh)
        }
    }
}
