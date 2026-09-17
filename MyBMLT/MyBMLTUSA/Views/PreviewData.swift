import SwiftUI

/// Sample meetings for SwiftUI previews.
///
/// ## Why this is `#if DEBUG`
/// Previews and their fixtures must not ship. `Meeting` is a large struct with
/// 22 members and no memberwise defaults (they are all `let`), so writing a
/// literal inline in every preview is noisy and drifts. One fixture per shape
/// keeps the previews readable and makes the shapes explicit.
///
/// ## Why previews exist here at all
/// Building them surfaced a real crash: `MeetingDetailView` and `MeetingCard`
/// both took `@Environment(UserLists.self)` non-optionally, which **traps** when
/// the value is absent rather than failing to compile. Verified:
///
/// ```
/// Fatal error: No Observable object of type UserLists found.
/// ```
///
/// Neither view could be previewed, and nothing warned about it. Both now take
/// `UserLists?` and degrade instead, so these previews render without the
/// composition root. `MeetingDetailViewTests` pins that behaviour.
#if DEBUG
enum PreviewData {

    /// An in-person meeting with a full address and coordinates.
    static let inPerson = Meeting(
        id: 148884, rootServerID: 38, name: "Wednesday Night Group",
        weekday: 4, startTime: "19:30:00", duration: "01:30:00",
        locationName: "North Park Clubhouse", street: "2930 University Ave",
        city: "San Diego", zip: "92104",
        locationInfo: "Enter through the side door on Utah St.",
        virtualLink: nil, virtualInfo: nil, formats: ["O", "D", "WC"],
        serviceBodyID: 2313, serviceBodyName: "San Diego Imperial Counties Region",
        venueType: 1, latitude: 32.7481, longitude: -117.1298,
        timeZoneID: "America/Los_Angeles",
        distanceMiles: nil, distanceKilometers: nil
    )

    /// A virtual meeting, including a passcode that lives only in
    /// `virtualInfo` — the real shape the password extractor must handle.
    static let virtual = Meeting(
        id: 148885, rootServerID: 38, name: "Midday Zoom Group",
        weekday: 3, startTime: "12:00:00", duration: "01:00:00",
        locationName: "", street: "", city: "", zip: "", locationInfo: "",
        virtualLink: "https://zoom.us/j/9163380135",
        virtualInfo: "Zoom ID: 916 338 0135, Passcode: 12345",
        formats: ["VM", "O", "JT"], serviceBodyID: 2313,
        serviceBodyName: "San Diego Imperial Counties Region",
        venueType: 2, latitude: nil, longitude: nil, timeZoneID: "",
        distanceMiles: nil, distanceKilometers: nil
    )

    /// A hybrid meeting: somewhere to go *and* a link to join.
    static let hybrid = Meeting(
        id: 148887, rootServerID: 38, name: "Friday Speaker Meeting",
        weekday: 6, startTime: "20:00:00", duration: "01:30:00",
        locationName: "Alano Club", street: "1944 30th St",
        city: "San Diego", zip: "92102", locationInfo: "",
        virtualLink: "https://us02web.zoom.us/j/88552200",
        virtualInfo: "Passcode: 998877", formats: ["HY", "SD", "O"],
        serviceBodyID: 2313, serviceBodyName: "San Diego Imperial Counties Region",
        venueType: 3, latitude: 32.7276, longitude: -117.1301,
        timeZoneID: "America/Los_Angeles",
        distanceMiles: nil, distanceKilometers: nil
    )

    /// A meeting in a different time zone, which exercises the "Times shown in
    /// …" notice rather than silently showing an unlabelled local time.
    static let otherZone = Meeting(
        id: 200, rootServerID: 1, name: "Broadway Group",
        weekday: 2, startTime: "18:00:00", duration: "01:00:00",
        locationName: "Community Center", street: "100 Broadway",
        city: "New York", zip: "10007", locationInfo: "",
        virtualLink: nil, virtualInfo: nil, formats: ["O", "D"],
        serviceBodyID: 1, serviceBodyName: "Greater New York Region",
        venueType: 1, latitude: 40.7130, longitude: -74.0059,
        timeZoneID: "America/New_York",
        distanceMiles: nil, distanceKilometers: nil
    )

    /// The states the detail banner can be in, for previewing them side by side.
    ///
    /// `UserLists` is injected directly rather than through the app's
    /// composition root, so each preview shows a specific state without needing
    /// a network or a populated store.
    @MainActor
    static func lists(favorite: Meeting? = nil,
                      exploring: Meeting? = nil,
                      missing: Meeting? = nil,
                      changed: Meeting? = nil) -> UserLists {
        let lists = UserLists()
        if let favorite { lists.favorites.toggle(favorite) }
        if let exploring { lists.explore.toggle(exploring) }
        if let missing {
            lists.favorites.toggle(missing)
            // Two clean observations, matching `missingConfirmationsRequired`.
            // Going through the real API keeps the preview honest about how the
            // banner is actually reached.
            lists.favorites.recordObservations(requested: [missing.uid], returned: [])
            lists.favorites.recordObservations(requested: [missing.uid], returned: [])
        }
        if let changed {
            lists.favorites.toggle(changed)
            let moved = Meeting(
                id: changed.id, rootServerID: changed.rootServerID, name: changed.name,
                weekday: changed.weekday, startTime: "21:15:00",
                duration: changed.duration, locationName: changed.locationName,
                street: changed.street, city: changed.city, zip: changed.zip,
                locationInfo: changed.locationInfo, virtualLink: changed.virtualLink,
                virtualInfo: changed.virtualInfo, formats: changed.formats,
                serviceBodyID: changed.serviceBodyID,
                serviceBodyName: changed.serviceBodyName, venueType: changed.venueType,
                latitude: changed.latitude, longitude: changed.longitude,
                timeZoneID: changed.timeZoneID, distanceMiles: nil,
                distanceKilometers: nil
            )
            lists.favorites.updateRecords(from: [moved])
        }
        return lists
    }
}
#endif
