import Testing
import Foundation
@testable import MyBMLTUSA

/// Tests for request construction.
///
/// These exist because the aggregator's failure modes here are **silent**.
/// Verified live against `aggregator.bmltenabled.org`:
///
/// | Parameters sent                              | Result            |
/// |----------------------------------------------|-------------------|
/// | `meeting_ids=148884` + `root_server_ids[]=1`  | 0 rows (filtered) |
/// | `meeting_ids=148884` + `root_server_id=1`     | 1 row (ignored)   |
/// | `meeting_ids=148884` + `root_servers[]=1`     | 1 row (ignored)   |
/// | `meeting_ids=148884` + `server_ids[]=1`       | 1 row (ignored)   |
/// | `meeting_ids=148884,200` + `root_server_ids=38,1` | 1 row, not 2  |
/// | `meeting_ids=1,2,...,60` (no root filter)     | 13 rows, root 1 only |
///
/// Every one of those returns HTTP 200 with decodable JSON. A wrong parameter
/// name therefore cannot be caught by an error path — only by asserting on the
/// items we actually build.
@Suite("Aggregator request shape")
struct AggregatorClientTests {

    private let client = AggregatorClient()

    private func item(_ name: String, in items: [URLQueryItem]) -> [String] {
        items.filter { $0.name == name }.compactMap(\.value)
    }

    @Test("Scoped meeting fetch emits paired bracket-form root_server_ids")
    func scopedMeetingIDsUseBracketForm() {
        let items = client.queryItems(for: .meetingIDs(ids: [148884, 200],
                                                       rootServerIDs: [38, 1]))

        // Both ids present, each as its own bracket-form item.
        #expect(item("meeting_ids[]", in: items).sorted() == ["148884", "200"])
        // The plural bracket form, which is the only spelling verified to
        // filter. Singular and alternative spellings are silently ignored.
        #expect(item("root_server_ids[]", in: items).sorted() == ["1", "38"])
    }

    @Test("The comma form of root_server_ids is never emitted")
    func rootServerIDsAreNotCommaJoined() {
        let items = client.queryItems(for: .meetingIDs(ids: [1], rootServerIDs: [38, 1]))

        // A single "38,1" value is the silent-truncation bug: the server reads
        // only the first server and drops the rest.
        #expect(!item("root_server_ids[]", in: items).contains("38,1"))
        #expect(item("root_server_ids[]", in: items).count == 2)
    }

    @Test("An unscoped meeting fetch is not representable")
    func meetingIDsAlwaysCarryRootServerScope() {
        let items = client.queryItems(for: .meetingIDs(ids: [42], rootServerIDs: [7]))

        // Guards the aliasing hazard: id 42 exists on many root servers, and
        // without this filter the aggregator answers for whichever owns it
        // first. If this ever becomes empty, the fetch is unsafe.
        #expect(item("root_server_ids[]", in: items).isEmpty == false)
        #expect(item("root_server_ids[]", in: items) == ["7"])
    }

    @Test("Meeting ids are never comma-joined either")
    func meetingIDsUseRepeatedItems() {
        let items = client.queryItems(for: .meetingIDs(ids: [1, 2, 3],
                                                       rootServerIDs: [38]))

        #expect(item("meeting_ids[]", in: items) == ["1", "2", "3"])
    }

    @Test("Service body query keeps its single comma-joined services parameter")
    func serviceBodiesUnchanged() {
        let items = client.queryItems(for: .serviceBodies(ids: [2313], recursive: true))

        // This one *is* comma-joined and verified working (377 SDICR meetings).
        // The asymmetry with meeting ids is real, not an oversight.
        #expect(item("services[]", in: items) == ["2313"])
        #expect(item("recursive", in: items) == ["1"])
    }

    @Test("Geo query emits the verified parameter names")
    func geoUnchanged() {
        let items = client.queryItems(for: .geo(latitude: 32.7157,
                                                longitude: -117.1611,
                                                radiusMiles: 10))

        #expect(item("lat_val", in: items) == ["32.7157"])
        #expect(item("long_val", in: items) == ["-117.1611"])
        #expect(item("geo_width", in: items) == ["10.0"])
    }
}
