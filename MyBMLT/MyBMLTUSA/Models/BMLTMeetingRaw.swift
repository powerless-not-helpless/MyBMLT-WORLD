import Foundation

/// Raw BMLT JSON row. Every value is a **string** on the wire, including
/// numbers and coordinates — verified against the live aggregator.
///
/// The aggregator returns far more fields than we model; unknown keys are
/// ignored by `Codable` automatically.
nonisolated struct BMLTMeetingRaw: Codable {

    let id_bigint: String?
    let meeting_name: String?
    let weekday_tinyint: String?
    let start_time: String?
    let duration_time: String?
    let time_zone: String?

    let location_text: String?
    let location_street: String?
    let location_municipality: String?
    let location_postal_code_1: String?
    /// Sometimes the ONLY place a Zoom password appears.
    let location_info: String?

    let virtual_meeting_link: String?
    let virtual_meeting_additional_info: String?

    let service_body_bigint: String?
    let service_body_name: String?
    let formats: String?
    let venue_type: String?

    let latitude: String?
    let longitude: String?

    /// Present on the aggregator, ABSENT on bmlt.wszf.org.
    let root_server_id: Int?
    /// Present only on `geo_width` queries. Server-computed.
    let distance_in_miles: String?
    /// The same distance in kilometres, also sent on `geo_width` queries.
    /// Kept rather than derived, so a metric locale shows the server's figure.
    let distance_in_km: String?

    func toMeeting() -> Meeting? {
        guard
            let idStr = id_bigint, let id = Int(idStr),
            let name = meeting_name, !name.isEmpty,
            let wdStr = weekday_tinyint, let wd = Int(wdStr)
        else { return nil }

        let formatList = formats?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        return Meeting(
            id: id,
            // Default to 0 when absent. Any server without root_server_id in
            // its payload is a single-server deployment, so 0 is a safe
            // namespace for its `uid`s.
            rootServerID: root_server_id ?? 0,
            name: name,
            weekday: wd,
            startTime: start_time ?? "",
            duration: duration_time ?? "",
            locationName: location_text ?? "",
            street: location_street ?? "",
            city: location_municipality ?? "",
            zip: location_postal_code_1 ?? "",
            locationInfo: location_info ?? "",
            virtualLink: virtual_meeting_link,
            virtualInfo: virtual_meeting_additional_info,
            formats: formatList,
            serviceBodyID: Int(service_body_bigint ?? "") ?? 0,
            serviceBodyName: service_body_name ?? "",
            venueType: Int(venue_type ?? "") ?? 1,
            latitude: Double(latitude ?? ""),
            longitude: Double(longitude ?? ""),
            timeZoneID: time_zone ?? "",
            distanceMiles: Double(distance_in_miles ?? ""),
            distanceKilometers: Double(distance_in_km ?? "")
        )
    }
}

/// A BMLT format definition. Formats are **per-root-server**: verified 1,502
/// rows across the aggregator with only 309 unique `key_string` values, so the
/// same key legitimately means different things on different servers
/// (`O` = "Open" on most, "Meets 2nd wk of month" on root 10).
nonisolated struct BMLTFormat: Codable, Hashable {
    let key_string: String?
    let name_string: String?
    let root_server_id: Int?

    var key: String? {
        guard let k = key_string, !k.isEmpty else { return nil }
        return k
    }
}

/// The aggregator returns **two different top-level shapes** depending on
/// whether `get_used_formats=1` is in the query — verified:
///
///   with    → {"meetings": [...], "formats": [...]}    (587 rows)
///   without → [...]                                     (246 rows)
///
/// A decoder handling only one of these throws on the other.
nonisolated enum BMLTSearchPayload: Decodable {
    case meetings([BMLTMeetingRaw])
    case envelope(meetings: [BMLTMeetingRaw], formats: [BMLTFormat])

    private struct Envelope: Decodable {
        let meetings: [BMLTMeetingRaw]
        let formats: [BMLTFormat]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bare = try? container.decode([BMLTMeetingRaw].self) {
            self = .meetings(bare)
            return
        }
        let box = try container.decode(Envelope.self)
        self = .envelope(meetings: box.meetings, formats: box.formats ?? [])
    }

    var meetings: [BMLTMeetingRaw] {
        switch self {
        case .meetings(let m): return m
        case .envelope(let m, _): return m
        }
    }

    var formats: [BMLTFormat] {
        switch self {
        case .meetings: return []
        case .envelope(_, let f): return f
        }
    }
}
