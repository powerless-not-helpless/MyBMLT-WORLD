import Foundation

/// Reconciles saved Favorites/Explore entries whose meetings are **not** in the
/// active Area's meeting list, and records which of them the server no longer
/// returns.
///
/// ## Why this exists
/// `UserLists.update(from:)` heals saved records from whatever `MeetingStore`
/// already holds. That covers favourites inside the active Area for free, but a
/// favourite in another Area is never in that set, so it stays frozen at
/// save-time forever. This type closes that gap with a targeted fetch.
///
/// ## Why it is scoped by root server
/// A bare `id_bigint` is not globally unique — it is a per-root-server sequence
/// number. Verified live: `meeting_ids` with ids `1...60` returns rows from
/// root server 1 only, silently. So every request pairs `meeting_ids[]` with
/// `root_server_ids[]`, which was verified to genuinely filter. Without it, an
/// out-of-Area favourite would be diffed against an unrelated meeting and raise
/// a false "details changed" banner.
///
/// ## Why absence is only recorded on a *clean* fetch
/// A deleted meeting is not marked `published = 0`; it disappears, because the
/// aggregator filters unpublished rows server-side. That makes `[]` ambiguous
/// between "deleted" and "the query failed or was wrong". This type therefore
/// separates the two paths explicitly: a thrown request records **nothing**
/// about missing meetings, and only a successful, scoped, non-empty response is
/// passed to `recordObservations`. See `MeetingSetStore.missingSince`.
@MainActor
enum FavoriteVerifier {

    /// Maximum ids per request.
    ///
    /// Favorites are typically 5–20 and Explore around 67, so this is a
    /// guard-rail rather than a value expected to bind. It exists because a
    /// pathological list (or a future import feature) must not build a URL of
    /// unbounded length.
    static let maxIDsPerRequest = 200

    /// Fetches current data for `ids` grouped by root server, applies it to
    /// `store`, and records absences.
    ///
    /// - Parameters:
    ///   - byRoot: `rootServerID` → local `id`s, from
    ///     `MeetingSetStore.unverifiedIDs(notIn:)`.
    ///   - store: the list to heal. Membership is never changed.
    ///   - client: injected so this is testable without a network.
    ///
    /// A failure leaves saved records untouched — a user who is offline still
    /// sees everything they saved, which is the whole point of caching them.
    static func verify(byRoot: [Int: [Int]],
                       store: MeetingSetStore,
                       client: AggregatorClient = AggregatorClient()) async {
        let rootServerIDs = byRoot.keys.sorted()

        // Every uid this call is responsible for. Absences are only ever judged
        // against this set, never against the wider list.
        let requested = Set(byRoot.flatMap { root, ids in ids.map { "\(root):\($0)" } })

        var allIDs: [Int] = []
        for root in rootServerIDs {
            allIDs.append(contentsOf: byRoot[root] ?? [])
        }

        var fetched: [Meeting] = []
        var allChunksSucceeded = true

        for chunk in allIDs.chunked(into: maxIDsPerRequest) {
            do {
                let result = try await client.meetings(
                    .meetingIDs(ids: chunk, rootServerIDs: rootServerIDs)
                )
                fetched.append(contentsOf: result)
            } catch {
                // A failed request is not evidence about any meeting. Remember
                // that, so absence is not inferred from it.
                allChunksSucceeded = false
                #if DEBUG
                print("[FavoriteVerifier] scoped fetch failed: \(error)")
                #endif
            }
        }

        // Only records this store actually holds can be applied, and only for
        // the uid they were requested under. This also drops any row the server
        // returned for a server/id pairing we did not ask about.
        let relevant = fetched.filter { requested.contains($0.uid) }

        store.applyVerified(relevant)

        // Absence is judged only when every chunk answered. Partial results
        // would make a chunk that never came back look like a set of deletions.
        if allChunksSucceeded {
            store.recordObservations(requested: requested,
                                     returned: Set(relevant.map(\.uid)))
        }
    }
}

private extension Array {
    /// Splits into chunks of at most `size`. Used to bound request URL length.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
