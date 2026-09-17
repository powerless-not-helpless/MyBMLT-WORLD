import Foundation
import Observation

/// The Meetings tab's data source.
///
/// Query strategy: fetch the active Area's subtree recursively, then filter
/// client-side for day/venue/format. Server-side filtering is used where it is
/// proven (`venue_types`, `weekdays[]`), but the whole of a regional subtree is
/// small enough to hold — verified 377 meetings for all of SDICR — so
/// client-side filtering keeps interactions instant and works offline.
@MainActor
@Observable
final class MeetingStore {

    private let client: AggregatorClient
    private let store: FileStore

    private(set) var meetings: [Meeting] = []
    private(set) var formatLabels: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    /// True when what we're showing came from disk, not this session's network.
    private(set) var isFromCache = false

    /// Bumped when the active Area changes, so stale in-flight responses are
    /// discarded rather than overwriting a newer Area's results.
    private var generation = 0

    private let legacyCacheFile = "meetings_cache.json"

    /// Format labels bundled for SDICR, where `format_map.txt` was verified
    /// 33/33 against live data. Used only as a fallback when the server gives
    /// us no label for a key — formats are per-root-server, so server labels
    /// always win.
    private let bundledFormatLabels: [String: String]

    init(client: AggregatorClient = AggregatorClient(),
         store: FileStore = FileStore(),
         bundledFormatLabels: [String: String] = BundledFormats.labels) {
        self.client = client
        self.store = store
        self.bundledFormatLabels = bundledFormatLabels
    }

    // MARK: - Loading

    /// Cache-then-network, always. The first screen never waits on a request,
    /// and never requires network permission.
    func load(for selection: AreaSelection) async {
        generation += 1
        let myGeneration = generation

        loadFromCache(selection)
        await refresh(selection: selection, generation: myGeneration)
    }

    func refresh(selection: AreaSelection) async {
        generation += 1
        await refresh(selection: selection, generation: generation)
    }

    private func refresh(selection: AreaSelection, generation myGeneration: Int) async {
        isLoading = true
        error = nil

        do {
            let result = try await client.meetingsAndFormats(
                .serviceBodies(ids: [selection.serviceBodyID], recursive: true)
            )
            guard myGeneration == generation else { return }   // superseded

            meetings = result.meetings
            // Server labels win; bundled labels fill gaps only.
            formatLabels = bundledFormatLabels.merging(result.formats) { _, server in server }
            lastUpdated = Date()
            isFromCache = false
            isLoading = false
            saveToCache(selection)
        } catch {
            guard myGeneration == generation else { return }
            // Only surface an error when we have nothing to show. If the cache
            // populated the list, a failed refresh is not the user's problem.
            if meetings.isEmpty {
                // `caught` avoids shadowing the `error` property; assigning to
                // the implicit `error` binding would target the immutable
                // caught value, not the property.
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - Cache

    private struct CachePayload: Codable {
        let date: Date
        let meetings: [Meeting]
        let formatLabels: [String: String]
    }

    /// Keyed by root server **and** service body, so two Areas no longer
    /// overwrite each other (the pre-rewrite app cached a single file).
    private func cacheFile(for selection: AreaSelection) -> String {
        "meetings_\(selection.rootServerID)_\(selection.serviceBodyID).json"
    }

    private func saveToCache(_ selection: AreaSelection) {
        let payload = CachePayload(date: Date(), meetings: meetings, formatLabels: formatLabels)
        store.write(payload, to: cacheFile(for: selection))
    }

    private func loadFromCache(_ selection: AreaSelection) {
        guard let payload = store.read(CachePayload.self, from: cacheFile(for: selection)) else {
            meetings = []
            lastUpdated = nil
            isFromCache = false
            return
        }
        guard !payload.meetings.isEmpty else { return }
        meetings = payload.meetings
        formatLabels = bundledFormatLabels.merging(payload.formatLabels) { _, cached in cached }
        lastUpdated = payload.date
        isFromCache = true
    }

    // MARK: - Legacy cache access

    /// Decodes the pre-rewrite `meetings_cache.json`, for the favourites
    /// migration. That file's `Meeting` decode yields `rootServerID == 0`,
    /// which is fine — it is only used as a fingerprint source.
    ///
    /// Verified shape: `{"date": ..., "meetings": [...]}`, 372 rows, with
    /// `serviceBodyId` in the 1155–1165 (wszf) range.
    func loadLegacyMeetings() -> [Meeting] {
        struct LegacyPayload: Codable {
            let date: Date
            let meetings: [Meeting]
        }
        guard let payload = store.read(LegacyPayload.self, from: legacyCacheFile) else { return [] }
        return payload.meetings
    }

    func removeLegacyCache() {
        store.remove(legacyCacheFile)
    }
}

/// Format labels for the SDICR (root server 38).
///
/// **Not a global fallback.** Formats are per-root-server: the aggregator
/// returns 1,502 format rows with only 309 unique keys, and `O` means "Open" on
/// most servers but "Meets 2nd wk of month" on root 10. These labels are
/// therefore only used when the server provides nothing.
///
/// Coverage was corrected against live data. An earlier revision carried 33
/// hand-picked keys and claimed to be "verified 33/33", but that only proved the
/// 33 were spelled correctly — it did not prove they covered the data. SDICR
/// meetings use 40 distinct codes, and 6 of them were absent, including the two
/// most common after `O`/`D`: `§` (146 uses) and `JT` (114). Labels below are
/// taken from live `GetFormats` for root server 38.
/// `nonisolated`: static data with no UI state, read as a default argument in a
/// nonisolated context. Without this it is inferred main-actor-bound and cannot
/// be referenced from `MeetingStore`'s initializer signature.
nonisolated enum BundledFormats {
    static let labels: [String: String] = [
        "11": "11 Step Oriented", "5": "5th & 10th Step",
        "ASM": "Area Service Meetings", "B": "Newcomers",
        "BK": "Book Study", "BL": "Bi-Lingual", "BT": "Basic Text", "C": "Closed",
        "CL": "Candlelight", "CP": "Concepts", "CPC": "Chairperson's Choice",
        "CW": "Children Welcome", "D": "Discussion", "ES": "Español", "G": "LGBTQ+",
        "GP": "Guiding Principles", "HY": "Hybrid Meeting", "IW": "It Works How and Why",
        "JT": "Just for Today", "L": "LGBTQ+", "LC": "Living Clean", "LGBT": "LGBTQ+",
        "LS": "Literature Study", "M": "Men's", "MM": "Medallions Monthly",
        "NC": "No Children", "NS": "No Smoking", "O": "Open", "OD": "Outdoors",
        "OE": "Open Ended", "RF": "Rotating Format", "SB": "Smoke Break",
        "SD": "Speaker Discussion", "SG": "Step Working Guide", "So": "Speaker Only",
        "SPAD": "Spiritual Principle a Day", "St": "Step Study", "TC": "Temporarily Closed Facility",
        "To": "Topic", "Tr": "Tradition", "VM": "Virtual Meeting", "W": "Women",
        "WC": "Wheelchair", "YP": "Young People", "§": "Stamp",
    ]
}
