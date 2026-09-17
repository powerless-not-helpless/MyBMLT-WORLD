import Testing
import Foundation
@testable import MyBMLTUSA

/// A `URLProtocol` that answers from a queue of canned responses, so
/// `AggregatorClient` can be exercised through its real request and decode path
/// without a network.
///
/// ## Why a URLProtocol rather than a protocol abstraction
/// `AggregatorClient` already takes a `URLSession`, so this needs no new
/// seam in shipping code. It also tests more than a mock would: the URL is
/// really built, really encoded, and the JSON really decoded — which is where
/// the scoping bugs live. A hand-written `AggregatorClient` substitute would
/// stub past exactly the layer that has already been wrong twice.
///
/// ## Why state is keyed by session, not static
/// Swift Testing runs tests in parallel, so a single static queue let one test
/// consume another's programmed responses. Each test now programs a session
/// identified by a token in its request header, and the queues are kept apart.
/// An exhausted queue fails the test loudly instead of silently returning an
/// empty body — which would look exactly like "this meeting was deleted".
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    static let sessionHeader = "X-Stub-Session"

    /// One programmed response: either a body to return, or an error to throw.
    enum Response {
        case json(String)
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Response]] = [:]
    nonisolated(unsafe) private static var urlsBySession: [String: [URL]] = [:]

    /// Programs responses for one session token and returns a configured
    /// `URLSession`. The token is added to every request this session makes.
    ///
    /// `responses` is labelled so a single-argument call cannot bind the array
    /// to `token` by accident.
    static func session(_ token: String = UUID().uuidString,
                        responses: [Response]) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        queues[token] = responses
        urlsBySession[token] = []

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [sessionHeader: token]
        return URLSession(configuration: config)
    }

    /// Requests made by a session, in order.
    static func urls(for token: String) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urlsBySession[token] ?? []
    }

    /// Responses still unconsumed for a session. Used to prove a test did not
    /// silently under-deliver.
    static func remaining(for token: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return queues[token]?.count ?? 0
    }

    private static func next(_ token: String) -> Response? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queues[token], !q.isEmpty else { return nil }
        let first = q.removeFirst()
        queues[token] = q
        return first
    }

    private static func record(_ token: String, _ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urlsBySession[token, default: []].append(url)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.sessionHeader) ?? "unknown"
        if let url = request.url { Self.record(token, url) }

        guard let response = Self.next(token) else {
            // Deliberately an error, not an empty body. An exhausted queue that
            // returned `[]` would be indistinguishable from a deleted meeting
            // and could make a deletion test pass for the wrong reason.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch response {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .json(let body):
            let data = Data(body.utf8)
            let http = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The real `AggregatorClient.meetings` path is scoped and chunked here.
private func stubbedClient(_ session: URLSession) -> AggregatorClient {
    AggregatorClient(session: session)
}

/// Builds a BMLT row exactly as the aggregator sends it: every value a string,
/// `root_server_id` the one integer.
private func row(id: Int,
                 root: Int,
                 name: String = "Group",
                 weekday: Int = 2,
                 start: String = "19:00:00",
                 street: String = "123 Main St") -> String {
    """
    {
      "id_bigint": "\(id)",
      "meeting_name": "\(name)",
      "weekday_tinyint": "\(weekday)",
      "start_time": "\(start)",
      "duration_time": "01:00:00",
      "time_zone": "",
      "location_text": "Clubhouse",
      "location_street": "\(street)",
      "location_municipality": "San Diego",
      "location_postal_code_1": "92101",
      "location_info": "",
      "virtual_meeting_link": null,
      "virtual_meeting_additional_info": null,
      "service_body_bigint": "2313",
      "service_body_name": "SDICR",
      "formats": "O,D",
      "venue_type": "1",
      "latitude": "32.7157",
      "longitude": "-117.1611",
      "root_server_id": \(root)
    }
    """
}

private func jsonPayload(_ rows: [String]) -> String { "[\(rows.joined(separator: ","))]" }

/// Tests for the scoped out-of-Area fetch.
///
/// ## Why these matter
/// This is the only place the app decides a saved meeting is **gone**. A wrong
/// answer either banners a live meeting as vanished or silently heals a record
/// to an unrelated meeting. `recordObservations` is unit-tested in
/// `StoreTests`; these tests cover the layer above it — which fetch result is
/// allowed to become evidence, and which is not.
@Suite("Favorite verification")
@MainActor
struct FavoriteVerifierTests {

    private func tempStore() -> FileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyBMLTVerify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStore(testDirectory: dir)
    }

    private func meeting(id: Int,
                         root: Int,
                         name: String = "Group",
                         weekday: Int = 2,
                         start: String = "19:00:00",
                         street: String = "123 Main St") -> Meeting {
        Meeting(
            id: id, rootServerID: root, name: name, weekday: weekday,
            startTime: start, duration: "01:00:00", locationName: "Clubhouse",
            street: street, city: "San Diego", zip: "92101", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: ["O", "D"],
            serviceBodyID: 2313, serviceBodyName: "SDICR", venueType: 1,
            latitude: 32.7157, longitude: -117.1611, timeZoneID: "",
            distanceMiles: nil, distanceKilometers: nil
        )
    }

    // MARK: - Success path

    @Test("A returned meeting heals the saved record")
    func returnedMeetingHeals() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7, start: "19:00:00")
        store.toggle(saved)

        let stub = StubURLProtocol.session(responses: [.json(jsonPayload([row(id: 2, root: 7, start: "20:00:00")]))])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        #expect(store.all.first?.startTime == "20:00:00")
        #expect(store.pendingChanges(for: saved) == [.schedule])
        #expect(store.needsVerification == false)
    }

    @Test("The request carries the plural bracket-form root_server_ids")
    func requestIsScoped() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 2, root: 7))
        let token = UUID().uuidString

        let stub = StubURLProtocol.session(token, responses: [.json(jsonPayload([row(id: 2, root: 7)]))])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        // Asserted end-to-end through the real URL builder, because an unscoped
        // fetch silently resolves a bare id against the wrong server.
        let url = try? #require(StubURLProtocol.urls(for: token).first)
        let query = url?.query ?? ""
        #expect(query.contains("meeting_ids%5B%5D=2") || query.contains("meeting_ids[]=2"))
        #expect(query.contains("root_server_ids%5B%5D=7") || query.contains("root_server_ids[]=7"))
    }

    // MARK: - Failure path — the important half

    @Test("A failed fetch records no absence, and cannot banner a deletion")
    func failureRecordsNoAbsence() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // The server is unreachable. An empty result here would be
        // indistinguishable from a deletion if we treated it as evidence.
        let stub = StubURLProtocol.session(responses: [
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)),
        ])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        #expect(store.isMissing(saved) == false)
        #expect(store.confirmedMissingUIDs.isEmpty)
        // The saved record is untouched, so an offline user still sees it.
        #expect(store.count == 1)
    }

    @Test("A failed fetch still advances the verification clock")
    func failureStillMarksVerified() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 2, root: 7))

        let stub = StubURLProtocol.session(responses: [.failure(URLError(.timedOut))])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        // Otherwise an offline user would re-request on every tab appearance.
        #expect(store.needsVerification == false)
    }

    @Test("A malformed body records no absence either")
    func decodeFailureRecordsNoAbsence() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // Valid HTTP, undecodable body. Must not be read as "meeting gone".
        let stub = StubURLProtocol.session(responses: [
            .json("{ this is not the payload shape }"),
            .json("{ this is not the payload shape }"),
        ])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        #expect(store.isMissing(saved) == false)
    }

    // MARK: - Absence, the honest way

    @Test("Two clean empty responses confirm a missing meeting")
    func confirmedAbsence() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // A successful request that simply does not return the id.
        let stub = StubURLProtocol.session(responses: [.json("[]"), .json("[]")])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        #expect(store.isMissing(saved) == false)   // one observation is not enough

        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        #expect(store.isMissing(saved))
    }

    @Test("The TTL gate means two confirmations need two visits, not one")
    func confirmationSpansTwoVisits() async {
        // This records a real design consequence rather than hiding it: because
        // `markVerified` runs after every attempt and the store is then "fresh"
        // for `CachePolicy.meetings` (6 h), a deletion cannot be confirmed by
        // one tab visit. The second confirmation arrives at the next visit, on a
        // later launch. The banner is deliberately slow for that reason — a
        // wrong "gone" label is worse than a late one.
        let files = tempStore()
        let lists = UserLists(
            favorites: MeetingSetStore(kind: .favorites, store: files, legacyStore: files),
            explore: MeetingSetStore(kind: .explore, store: files, legacyStore: files)
        )
        let saved = meeting(id: 2, root: 7)
        lists.favorites.toggle(saved)

        let stub = StubURLProtocol.session(responses: [.json("[]")])
        await lists.verifyOutOfAreaFavorites(knownMeetings: [], client: stubbedClient(stub))

        // One observation recorded, but not yet surfaced.
        #expect(lists.favorites.isMissing(saved) == false)
        // And the gate now suppresses further attempts until the TTL lapses.
        #expect(lists.favorites.needsVerification == false)

        // Simulate the next visit after the TTL has passed.
        lists.favorites.markVerified(at: Date().addingTimeInterval(-7 * 60 * 60))
        let stub2 = StubURLProtocol.session(responses: [.json("[]")])
        await lists.verifyOutOfAreaFavorites(knownMeetings: [], client: stubbedClient(stub2))

        #expect(lists.favorites.isMissing(saved))
    }

    @Test("A meeting reappearing clears the missing flag through the real path")
    func reappearanceHeals() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        let stub = StubURLProtocol.session(responses: [
            .json("[]"), .json("[]"),
            .json(jsonPayload([row(id: 2, root: 7)])),
        ])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        #expect(store.isMissing(saved))

        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        #expect(store.isMissing(saved) == false)
    }

    // MARK: - Cross-server safety

    @Test("A row for another root server sharing an id cannot corrupt a favourite")
    func unrelatedRowIsDropped() async {
        // NOTE ON COVERAGE. This test pins the *behaviour*, not the specific
        // `requested.contains` filter in `FavoriteVerifier`. That filter was
        // checked by mutation and found to be **redundant today**: removing it
        // does not change any observable outcome, because `updateRecords`
        // already gates on `uids.contains` and `recordObservations` intersects
        // with `requested`. The test is kept because the invariant it asserts is
        // the one that matters, and because the two guards are independent — if
        // either is ever relaxed, this catches it at the level the user sees.
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        // Both "7:2" and "38:2" are real uids, and 7:2 is the saved one.
        let onSeven = meeting(id: 2, root: 7, name: "On Seven", start: "19:00:00")
        store.toggle(onSeven)

        // We asked about root 7 only, but the server answers with root 38's
        // id 2 — a different meeting that happens to share the sequence number,
        // and one that would look like a schedule change if it were applied.
        let stub = StubURLProtocol.session(responses: [
            .json(jsonPayload([row(id: 2, root: 38, name: "Unrelated", start: "23:45:00")])),
            .json(jsonPayload([row(id: 2, root: 38, name: "Unrelated", start: "23:45:00")])),
        ])
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))
        await FavoriteVerifier.verify(byRoot: [7: [2]], store: store, client: stubbedClient(stub))

        // The saved record keeps its own details: no aliased rename, no aliased
        // time change, and therefore no false "details changed" banner.
        #expect(store.all.first?.name == "On Seven")
        #expect(store.all.first?.startTime == "19:00:00")
        #expect(store.pendingChanges(for: onSeven).isEmpty)

        // And the unrelated row does not count as "7:2 was seen", so the saved
        // meeting is still assessed on its own evidence.
        #expect(store.isMissing(onSeven))
    }

    @Test("Two saved meetings sharing an id on different servers stay independent")
    func sameIDDifferentServersBothVerified() async {
        // The precise scenario the `uid` filter protects. Both are saved, both
        // are fetched, and each must heal against its own server's row.
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let onSeven = meeting(id: 2, root: 7, name: "Seven Group", start: "19:00:00")
        let onThirtyEight = meeting(id: 2, root: 38, name: "ThirtyEight Group", start: "19:00:00")
        store.toggle(onSeven)
        store.toggle(onThirtyEight)

        // One response carrying both, as a single cross-server request would.
        let both = jsonPayload([
            row(id: 2, root: 7, name: "Seven Group", start: "19:00:00"),
            row(id: 2, root: 38, name: "ThirtyEight Group", start: "20:00:00"),
        ])
        let stub = StubURLProtocol.session(responses: [.json(both)])
        await FavoriteVerifier.verify(byRoot: [7: [2], 38: [2]],
                                      store: store,
                                      client: stubbedClient(stub))

        // Each record heals from its own server's row, and only root 38 moved.
        let byUID = Dictionary(uniqueKeysWithValues: store.all.map { ($0.uid, $0) })
        #expect(byUID["7:2"]?.startTime == "19:00:00")
        #expect(byUID["38:2"]?.startTime == "20:00:00")
        #expect(store.pendingChanges(for: onSeven).isEmpty)
        #expect(store.pendingChanges(for: onThirtyEight) == [.schedule])
    }

    @Test("A meeting saved in two lists is verified in both")
    func bothListsVerified() async {
        let files = tempStore()
        let lists = UserLists(
            favorites: MeetingSetStore(kind: .favorites, store: files, legacyStore: files),
            explore: MeetingSetStore(kind: .explore, store: files, legacyStore: files)
        )
        let shared = meeting(id: 2, root: 7)
        lists.favorites.toggle(shared)
        lists.explore.toggle(shared)

        // Both lists are verified independently, so both requests must be served.
        let stub = StubURLProtocol.session(responses: [
            .json(jsonPayload([row(id: 2, root: 7, start: "20:00:00")])),
            .json(jsonPayload([row(id: 2, root: 7, start: "20:00:00")])),
        ])
        await lists.verifyOutOfAreaFavorites(knownMeetings: [], client: stubbedClient(stub))

        #expect(lists.favorites.all.first?.startTime == "20:00:00")
        #expect(lists.explore.all.first?.startTime == "20:00:00")
    }

    // MARK: - Chunking

    @Test("A large list is split into bounded requests and still verified")
    func chunkingSplitsRequests() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = (1...250).map { meeting(id: $0, root: 7, name: "M\($0)") }
        saved.forEach { store.toggle($0) }

        // 250 ids at a max of 200 per request means two calls.
        let token = UUID().uuidString
        let firstBatch = (1...200).map { row(id: $0, root: 7, name: "M\($0)") }
        let secondBatch = (201...250).map { row(id: $0, root: 7, name: "M\($0)") }
        let stub = StubURLProtocol.session(token, responses: [
            .json(jsonPayload(firstBatch)),
            .json(jsonPayload(secondBatch)),
        ])

        await FavoriteVerifier.verify(byRoot: [7: Array(1...250)],
                                      store: store,
                                      client: stubbedClient(stub))

        #expect(StubURLProtocol.urls(for: token).count == 2)
        // Every id was returned, so nothing is recorded as absent.
        #expect(store.confirmedMissingUIDs.isEmpty)
        #expect(store.needsVerification == false)
    }

    @Test("A partial chunk failure records no absences at all")
    func partialChunkFailureRecordsNothing() async {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = (1...250).map { meeting(id: $0, root: 7, name: "M\($0)") }
        saved.forEach { store.toggle($0) }

        // First chunk succeeds, second fails. The ids in the failed chunk were
        // never answered, so they must not be treated as deleted.
        let firstBatch = (1...200).map { row(id: $0, root: 7, name: "M\($0)") }
        let stub = StubURLProtocol.session(responses: [
            .json(jsonPayload(firstBatch)),
            .failure(URLError(.networkConnectionLost)),
        ])

        await FavoriteVerifier.verify(byRoot: [7: Array(1...250)],
                                      store: store,
                                      client: stubbedClient(stub))

        #expect(store.confirmedMissingUIDs.isEmpty)
        #expect(store.isMissing(saved[240]) == false)
    }
}
