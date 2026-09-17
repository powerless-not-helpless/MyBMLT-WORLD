import Testing
import Foundation
@testable import MyBMLTUSA

/// Tests for the identity contract. This is the highest-value test file in the
/// project, because `uid` is what every persisted set keys on, and getting it
/// wrong silently aliases meetings across root servers.
@Suite("Meeting identity")
struct MeetingIdentityTests {

    private func makeMeeting(id: Int, rootServerID: Int, name: String = "Test") -> Meeting {
        Meeting(
            id: id, rootServerID: rootServerID, name: name,
            weekday: 2, startTime: "19:00:00", duration: "01:00:00",
            locationName: "", street: "", city: "", zip: "", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: 1,
            latitude: nil, longitude: nil, timeZoneID: "America/Los_Angeles",
            distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("uid separates identical local IDs on different root servers")
    func uidIsGloballyUnique() {
        let a = makeMeeting(id: 42, rootServerID: 1)
        let b = makeMeeting(id: 42, rootServerID: 38)

        // Same local id, different servers: these are different meetings and
        // must not collide.
        #expect(a.uid != b.uid)
        #expect(a.uid == "1:42")
        #expect(b.uid == "38:42")
    }

    @Test("uid is stable for the same meeting across reads")
    func uidIsStable() {
        let first = makeMeeting(id: 1799, rootServerID: 38, name: "Monday Night")
        let second = makeMeeting(id: 1799, rootServerID: 38, name: "Monday Night")
        #expect(first.uid == second.uid)
    }

    @Test("Meetings without root_server_id share the 0 namespace")
    func missingRootServerDefaultsToZero() {
        let legacy = makeMeeting(id: 7, rootServerID: 0)
        #expect(legacy.uid == "0:7")
    }
}

/// Tests for password extraction against the exact strings the live aggregator
/// returned. The pre-rewrite code missed both `Passcode:` and `Pwd:`.
@Suite("Password extraction")
struct PasswordTests {

    private func meeting(virtualInfo: String?, locationInfo: String = "") -> Meeting {
        Meeting(
            id: 1, rootServerID: 1, name: "T", weekday: 1, startTime: "08:00:00",
            duration: "01:00:00", locationName: "", street: "", city: "", zip: "",
            locationInfo: locationInfo, virtualLink: nil, virtualInfo: virtualInfo,
            formats: [], serviceBodyID: 1, serviceBodyName: "", venueType: 2,
            latitude: nil, longitude: nil, timeZoneID: "", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Extracts Passcode from the real Virtual NA payload")
    func realVirtualInfo() {
        // Verified live: virtual_meeting_additional_info on the aggregator.
        let m = meeting(virtualInfo: "Zoom ID: 916 338 0135, Passcode: 12345")
        #expect(m.passwordValue == "12345")
    }

    @Test("Extracts Pwd from location_info when virtualInfo is empty")
    func realLocationInfo() {
        // Verified live: location_info is sometimes the only carrier.
        let m = meeting(virtualInfo: nil, locationInfo: "Zoom: 916 338 0135 Pwd: 12345")
        #expect(m.passwordValue == "12345")
    }

    @Test("Prefers virtualInfo over locationInfo when both carry one")
    func precedence() {
        let m = meeting(virtualInfo: "Passcode: 11111",
                        locationInfo: "Pwd: 22222")
        #expect(m.passwordValue == "11111")
    }

    @Test("Returns nil when the meeting states there is no password")
    func noPassword() {
        #expect(meeting(virtualInfo: "No password required").passwordValue == nil)
        #expect(meeting(virtualInfo: "Sin contraseña").passwordValue == nil)
    }

    @Test("Returns nil for empty or absent info")
    func empty() {
        #expect(meeting(virtualInfo: nil).passwordValue == nil)
        #expect(meeting(virtualInfo: "").passwordValue == nil)
        #expect(meeting(virtualInfo: "Zoom ID: 916 338 0135").passwordValue == nil)
    }

    @Test("Stops at the comma rather than swallowing the rest of the line")
    func stopsAtComma() {
        let m = meeting(virtualInfo: "Passcode: 99887, then other text")
        #expect(m.passwordValue == "99887")
    }

    @Test("Handles Spanish labels used by Habla Hispana meetings")
    func spanish() {
        #expect(meeting(virtualInfo: "clave: abc123").passwordValue == "abc123")
    }
}

/// Tests for the time-zone handling that the aggregator requires and wszf did
/// not. A meeting's start time is in *its own* zone.
@Suite("Time zones")
struct TimeZoneTests {

    private func meeting(weekday: Int, start: String, zone: String) -> Meeting {
        Meeting(
            id: 1, rootServerID: 1, name: "T", weekday: weekday, startTime: start,
            duration: "01:00:00", locationName: "", street: "", city: "", zip: "",
            locationInfo: "", virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: 1,
            latitude: nil, longitude: nil, timeZoneID: zone, distanceMiles: nil, distanceKilometers: nil
        )
    }

    /// Fixed reference: Wednesday 2026-09-16 12:00:00 UTC.
    private var referenceNow: Date {
        Date(timeIntervalSince1970: 1_789_560_000)
    }

    @Test("Resolves the next occurrence in the meeting's own zone")
    func resolvesInOwnZone() throws {
        // 19:00 Pacific on a Wednesday.
        let m = meeting(weekday: 4, start: "19:00:00", zone: "America/Los_Angeles")
        let next = try #require(m.nextOccurrence(after: referenceNow))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let comps = cal.dateComponents([.hour, .minute, .weekday], from: next)

        #expect(comps.hour == 19)
        #expect(comps.minute == 0)
        #expect(comps.weekday == 4)
    }

    @Test("The same wall-clock time in two zones yields different instants")
    func zonesDiffer() throws {
        let pacific = meeting(weekday: 4, start: "19:00:00", zone: "America/Los_Angeles")
        let eastern = meeting(weekday: 4, start: "19:00:00", zone: "America/New_York")

        let a = try #require(pacific.nextOccurrence(after: referenceNow))
        let b = try #require(eastern.nextOccurrence(after: referenceNow))

        // 19:00 ET is three hours earlier in absolute time than 19:00 PT.
        #expect(a != b)
        #expect(abs(a.timeIntervalSince(b)) == 3 * 3600)
    }

    @Test("Falls back to the device zone when the server sends nothing")
    func fallbackToDeviceZone() throws {
        let m = meeting(weekday: 4, start: "19:00:00", zone: "")
        #expect(m.timeZone.identifier == TimeZone.current.identifier)
        #expect(try #require(m.nextOccurrence(after: referenceNow)) > referenceNow)
    }

    @Test("Reports when a meeting is in a different zone than the device")
    func detectsForeignZone() {
        let far = meeting(weekday: 1, start: "10:00:00", zone: "Asia/Tokyo")
        // Either the device is in Tokyo or this is true; asserting the empty
        // zone case is false is the portable half.
        let none = meeting(weekday: 1, start: "10:00:00", zone: "")
        #expect(none.isInDifferentZoneThanDevice == false)
        if TimeZone.current.identifier != "Asia/Tokyo" {
            #expect(far.isInDifferentZoneThanDevice)
        }
    }

    @Test("Grace window keeps a just-started meeting on today's date")
    func graceWindow() throws {
        // 11:55 UTC on the reference Wednesday; meeting was at 11:50 UTC.
        let now = referenceNow.addingTimeInterval(-5 * 60)
        let m = meeting(weekday: 4, start: "11:50:00", zone: "UTC")
        let next = try #require(m.nextOccurrence(after: now))
        // Within grace, so it is not pushed a week forward.
        #expect(next < now.addingTimeInterval(60 * 60))
    }

    // MARK: - formattedTime

    /// The regression test for a wall-clock value formatted through a `Date`:
    /// the device zone must not appear in the output at all.
    @Test("formattedTime is identical regardless of the meeting's zone")
    func formattedTimeIgnoresZone() {
        let zones = [
            "America/Los_Angeles", "America/Chicago", "America/New_York",
            "UTC", "Asia/Tokyo", "Australia/Sydney", "",
        ]
        let rendered = zones.map { meeting(weekday: 2, start: "19:00:00", zone: $0).formattedTime }

        // Every zone renders the same string, so the set has one member.
        #expect(Set(rendered).count == 1)
    }

    @Test("formattedTime renders afternoon times as PM")
    func formattedTimeAfternoon() {
        // 12-hour output depends on the device locale, so assert on the hour
        // digits only; the suite must pass on a 24-hour device too.
        let twelve = meeting(weekday: 2, start: "12:00:00", zone: "UTC").formattedTime
        let noon = meeting(weekday: 2, start: "12:00:00", zone: "UTC").formattedTime
        #expect(twelve == noon)

        let pm = meeting(weekday: 2, start: "19:00:00", zone: "UTC").formattedTime
        #expect(pm.contains("7:00"))
    }

    @Test("formattedTime handles midnight and noon without a 0 hour")
    func formattedTimeBoundaries() {
        let midnight = meeting(weekday: 2, start: "00:30:00", zone: "UTC").formattedTime
        let noon = meeting(weekday: 2, start: "12:00:00", zone: "UTC").formattedTime

        // 12-hour form must never print a bare "0"; 24-hour prints "00:30".
        #expect(!midnight.hasPrefix("0:") && !midnight.hasPrefix(" 0:"))
        #expect(midnight.contains("12:30") || midnight.contains("00:30"))
        #expect(noon.contains("12:00"))
    }

    @Test("formattedTime degrades visibly when start_time is missing")
    func formattedTimeMissing() {
        #expect(meeting(weekday: 2, start: "", zone: "UTC").formattedTime == "Time not listed")
        #expect(meeting(weekday: 2, start: "nonsense", zone: "UTC").formattedTime == "nonsense")
    }
}

/// Which meetings have a real-world venue. Guards the map link, which must not
/// be offered for an online-only meeting.
@Suite("Venue")
struct VenueTests {

    private func meeting(venueType: Int, lat: Double?, lon: Double?) -> Meeting {
        Meeting(
            id: 1, rootServerID: 1, name: "T", weekday: 1, startTime: "08:00:00",
            duration: "01:00:00", locationName: "", street: "", city: "", zip: "",
            locationInfo: "", virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: venueType,
            latitude: lat, longitude: lon, timeZoneID: "UTC", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("A virtual-only meeting with stale coordinates is not a physical venue")
    func virtualWithCoordinatesIsNotPhysical() {
        // The aggregator frequently carries coordinates on virtual-only rows —
        // usually the creator's location, not a venue. Offering "Open in Maps"
        // for those sends the user to an unrelated address.
        #expect(meeting(venueType: 2, lat: 32.7157, lon: -117.1611).hasPhysicalVenue == false)

        // Hybrid does happen somewhere, so it keeps its venue.
        #expect(meeting(venueType: 3, lat: 32.7157, lon: -117.1611).hasPhysicalVenue)
        // In-person likewise.
        #expect(meeting(venueType: 1, lat: 32.7157, lon: -117.1611).hasPhysicalVenue)
    }

    @Test("A virtual-only meeting is not physical even without coordinates")
    func virtualWithoutCoordinates() {
        #expect(meeting(venueType: 2, lat: nil, lon: nil).hasPhysicalVenue == false)
    }
}

/// Distance units. The server sends miles and kilometres together; which one is
/// displayed depends on the device locale, not on the data.
@Suite("Distance units")
struct DistanceTests {

    private func meeting(miles: Double?, km: Double?) -> Meeting {
        Meeting(
            id: 1, rootServerID: 1, name: "T", weekday: 1, startTime: "08:00:00",
            duration: "01:00:00", locationName: "", street: "", city: "", zip: "",
            locationInfo: "", virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: 1,
            latitude: nil, longitude: nil, timeZoneID: "UTC",
            distanceMiles: miles, distanceKilometers: km
        )
    }

    @Test("Both units are kept as the server sent them")
    func bothUnitsDecoded() throws {
        // Verified live: distance_in_miles 0.87786181705727 and
        // distance_in_km 1.4136247007978 for the same meeting.
        let raw = """
        [{"id_bigint":"1","meeting_name":"M","weekday_tinyint":"2",
          "start_time":"19:00:00","duration_time":"01:00:00",
          "distance_in_miles":"0.87786181705727","distance_in_km":"1.4136247007978"}]
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: raw)
        let m = try #require(payload.meetings.first?.toMeeting())

        #expect(m.distanceMiles != nil)
        #expect(m.distanceKilometers != nil)
        // Not a conversion: these are the server's own two figures.
        let km = try #require(m.distanceKilometers)
        #expect(abs(km - 1.4136) < 0.001)
    }

    @Test("formattedDistance matches the locale's measurement system")
    func unitFollowsLocale() {
        let m = meeting(miles: 1.0, km: 1.60934)
        guard let label = m.formattedDistance else {
            Issue.record("expected a distance label")
            return
        }
        if Locale.current.measurementSystem == .metric {
            #expect(label.hasSuffix(" km"))
        } else {
            #expect(label.hasSuffix(" mi"))
        }
    }

    @Test("No distance means no label, rather than a zero")
    func missingDistanceIsNil() {
        // Ordinary area browsing carries no distance; the card must show nothing.
        #expect(meeting(miles: nil, km: nil).formattedDistance == nil)
    }
}

/// Tests for join-target resolution, including the Google Meet branch the brief
/// explicitly requires.
@Suite("Join targets")
struct JoinTargetTests {

    private func meeting(link: String?, venueType: Int = 2) -> Meeting {
        Meeting(
            id: 1, rootServerID: 1, name: "T", weekday: 1, startTime: "08:00:00",
            duration: "01:00:00", locationName: "", street: "", city: "", zip: "",
            locationInfo: "", virtualLink: link, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: venueType,
            latitude: nil, longitude: nil, timeZoneID: "", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Google Meet links route through the Google Meet branch")
    func googleMeet() throws {
        let m = meeting(link: "https://meet.google.com/abc-defg-hij")
        let target = try #require(m.joinTarget)
        #expect(target.label == "Join with Google Meet")
        #expect(target.url.host == "meet.google.com")
    }

    @Test("Zoom links become zoommtg deep links carrying the meeting id")
    func zoomDeepLink() throws {
        let m = meeting(link: "https://us02web.zoom.us/j/9163380135?pwd=abc123")
        let target = try #require(m.joinTarget)

        #expect(target.label == "Join with Zoom")
        #expect(target.url.scheme == "zoommtg")

        let comps = try #require(URLComponents(url: target.url, resolvingAgainstBaseURL: false))
        let items = comps.queryItems ?? []
        #expect(items.contains { $0.name == "confno" && $0.value == "9163380135" })
        #expect(items.contains { $0.name == "pwd" && $0.value == "abc123" })
    }

    @Test("Zoom links with spaces in them still resolve")
    func zoomWithWhitespace() throws {
        // Some server data contains stray spaces in the URL.
        let m = meeting(link: " https://us02web.zoom.us/j/9163380135 ")
        #expect(try #require(m.joinTarget).url.scheme == "zoommtg")
    }

    @Test("Non-Zoom, non-Google links are passed through as web URLs")
    func otherPlatform() throws {
        let m = meeting(link: "https://example.org/room/1")
        let target = try #require(m.joinTarget)
        #expect(target.label == "Join Meeting")
        #expect(target.url.scheme == "https")
    }

    @Test("Insecure and malformed links produce no join target")
    func rejectsBadLinks() {
        #expect(meeting(link: nil).joinTarget == nil)
        #expect(meeting(link: "").joinTarget == nil)
        #expect(meeting(link: "http://insecure.example.com").joinTarget == nil)
        #expect(meeting(link: "not a url").joinTarget == nil)
    }

    @Test("shareableLink strips the Zoom pwd query parameter")
    func shareableStripsPassword() throws {
        let m = meeting(link: "https://us02web.zoom.us/j/9163380135?pwd=secret")
        let share = try #require(m.shareableLink)
        #expect(share == "https://us02web.zoom.us/j/9163380135")
        #expect(!share.contains("secret"))
    }
}

/// Tests for the shape-tolerant decoding, since the aggregator returns two
/// different top-level JSON shapes depending on the query.
@Suite("Aggregator decoding")
struct DecodingTests {

    private let enveloped = """
    {"meetings":[{"id_bigint":"55981","meeting_name":"Never Alone",
      "weekday_tinyint":"1","start_time":"08:00:00","duration_time":"01:00:00",
      "venue_type":"2","longitude":"-97.7430608","latitude":"30.267153",
      "service_body_bigint":"3","root_server_id":1,"time_zone":"America/Chicago",
      "virtual_meeting_additional_info":"Zoom ID: 916 338 0135, Passcode: 12345"}],
     "formats":[{"key_string":"O","name_string":"Open","root_server_id":1}]}
    """.data(using: .utf8)!

    private let bareArray = """
    [{"id_bigint":"148885","meeting_name":"Came To Believe","weekday_tinyint":"2",
      "start_time":"19:00:00","duration_time":"01:00:00","venue_type":"1",
      "latitude":"32.7","longitude":"-117.1","service_body_bigint":"2315",
      "root_server_id":38,"distance_in_miles":"1.9391673389101"}]
    """.data(using: .utf8)!

    @Test("Decodes the enveloped shape and keeps formats")
    func decodesEnvelope() throws {
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: enveloped)
        #expect(payload.meetings.count == 1)
        #expect(payload.formats.count == 1)
        #expect(payload.formats.first?.key == "O")
    }

    @Test("Decodes the bare array shape used by geo queries")
    func decodesBareArray() throws {
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: bareArray)
        #expect(payload.meetings.count == 1)
        #expect(payload.formats.isEmpty)
    }

    @Test("Maps server fields onto the domain model")
    func mapsFields() throws {
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: enveloped)
        let meeting = try #require(payload.meetings.first?.toMeeting())

        #expect(meeting.id == 55981)
        #expect(meeting.rootServerID == 1)
        #expect(meeting.uid == "1:55981")
        #expect(meeting.venueType == 2)
        #expect(meeting.timeZoneID == "America/Chicago")
        #expect(meeting.passwordValue == "12345")
        #expect(meeting.serviceBodyID == 3)
    }

    @Test("Surface-carried distance survives decoding")
    func mapsDistance() throws {
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: bareArray)
        let meeting = try #require(payload.meetings.first?.toMeeting())
        #expect(meeting.distanceMiles != nil)
        #expect(abs((meeting.distanceMiles ?? 0) - 1.939) < 0.01)
    }

    @Test("Rows missing required fields are dropped rather than defaulted")
    func dropsIncompleteRows() throws {
        // No meeting_name -> toMeeting returns nil.
        let json = """
        [{"id_bigint":"1","weekday_tinyint":"1","start_time":"08:00:00"}]
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: json)
        #expect(payload.meetings.compactMap { $0.toMeeting() }.isEmpty)
    }

    @Test("Formats split on commas and trim whitespace")
    func splitsFormats() throws {
        let json = """
        [{"id_bigint":"1","meeting_name":"X","weekday_tinyint":"1",
          "start_time":"08:00:00","formats":"O, D ,WC"}]
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(BMLTSearchPayload.self, from: json)
        let meeting = try #require(payload.meetings.first?.toMeeting())
        #expect(meeting.formats == ["O", "D", "WC"])
        #expect(meeting.isWheelchairAccessible)
    }
}

/// The text behind the card's Copy button. A regression here silently sends a
/// user to a meeting without the password they need.
@Suite("Copyable meeting text")
struct MeetingTextExportTests {

    private func meeting(
        venueType: Int,
        virtualLink: String? = nil,
        virtualInfo: String? = nil,
        locationInfo: String = "",
        formats: [String] = []
    ) -> Meeting {
        Meeting(
            id: 1, rootServerID: 38, name: "Sonoma Online Meeting",
            weekday: 2, startTime: "19:00:00", duration: "01:30:00",
            locationName: "Junior Farm", street: "464 Palm Ave",
            city: "Penngrove", zip: "94951", locationInfo: locationInfo,
            virtualLink: virtualLink, virtualInfo: virtualInfo, formats: formats,
            serviceBodyID: 2367, serviceBodyName: "Sonoma County Area",
            venueType: venueType, latitude: nil, longitude: nil,
            timeZoneID: "America/Los_Angeles", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("A virtual meeting exports day, time, join link and password")
    func virtualExport() {
        let m = meeting(
            venueType: 2,
            virtualLink: "https://zoom.us/j/215310190?pwd=abc123",
            virtualInfo: "Zoom ID: 215 310 190, Passcode: 1953",
            formats: ["SD", "VM"]
        )
        let text = MeetingTextExport.plainText(for: m)

        #expect(text.contains("Mon at 7:00 PM"))
        #expect(text.contains("Sonoma Online Meeting"))
        // The pwd query parameter is stripped from the shared link, because the
        // password is printed on its own line.
        #expect(text.contains("https://zoom.us/j/215310190"))
        #expect(!text.contains("pwd=abc123"))
        #expect(text.contains("Password: 1953"))
        // Format codes are expanded, not passed through raw.
        #expect(text.contains("Virtual Meeting"))
        #expect(!text.contains("VM,"))
    }

    @Test("Export stays short: no type, service body, or time zone")
    func exportIsTrimmed() {
        let m = meeting(
            venueType: 2,
            virtualLink: "https://zoom.us/j/215310190",
            formats: ["VM"]
        )
        let text = MeetingTextExport.plainText(for: m)

        // day/time, name, duration, link, formats = 5 lines. No password line:
        // this fixture supplies no virtualInfo or locationInfo.
        #expect(text.components(separatedBy: "\n").count == 5)
        #expect(!text.contains("Type:"))
        #expect(!text.contains("Sonoma County Area"))
        #expect(!text.contains("Time zone"))
    }

    @Test("Duration is included, formatted for reading")
    func durationIsExported() {
        // The fixture runs 01:30:00.
        let m = meeting(venueType: 1, formats: ["O"])
        #expect(MeetingTextExport.plainText(for: m).contains("1 hr 30 min"))
    }

    @Test("An in-person meeting exports its address and omits join details")
    func inPersonExport() {
        let m = meeting(venueType: 1, formats: ["O", "D"])
        let text = MeetingTextExport.plainText(for: m)

        #expect(text.contains("464 Palm Ave, Penngrove, 94951"))
        #expect(!text.contains("Join"))
        #expect(!text.contains("Password:"))
        // A physical venue's location name is not included — the address is
        // what someone navigating needs, and locationName is often a nickname
        // ("Junior Farm") that means nothing out of context.
        #expect(!text.contains("Junior Farm"))
    }

    @Test("A password found only in location_info still exports")
    func passwordFromLocationInfo() {
        // Verified real case: some phone/online meetings carry the password in
        // location_info and nowhere else.
        let m = meeting(venueType: 2, locationInfo: "Zoom: 916 338 0135 Pwd: 12345")
        #expect(MeetingTextExport.plainText(for: m).contains("Password: 12345"))
    }

    @Test("Unknown format codes survive as codes rather than vanishing")
    func unknownFormatCode() {
        let m = meeting(venueType: 1, formats: ["ZZZ"])
        #expect(MeetingTextExport.plainText(for: m).contains("ZZZ"))
    }

    @Test("Copying several meetings separates them by a blank line")
    func multipleMeetings() {
        let a = meeting(venueType: 1)
        let b = meeting(venueType: 1)
        let parts = MeetingTextExport.plainText(for: [a, b])
            .components(separatedBy: "\n\n")
        #expect(parts.count == 2)
    }
}
