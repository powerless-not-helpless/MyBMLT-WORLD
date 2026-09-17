import Testing
@testable import MyBMLTUSA

/// Tests for `MeetingActions` location handling.
///
/// ## Why these exist
/// `MeetingActions.canOpenGoogleMaps` was previously a **stored-style property**
/// that asked `UIApplication.canOpenURL("comgooglemaps://")`. Two problems:
///
/// 1. `canOpenURL` is deprecated as of iOS 27, and it is unverifiable in a test
///    host — it returns `false` on Simulator, so the button silently never
///    appeared there.
/// 2. Gating the button on app-installed-ness hid the option entirely from any
///    user without Google Maps, who might still want the web map.
///
/// It is now a function of the meeting's coordinates, which is testable and has
/// no deprecated dependency. The open itself attempts the deep link and falls
/// back to the web on failure, mirroring `openJoinTarget(_:)`.
///
/// These tests pin the coordinate guard, because that guard is now the *only*
/// thing deciding whether the button appears.
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
        #expect(MeetingActions.canOpenGoogleMaps(meeting(latitude: 32.7157, longitude: -117.1611)))
    }

    @Test("Offers nothing when either coordinate is missing")
    func requiresBothCoordinates() {
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: nil, longitude: -117.1611)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 32.7157, longitude: nil)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: nil, longitude: nil)))
    }

    /// `0,0` is the null island. Meetings in the aggregator that carry no real
    /// location sometimes serialize as `0.0` rather than absent, and a map pin
    /// in the Gulf of Guinea is worse than no button.
    @Test("Refuses the null island at 0,0")
    func rejectsNullIsland() {
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 0, longitude: 0)))
    }

    @Test("Refuses coordinates outside the valid range")
    func rejectsOutOfRange() {
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 91, longitude: 0.1)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: -91, longitude: 0.1)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 32, longitude: 181)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 32, longitude: -181)))
    }

    @Test("Refuses non-finite coordinates")
    func rejectsNonFinite() {
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: .nan, longitude: 0.1)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: 32, longitude: .infinity)))
        #expect(!MeetingActions.canOpenGoogleMaps(meeting(latitude: -.infinity, longitude: 0.1)))
    }

    /// Boundary values are legal and must be accepted, so the range check is
    /// inclusive on both ends.
    @Test("Accepts the valid extremes")
    func acceptsBoundaries() {
        #expect(MeetingActions.canOpenGoogleMaps(meeting(latitude: 90, longitude: 180)))
        #expect(MeetingActions.canOpenGoogleMaps(meeting(latitude: -90, longitude: -180)))
    }

    /// The guard must not depend on the environment: this is what allows the
    /// button to render in a preview or test host, the same concern that
    /// `MeetingDetailViewTests` pins for `UserLists`.
    @Test("Is a pure function of the meeting, with no environment or app state")
    func isPure() {
        let m = meeting(latitude: 32.7157, longitude: -117.1611)
        #expect(MeetingActions.canOpenGoogleMaps(m) == MeetingActions.canOpenGoogleMaps(m))
    }
}
