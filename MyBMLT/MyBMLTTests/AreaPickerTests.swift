import Testing
import Foundation
@testable import MyBMLTUSA

/// Tests for `AreaProximity` — the vote that decides which Area owns a
/// coordinate.
///
/// ## Why these exist
/// This logic used to be two `private` methods on `AreaPickerView` reading
/// `areas.tree` out of the environment. Nothing could reach them: a view needs a
/// window, and the tree came from composition-root state, so the single decision
/// that picks the user's Area had no test. Extracting it to a pure function is
/// what makes the cases below possible.
///
/// The behaviour is a **plurality inside the nearest five meetings**, not "the
/// owner of the single nearest meeting". Those differ, and `STATUS.md` records
/// that earlier revisions got the ranking wrong twice (a count across every
/// meeting in 25 miles, then a name match that was later removed as decoration).
/// These tests pin the real rule rather than the tidier-sounding one.
@Suite("Area proximity")
struct AreaProximityTests {

    private func body(_ id: Int, _ name: String) -> ServiceBody {
        ServiceBody(id: id, parentID: nil, name: name, description: nil,
                    type: "AS", url: nil, helpline: "", worldID: nil,
                    rootServerID: 38)
    }

    /// Two Areas, `100` and `200`, both present in the graph.
    private var tree: ServiceBodyTree {
        ServiceBodyTree([body(100, "Alpha Area"), body(200, "Beta Area")])
    }

    private func meeting(id: Int = 1, owner: Int, miles: Double?) -> Meeting {
        Meeting(
            id: id, rootServerID: 38, name: "Group", weekday: 2,
            startTime: "19:00:00", duration: "01:00:00", locationName: "",
            street: "", city: "", zip: "", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: ["O"],
            serviceBodyID: owner, serviceBodyName: "", venueType: 1,
            latitude: 32.7, longitude: -117.1, timeZoneID: "",
            distanceMiles: miles, distanceKilometers: nil
        )
    }

    // MARK: - The vote

    @Test("The Area owning the most of the nearest meetings wins")
    func pluralityWins() {
        let meetings = [
            meeting(id: 1, owner: 200, miles: 1.0),
            meeting(id: 2, owner: 100, miles: 2.0),
            meeting(id: 3, owner: 200, miles: 3.0),
            meeting(id: 4, owner: 100, miles: 4.0),
            meeting(id: 5, owner: 200, miles: 5.0),
        ]
        let owners = AreaProximity.owners(of: meetings, in: tree)

        #expect(owners.map(\.id) == [200, 100])
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 200)
    }

    @Test("An Area with many meetings far away cannot outvote the local one")
    func farAreaCannotOutvoteTheLocalOne() {
        // The documented failure this rule exists to prevent: Bay Area owned 117
        // meetings within 25 miles of Tampa and won a count-based vote, while the
        // Area actually covering Tampa had one meeting next door. Bounding the
        // window first is what fixes that.
        var meetings = (1...5).map { meeting(id: $0, owner: 100, miles: Double($0) * 0.2) }
        meetings += (6...15).map { meeting(id: $0, owner: 200, miles: Double($0) + 20) }

        let owners = AreaProximity.owners(of: meetings, in: tree)

        #expect(owners.map(\.id) == [100])
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 100)
    }

    @Test("Exactly five meetings vote, so a sixth-nearest owner gets none")
    func windowIsExactlyFive() {
        // Five near rows for 100, five further rows for 200. If the whole list
        // voted the result would be a 5-5 tie; only the window decides.
        var meetings = (1...5).map { meeting(id: $0, owner: 100, miles: Double($0)) }
        meetings += (6...10).map { meeting(id: $0, owner: 200, miles: Double($0) + 5) }

        let owners = AreaProximity.owners(of: meetings, in: tree)

        #expect(owners.map(\.id) == [100])
        #expect(owners.count == 1)
    }

    @Test("Rows arrive unsorted and are ordered by the server's distance")
    func sortsByDistanceBeforeSampling() {
        // Deliberately out of order: the three nearest belong to 200.
        let meetings = [
            meeting(id: 1, owner: 100, miles: 9.0),
            meeting(id: 2, owner: 200, miles: 0.4),
            meeting(id: 3, owner: 100, miles: 8.0),
            meeting(id: 4, owner: 200, miles: 0.6),
            meeting(id: 5, owner: 200, miles: 0.8),
        ]
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 200)
    }

    @Test("The vote is a plurality, not simply the nearest meeting's owner")
    func pluralityCanBeatTheNearestSingleRow() {
        // The distinction the rule's name makes easy to miss: 100 owns the single
        // nearest meeting, but 200 owns most of the window and wins. An
        // implementation that took the nearest row's owner would answer 100.
        let meetings = [
            meeting(id: 1, owner: 100, miles: 0.2),
            meeting(id: 2, owner: 200, miles: 1.0),
            meeting(id: 3, owner: 200, miles: 1.2),
            meeting(id: 4, owner: 200, miles: 1.5),
        ]
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 200)
    }

    // MARK: - Tie-breaking

    @Test("A tie is broken by the nearer meeting")
    func tieBrokenByNearest() {
        // Two each. 100's nearest is 1.0 mi, 200's is 2.0 mi.
        let meetings = [
            meeting(id: 1, owner: 100, miles: 1.0),
            meeting(id: 2, owner: 200, miles: 2.0),
            meeting(id: 3, owner: 100, miles: 7.0),
            meeting(id: 4, owner: 200, miles: 8.0),
        ]
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 100)
    }

    @Test("Equal counts and equal distance break on the lower id")
    func tieBrokenByIdWhenDistanceMatches() {
        // `Dictionary` iteration order is unspecified and `sorted` is not
        // stable, so without the id tiebreak this order could vary run to run.
        let meetings = [
            meeting(id: 1, owner: 200, miles: 1.0),
            meeting(id: 2, owner: 100, miles: 1.0),
            meeting(id: 3, owner: 200, miles: 5.0),
            meeting(id: 4, owner: 100, miles: 5.0),
        ]
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 100)
    }

    // MARK: - Missing distance

    @Test("When no row carries a distance, the server's own order decides")
    func fallsBackToServerOrderWithoutDistances() {
        // Six rows, all unplaceable. The window is the first five as sent, so the
        // sixth cannot vote — the same truncation as the sorted path.
        var meetings = (1...5).map { meeting(id: $0, owner: 100, miles: nil) }
        meetings.append(meeting(id: 6, owner: 200, miles: nil))

        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 100)
    }

    @Test("A row without a distance does not vote beside rows that have one")
    func unplacedRowsAreExcludedWhenOthersArePlaced() {
        // Pins the real behaviour, which the doc comment on this rule described
        // inaccurately for this case: a row with no distance is dropped
        // entirely once any other row carries one, not "voted last". Here 100's
        // only meeting is unplaceable, so it is absent from the result rather
        // than ranked below 200.
        let meetings = [
            meeting(id: 1, owner: 100, miles: nil),
            meeting(id: 2, owner: 200, miles: 0.5),
        ]
        let owners = AreaProximity.owners(of: meetings, in: tree)

        #expect(owners.map(\.id) == [200])
        #expect(AreaProximity.nearestOwner(of: meetings, in: tree)?.id == 200)
    }

    // MARK: - Nothing to resolve

    @Test("No meetings resolves to no Area rather than a wrong one")
    func emptyMeetings() {
        #expect(AreaProximity.owners(of: [], in: tree).isEmpty)
        #expect(AreaProximity.nearestOwner(of: [], in: tree) == nil)
    }

    @Test("An unloaded graph resolves to no Area")
    func nilTree() {
        let meetings = [meeting(owner: 100, miles: 1.0)]
        #expect(AreaProximity.owners(of: meetings, in: nil).isEmpty)
        #expect(AreaProximity.nearestOwner(of: meetings, in: nil) == nil)
    }

    @Test("An owner absent from the graph is dropped, not rendered")
    func unknownOwnerIsDropped() {
        // Service body ids are only unique per root server, and the graph may be
        // a different server's. An id that resolves to nothing cannot become an
        // Area, and must not suppress a resolvable one.
        let meetings = [
            meeting(id: 1, owner: 999, miles: 0.1),
            meeting(id: 2, owner: 100, miles: 1.0),
        ]
        #expect(AreaProximity.owners(of: meetings, in: tree).map(\.id) == [100])
    }
}

/// Tests for the Area picker's discovery fetch, now that it goes through
/// `AreaStore`'s injected client instead of a client constructed in the view.
///
/// ## Why these matter
/// `AreaPickerView` is the only view that did network work, and it built its own
/// `AggregatorClient`, so the URL it produced and the rows it decoded were
/// unreachable from tests. Routing the call through `AreaStore` puts it behind
/// the same seamed client every other store already uses, and `StubURLProtocol`
/// then exercises the real URL build and real decode — the layer that has been
/// wrong before.
@Suite("Area resolution")
@MainActor
struct AreaResolutionTests {

    private func tempStore() -> FileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyBMLTArea-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStore(testDirectory: dir)
    }

    /// A BMLT row shaped like a `geo_width` response, which is the only query
    /// that populates `distance_in_miles`.
    private func geoRow(id: Int, owner: Int, miles: String) -> String {
        """
        {
          "id_bigint": "\(id)",
          "meeting_name": "Group",
          "weekday_tinyint": "2",
          "start_time": "19:00:00",
          "duration_time": "01:00:00",
          "time_zone": "",
          "location_text": "",
          "location_street": "",
          "location_municipality": "San Diego",
          "location_postal_code_1": "92101",
          "location_info": "",
          "virtual_meeting_link": null,
          "virtual_meeting_additional_info": null,
          "service_body_bigint": "\(owner)",
          "service_body_name": "Area \(owner)",
          "formats": "O",
          "venue_type": "1",
          "latitude": "32.7157",
          "longitude": "-117.1611",
          "distance_in_miles": "\(miles)",
          "distance_in_km": "1.6",
          "root_server_id": 38
        }
        """
    }

    private func jsonPayload(_ rows: [String]) -> String {
        "[\(rows.joined(separator: ","))]"
    }

    private func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    @Test("The nearby lookup goes through the injected session")
    func fetchesThroughInjectedClient() async throws {
        let token = UUID().uuidString
        let session = StubURLProtocol.session(token, responses: [
            .json(jsonPayload([geoRow(id: 148884, owner: 100, miles: "0.9")])),
        ])
        let store = AreaStore(store: tempStore(), client: AggregatorClient(session: session))

        let nearby = try await store.meetingsNear(latitude: 32.7157,
                                                 longitude: -117.1611,
                                                 radiusMiles: 25)

        #expect(nearby.count == 1)
        #expect(nearby.first?.serviceBodyID == 100)
        #expect(nearby.first?.distanceMiles == 0.9)

        // The request that was really built. Asserting the items rather than
        // trusting the query case means a renamed parameter cannot slip through:
        // the aggregator ignores unknown parameters and still returns 200.
        let url = try #require(StubURLProtocol.urls(for: token).first)
        let items = queryItems(url)
        #expect(items.first { $0.name == "switcher" }?.value == "GetSearchResults")
        #expect(items.first { $0.name == "lat_val" }?.value == "32.7157")
        #expect(items.first { $0.name == "long_val" }?.value == "-117.1611")
        #expect(items.first { $0.name == "geo_width" }?.value == "25.0")
    }

    @Test("A radius response resolves to the Area that owns the nearest meetings")
    func nearbyMeetingsResolveToAnArea() async throws {
        let session = StubURLProtocol.session(responses: [
            .json(jsonPayload([
                geoRow(id: 1, owner: 200, miles: "12.0"),
                geoRow(id: 2, owner: 100, miles: "0.9"),
                geoRow(id: 3, owner: 100, miles: "1.4"),
            ])),
        ])
        let store = AreaStore(store: tempStore(), client: AggregatorClient(session: session))
        let tree = ServiceBodyTree([
            ServiceBody(id: 100, parentID: nil, name: "Alpha Area", description: nil,
                        type: "AS", url: nil, helpline: "", worldID: nil, rootServerID: 38),
            ServiceBody(id: 200, parentID: nil, name: "Beta Area", description: nil,
                        type: "AS", url: nil, helpline: "", worldID: nil, rootServerID: 38),
        ])

        let nearby = try await store.meetingsNear(latitude: 32.7157,
                                                 longitude: -117.1611,
                                                 radiusMiles: 25)

        #expect(nearby.count == 3)
        #expect(AreaProximity.nearestOwner(of: nearby, in: tree)?.id == 100)
    }

    @Test("An empty neighbourhood selects no Area rather than a wrong one")
    func emptyNeighbourhoodSelectsNothing() async throws {
        // A real, successful, empty result — distinct from a failed query. The
        // view must not fall back to some other Area, and must not treat this as
        // an error either.
        let session = StubURLProtocol.session(responses: [.json("[]")])
        let store = AreaStore(store: tempStore(), client: AggregatorClient(session: session))
        let tree = ServiceBodyTree([
            ServiceBody(id: 100, parentID: nil, name: "Alpha Area", description: nil,
                        type: "AS", url: nil, helpline: "", worldID: nil, rootServerID: 38),
        ])

        let nearby = try await store.meetingsNear(latitude: 0,
                                                 longitude: 0,
                                                 radiusMiles: 25)

        #expect(nearby.isEmpty)
        #expect(AreaProximity.nearestOwner(of: nearby, in: tree) == nil)
    }

    @Test("A failed lookup throws instead of reporting an empty neighbourhood")
    func failedLookupThrows() async {
        // The view tells these apart, and the distinction is user-visible: a
        // network failure is worth retrying, "no areas found" is not. If this
        // ever returned `[]` the two would collapse into the same wrong advice.
        let session = StubURLProtocol.session(responses: [.failure(URLError(.timedOut))])
        let store = AreaStore(store: tempStore(), client: AggregatorClient(session: session))

        do {
            _ = try await store.meetingsNear(latitude: 32.7157,
                                             longitude: -117.1611,
                                             radiusMiles: 25)
            Issue.record("Expected the lookup to throw, but it returned a result")
        } catch {
            // Expected.
        }
    }
}
