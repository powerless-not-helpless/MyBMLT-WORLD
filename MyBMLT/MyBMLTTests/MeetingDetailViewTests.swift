import Testing
import SwiftUI
@testable import MyBMLTUSA

/// Regression tests for rendering `MeetingDetailView` without the composition
/// root in the environment.
///
/// ## Why these exist
/// `@Environment(UserLists.self) private var lists: UserLists` **traps** when
/// the value is absent. Verified against this exact view before the fix:
///
/// ```
/// Fatal error: No Observable object of type UserLists found.
/// A View.environmentObject(_:) for UserLists may be missing as an ancestor.
/// ```
///
/// That is a hard crash, not a compile error, and nothing in the type system
/// warns about it. It also made the view unrenderable in a preview or any test
/// host that does not build the full app environment.
///
/// The view now declares `UserLists?`, which selects the optional `Environment`
/// initialiser and yields `nil` instead. These tests pin that, because a future
/// edit that "tidies up" the optional back to a non-optional would silently
/// reintroduce the crash.
///
/// Note on failure mode: a trap kills the whole test process, so a regression
/// here does not appear as one failed expectation — it aborts the run. That is
/// precisely why this is worth a dedicated test.
@MainActor
@Suite("Meeting detail rendering")
struct MeetingDetailViewTests {

    private func sampleMeeting() -> Meeting {
        Meeting(
            id: 148884, rootServerID: 38, name: "Wednesday Night Group",
            weekday: 4, startTime: "19:30:00", duration: "01:30:00",
            locationName: "Clubhouse", street: "123 Main St",
            city: "San Diego", zip: "92101", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: ["O", "D"],
            serviceBodyID: 2313, serviceBodyName: "SDICR", venueType: 1,
            latitude: 32.7157, longitude: -117.1611, timeZoneID: "America/Los_Angeles",
            distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Renders without UserLists in the environment instead of trapping")
    func rendersWithoutListsEnvironment() {
        let view = MeetingDetailView(meeting: sampleMeeting())

        // Touching `body` is what exercised the environment lookup and trapped
        // before the fix. Reaching the next line is the assertion.
        _ = view.body
    }

    @Test("Renders a virtual meeting without UserLists in the environment")
    func rendersVirtualWithoutListsEnvironment() {
        // A different set of sections (online block instead of location), so the
        // environment is resolved on a second code path too.
        let virtual = Meeting(
            id: 2, rootServerID: 38, name: "Zoom Group", weekday: 2,
            startTime: "08:00:00", duration: "01:00:00", locationName: "",
            street: "", city: "", zip: "", locationInfo: "",
            virtualLink: "https://zoom.us/j/123456789",
            virtualInfo: "Passcode: 12345", formats: [], serviceBodyID: 2313,
            serviceBodyName: "", venueType: 2, latitude: nil, longitude: nil,
            timeZoneID: "", distanceMiles: nil, distanceKilometers: nil
        )

        _ = MeetingDetailView(meeting: virtual).body
    }

    @Test("Renders inside a preview-equivalent host with no stores injected")
    func rendersInBareHost() {
        // Mirrors what a #Preview block does: a bare NavigationStack with no
        // .environment(...) applied by the app's composition root.
        let host = NavigationStack {
            MeetingDetailView(meeting: sampleMeeting())
        }
        _ = host.body
    }
}
