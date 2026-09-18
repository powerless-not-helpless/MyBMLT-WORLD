import Foundation
import Observation

/// Owns where the user is interested in, and persists it.
///
/// The brief requires the app not to assume a single home Area. That is
/// enforced structurally here: `AreaState.selections` is a list, and changing
/// the active Area **adds** to it rather than replacing. A user who moves from
/// San Diego to Austin keeps both, and can switch back without re-discovering.
@MainActor
@Observable
final class AreaStore {

    private let store: FileStore
    private let client: AggregatorClient

    private(set) var state: AreaState
    /// The full service body graph, cached for a week (~1,571 rows).
    private(set) var tree: ServiceBodyTree?
    private(set) var isLoadingBodies = false
    private(set) var bodiesError: String?

    private let stateFileName = "areas.json"
    private let bodiesFileName = "servicebodies.json"

    init(store: FileStore = FileStore(), client: AggregatorClient = AggregatorClient()) {
        self.store = store
        self.client = client
        self.state = store.read(AreaState.self, from: stateFileName) ?? AreaState()

        if let cached = store.read([ServiceBody].self, from: bodiesFileName),
           CachePolicy.isFresh(store.modifiedAt(bodiesFileName),
                               within: CachePolicy.serviceBodies) {
            self.tree = ServiceBodyTree(cached)
        }
    }

    // MARK: - Active area

    var active: AreaSelection? { state.active }

    var hasSelection: Bool { state.active != nil }

    var selections: [AreaSelection] {
        state.selections.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// The service body record for the active area, if the graph is loaded.
    var activeBody: ServiceBody? {
        guard let active else { return nil }
        return tree?.body(uid: active.serviceBodyUID)
    }

    func setActive(_ selection: AreaSelection) {
        state.add(selection, makeActive: true)
        persist()
    }

    func add(_ selection: AreaSelection, makeActive: Bool = false) {
        state.add(selection, makeActive: makeActive)
        persist()
    }

    func remove(_ selection: AreaSelection) {
        state.remove(uid: selection.serviceBodyUID)
        persist()
    }

    // MARK: - Service body graph

    /// Loads the graph from cache when fresh, otherwise from the network.
    ///
    /// Never clears `tree` on failure: a stale graph is far better than none,
    /// because it is the only way to render the Area picker offline.
    func loadServiceBodies(forceRefresh: Bool = false) async {
        let isFresh = CachePolicy.isFresh(store.modifiedAt(bodiesFileName),
                                          within: CachePolicy.serviceBodies)
        if !forceRefresh, isFresh, tree != nil { return }

        isLoadingBodies = true
        bodiesError = nil
        defer { isLoadingBodies = false }

        do {
            let fetched = try await client.serviceBodies()
            tree = fetched
            store.write(fetched.bodies, to: bodiesFileName)
        } catch {
            bodiesError = error.localizedDescription
            // Keep whatever cache we already loaded.
        }
    }

    // MARK: - Nearby meetings

    /// Meetings within `radiusMiles` of a coordinate, as the server reports
    /// them.
    ///
    /// Exists so the Area picker's two discovery paths ("use my location" and
    /// a city/ZIP lookup) go through this store's injected client instead of
    /// constructing one. That is what makes the request path testable: a test
    /// can build an `AreaStore` with a stubbed `URLSession` and observe the
    /// real URL that was built and the rows that were decoded, neither of which
    /// is reachable through a private method on a view.
    ///
    /// The radius stays a parameter with no product meaning here: callers pass
    /// the value their flow documents.
    func meetingsNear(latitude: Double,
                      longitude: Double,
                      radiusMiles: Double) async throws -> [Meeting] {
        try await client.meetings(
            .geo(latitude: latitude, longitude: longitude, radiusMiles: radiusMiles)
        )
    }

    // MARK: - Persistence

    private func persist() {
        store.write(state, to: stateFileName)
    }
}
