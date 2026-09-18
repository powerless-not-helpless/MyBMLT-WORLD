import Testing
@testable import MyBMLTUSA

/// Tests for `MeetingActions` location handling.
///
/// ## Why these exist
/// The "Open in Maps" button is gated on `MeetingActions.canOpenInMaps`, a pure
/// function of the meeting's coordinates. It is the single guard behind both the
/// button's visibility and the open attempt, so it is pinned here.
///
/// The guard rejects absent, non-finite, out-of-range and `0,0` coordinates.
/// `0,0` matters because meetings with no real location sometimes serialize as
/// `0.0` rather than absent, and a pin in the Gulf of Guinea is worse than no
/// button.
///
/// This was previously a `canOpenURL("comgooglemaps://")` check. That was
/// removed along with the Google Maps option entirely: iOS ships Apple Maps, and
/// a second map target was neither needed nor verifiable in a test host.
@Suite("Meeting actions")
struct MeetingActionsTests {

    private func meeting(latitude: Double?, longitude: Double?) -> Meeting {
        Meeting(
            id: 148884, rootServerID: 38, name: "Wednesday Night Group",
            weekday: 4, startTime: "19:30:00", duration: "01:30:00",
            locationName: "Clubhouse", street: "123 Main St",
            city: "San Diego", zip: "92101", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: ["O", "D"],
            serviceBodyID: 2313, serviceBodyName: "SDICR", venueType: 1,
            latitude: latitude, longitude: longitude, timeZoneID: "America/Los_Angeles",
            distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Offers the button for a meeting with a real location")
    func offersForRealLocation() {
        #expect(MeetingActions.canOpenInMaps(meeting(latitude: 32.7157, longitude: -117.1611)))
    }

    @Test("Offers nothing when either coordinate is missing")
    func requiresBothCoordinates() {
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: nil, longitude: -117.1611)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 32.7157, longitude: nil)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: nil, longitude: nil)))
    }

    /// `0,0` is the null island. Meetings in the aggregator that carry no real
    /// location sometimes serialize as `0.0` rather than absent, and a map pin
    /// in the Gulf of Guinea is worse than no button.
    @Test("Refuses the null island at 0,0")
    func rejectsNullIsland() {
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 0, longitude: 0)))
    }

    @Test("Refuses coordinates outside the valid range")
    func rejectsOutOfRange() {
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 91, longitude: 0.1)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: -91, longitude: 0.1)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 32, longitude: 181)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 32, longitude: -181)))
    }

    @Test("Refuses non-finite coordinates")
    func rejectsNonFinite() {
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: .nan, longitude: 0.1)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: 32, longitude: .infinity)))
        #expect(!MeetingActions.canOpenInMaps(meeting(latitude: -.infinity, longitude: 0.1)))
    }

    /// Boundary values are legal and must be accepted, so the range check is
    /// inclusive on both ends.
    @Test("Accepts the valid extremes")
    func acceptsBoundaries() {
        #expect(MeetingActions.canOpenInMaps(meeting(latitude: 90, longitude: 180)))
        #expect(MeetingActions.canOpenInMaps(meeting(latitude: -90, longitude: -180)))
    }

    /// The guard must not depend on the environment: this is what allows the
    /// button to render in a preview or test host, the same concern that
    /// `MeetingDetailViewTests` pins for `UserLists`.
    @Test("Is a pure function of the meeting, with no environment or app state")
    func isPure() {
        let m = meeting(latitude: 32.7157, longitude: -117.1611)
        #expect(MeetingActions.canOpenInMaps(m) == MeetingActions.canOpenInMaps(m))
    }
}
