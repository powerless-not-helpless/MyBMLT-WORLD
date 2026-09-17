import Foundation

/// A BMLT meeting, normalized from the aggregator's all-strings JSON.
///
/// ## Identity
/// `id` (`id_bigint`) is a **per-root-server sequence number**, NOT globally
/// unique. The aggregator merges ~200 root servers, so the same `id` can exist
/// on several of them for different meetings. Always persist and compare using
/// `uid`, never `id`.
nonisolated struct Meeting: Identifiable, Codable, Hashable {

    /// Local server ID. Unique only within `rootServerID`.
    let id: Int

    /// Which root server this meeting came from. Required for `uid`.
    let rootServerID: Int

    let name: String
    /// 1 = Sunday ... 7 = Saturday
    let weekday: Int
    /// "HH:MM:SS" in the meeting's own `timeZoneID`, not the device's.
    let startTime: String
    /// "HH:MM:SS"
    let duration: String

    let locationName: String
    let street: String
    let city: String
    let zip: String
    /// Free-text venue notes. Sometimes carries Zoom credentials
    /// (e.g. "Zoom: 916 338 0135 Pwd: 12345") that appear nowhere else.
    let locationInfo: String

    let virtualLink: String?
    let virtualInfo: String?

    let formats: [String]
    let serviceBodyID: Int
    let serviceBodyName: String
    /// 1 = In-Person, 2 = Virtual, 3 = Hybrid
    let venueType: Int
    let latitude: Double?
    let longitude: Double?

    /// IANA identifier, e.g. "America/Chicago". Verified populated on the
    /// aggregator; empty string on `bmlt.wszf.org`.
    let timeZoneID: String

    /// Server-computed distance, present only on `geo_width` queries.
    ///
    /// The server sends `distance_in_miles` and `distance_in_km` together, so
    /// both are kept rather than converting one into the other. Which is shown
    /// is a locale decision, not a data one.
    let distanceMiles: Double?
    /// The same distance in kilometres, also server-computed.
    let distanceKilometers: Double?

    // MARK: - Identity

    /// Globally unique across the aggregator. Use this as every persisted key.
    var uid: String { "\(rootServerID):\(id)" }

    // MARK: - Distance

    /// Distance in the unit the user's locale expects, e.g. "0.9 mi" or "1.4 km".
    ///
    /// The US and UK use miles; most of the world uses kilometres.
    /// `Locale.current.measurementSystem` is the system's own answer, so a user
    /// in Poland sees km and a user in Texas sees miles with no setting of their
    /// own. Both figures come from the server — no conversion happens here.
    var formattedDistance: String? {
        if Locale.current.measurementSystem == .metric {
            guard let km = distanceKilometers else { return nil }
            return String(format: "%.1f km", km)
        }
        guard let mi = distanceMiles else { return nil }
        return String(format: "%.1f mi", mi)
    }

    // MARK: - Venue

    var isVirtualOrHybrid: Bool { venueType == 2 || venueType == 3 }

    /// A meeting with a real-world venue a user can travel to.
    ///
    /// Hybrid (3) counts: it happens somewhere. Virtual-only (2) does not, even
    /// though the aggregator often still carries coordinates on those rows —
    /// usually the coordinates of whoever created the entry, not a place to go.
    /// Gating the map link on coordinates alone therefore offers "Open in Maps"
    /// for online meetings and sends the user to an unrelated address.
    var hasPhysicalVenue: Bool { venueType != 2 }

    var venueLabel: String {
        switch venueType {
        case 1: return "In-Person"
        case 2: return "Virtual"
        case 3: return "Hybrid"
        default: return "Unknown"
        }
    }

    var isWheelchairAccessible: Bool {
        formats.contains { ["WC", "WCAB", "HC"].contains($0) }
    }

    // MARK: - Time

    var weekdayName: String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard weekday >= 1 && weekday <= 7 else { return "?" }
        return days[weekday - 1]
    }

    /// Resolved time zone, falling back to the device zone when the server
    /// gave us nothing (which is always the case on `bmlt.wszf.org`).
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? .current
    }

    /// True when this meeting's local time differs from the device's, so the
    /// UI can say "in Pacific Time" instead of silently showing an
    /// unlabeled time the user will misread.
    var isInDifferentZoneThanDevice: Bool {
        guard !timeZoneID.isEmpty else { return false }
        return timeZone.identifier != TimeZone.current.identifier
    }

    /// Minutes from midnight, in the meeting's own zone.
    private var startMinutes: Int? {
        let parts = startTime.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    var formattedDuration: String {
        let parts = duration.split(separator: ":")
        guard parts.count >= 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]) else { return duration }
        if hours > 0 && minutes > 0 { return "\(hours) hr \(minutes) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }

    /// The meeting's local start time, e.g. "7:00 PM".
    ///
    /// Deliberately arithmetic on `startMinutes`, never a `Date`.
    ///
    /// `start_time` is a time-of-day in the meeting's own zone with no date
    /// attached. Round-tripping it through a `Date` would introduce a zone
    /// decision that has to be made twice — once when the components are turned
    /// into an instant, again when the instant is formatted — and getting only
    /// one of the pair right silently shifts the displayed clock by the device's
    /// offset. Wall-clock in, wall-clock out has no zone to get wrong: this
    /// prints "7:00 PM" on a device in Chicago, Tokyo, or anywhere else.
    ///
    /// The 12/24-hour choice is a *locale* preference, not a zone one, so it is
    /// read from `Locale.current`. AM/PM strings are intentionally not localized;
    /// the app ships `lang_enum=en` throughout.
    ///
    /// Falls back to the raw server string when `start_time` is unparseable,
    /// matching `formattedDuration`.
    var formattedTime: String {
        guard let minutes = startMinutes else {
            return startTime.isEmpty ? "Time not listed" : startTime
        }
        let h24 = minutes / 60
        let m = minutes % 60

        let uses24Hour = DateFormatter
            .dateFormat(fromTemplate: "j", options: 0, locale: .current)?
            .contains("H") ?? false
        if uses24Hour {
            return String(format: "%02d:%02d", h24, m)
        }

        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(String(format: "%02d", m)) \(h24 < 12 ? "AM" : "PM")"
    }

    /// The next occurrence of this meeting at or before `now`'s weekday cycle,
    /// computed inside the meeting's own time zone.
    ///
    /// Returns `nil` only when `startTime` is unparseable.
    func nextOccurrence(after now: Date = Date(), graceMinutes: Int = 10) -> Date? {
        guard let start = startMinutes else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        // Target: this meeting's weekday + time, expressed in its own zone,
        // within the current week starting from `now`.
        let comps = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute],
                                       from: now)
        guard let todayWeekday = comps.weekday else { return nil }

        // BMLT weekday is 1=Sunday; Calendar's is 1=Sunday too. Good.
        var dayOffset = weekday - todayWeekday
        if dayOffset < 0 { dayOffset += 7 }

        guard let baseMidnight = cal.date(from: DateComponents(
            year: comps.year, month: comps.month, day: comps.day,
            hour: 0, minute: 0
        )) else { return nil }

        let candidate = cal.date(byAdding: DateComponents(
            day: dayOffset,
            hour: start / 60,
            minute: start % 60
        ), to: baseMidnight)

        guard let first = candidate else { return nil }
        // If we're still inside the grace window of a meeting that just began,
        // return it rather than jumping a week forward.
        if first.timeIntervalSince(now) >= -Double(graceMinutes * 60) {
            return first
        }
        return cal.date(byAdding: .day, value: 7, to: first)
    }

    func minutes(until date: Date, from now: Date = Date()) -> Int {
        Int(date.timeIntervalSince(now) / 60)
    }

    // MARK: - Join target

    /// VM/HYBRID join destination, with an explicit Google Meet branch and a
    /// Zoom deep link that falls back to the web URL.
    var joinTarget: (label: String, url: URL)? {
        guard let raw = virtualLink?.replacingOccurrences(of: " ", with: ""),
              let web = URL(string: raw),
              web.scheme?.lowercased() == "https"
        else { return nil }

        let host = web.host?.lowercased() ?? ""

        if host.contains("meet.google.com") {
            return ("Join with Google Meet", web)
        }

        if host.contains("zoom.us") {
            let meetingID = web.path.components(separatedBy: "/").last ?? ""
            guard !meetingID.isEmpty else { return ("Join with Zoom", web) }

            let pwd = URLComponents(url: web, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "pwd" }?
                .value

            var comps = URLComponents()
            comps.scheme = "zoommtg"
            comps.host = "zoom.us"
            comps.path = "/join"
            comps.queryItems = [URLQueryItem(name: "confno", value: meetingID)]
            if let pwd { comps.queryItems?.append(URLQueryItem(name: "pwd", value: pwd)) }

            // Prefer the installed app; the caller falls back to `web` if
            // opening this fails.
            if let deep = comps.url { return ("Join with Zoom", deep) }
            return ("Join with Zoom", web)
        }

        return ("Join Meeting", web)
    }

    /// The plain web URL for copying/sharing, with the Zoom `pwd` query
    /// stripped (the password is shown separately).
    var shareableLink: String? {
        guard let raw = virtualLink else { return nil }
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        return cleaned.components(separatedBy: "?pwd=").first ?? cleaned
    }

    // MARK: - Passwords

    /// Extracts the meeting password from every field that carries one.
    ///
    /// Verified real payloads this must handle:
    ///   virtual_meeting_additional_info: "Zoom ID: 916 338 0135, Passcode: 12345"
    ///   location_info:                   "Zoom: 916 338 0135 Pwd: 12345"
    ///
    /// Note `location_info` is checked too — for some phone/online meetings the
    /// password exists nowhere else.
    var passwordValue: String? {
        let sources = [virtualInfo, locationInfo].compactMap { $0 }
        for raw in sources {
            if let found = Self.extractPassword(from: raw) { return found }
        }
        return nil
    }

    private static let passwordLabels = [
        "passcode:", "password:", "passcode", "password",
        "pwd:", "pw:", "clave:", "contraseña:", "contrasena:",
    ]

    private static func extractPassword(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.contains("no password") || lower.contains("sin contraseña") { return nil }

        for label in passwordLabels {
            guard let range = lower.range(of: label) else { continue }
            let after = trimmed[range.upperBound...]
            // Stop at the next label or comma so "Passcode: 12345, ID: 99"
            // yields "12345" and not the rest of the string.
            let terminators = CharacterSet(charactersIn: ",;\n")
            let value = after
                .components(separatedBy: terminators)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty && value.count <= 32 {
                return value
            }
        }
        return nil
    }

    // MARK: - Address

    var addressLine: String {
        [street, city, zip].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Migration

    /// A content-based identity that survives a change of root server.
    ///
    /// Used only to carry pre-`uid` favourites across the move from
    /// bmlt.wszf.org to the aggregator, where both service body IDs and
    /// meeting IDs differ for the same physical meeting.
    ///
    /// Deliberately excludes `id`, `rootServerID`, and coordinates (which get
    /// corrected server-side over time).
    var migrationFingerprint: String {
        let normalizedName = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        return "\(normalizedName)|\(weekday)|\(startTime)"
    }

    // MARK: - Change detection

    /// A behavioural change between a saved favourite and its current record.
    ///
    /// Deliberately **not** derived from `Meeting == Meeting`. A whole-struct
    /// comparison fires on churn the user cannot see or act on — a geocode
    /// nudging `latitude`/`longitude` for the same building, format-code
    /// reordering, a trimmed `serviceBodyName` — and a banner that cries wolf
    /// on cosmetic noise teaches people to ignore it, which is worse than
    /// shipping no banner at all.
    ///
    /// The three cases are exactly the three facts that change what a person
    /// does next, and they line up with `MeetingDetailView`'s own sections
    /// (`scheduleBlock`, `locationBlock`, `onlineBlock`).
    enum Change: String, Codable, CaseIterable, Hashable {
        /// Weekday, start time, or duration. You will arrive at the wrong time.
        case schedule
        /// Street, city, ZIP, venue name, or moved coordinates. You will drive
        /// to the wrong place.
        case location
        /// Join link, password, or in-person/virtual/hybrid venue type. The
        /// link you have will not work.
        case online

        var title: String {
            switch self {
            case .schedule: return "Time changed"
            case .location: return "Location changed"
            case .online: return "Online details changed"
            }
        }

        var systemImage: String {
            switch self {
            case .schedule: return "clock.badge.exclamationmark"
            case .location: return "mappin.slash"
            case .online: return "video.slash"
            }
        }

        /// Ordered so the banner lists the most trip-ruining change first.
        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// Which behavioural fields differ between `self` (current server record)
    /// and `old` (the record the user saved).
    ///
    /// Returns an empty set when nothing a user would act on has moved, which
    /// is the signal to apply the new record silently.
    func changes(from old: Meeting) -> Set<Change> {
        var changes: Set<Change> = []

        if weekday != old.weekday
            || startTime != old.startTime
            || duration != old.duration {
            changes.insert(.schedule)
        }

        // Coordinates are compared at ~11 m precision (4 dp). Below that a
        // re-geocode of the same building would report a false move. A venue
        // that genuinely relocates clears this easily.
        let movedFarEnough: Bool
        switch (latitude, longitude, old.latitude, old.longitude) {
        case let (lat?, lon?, oldLat?, oldLon?):
            movedFarEnough = abs(lat - oldLat) > 0.0001 || abs(lon - oldLon) > 0.0001
        case (nil, nil, nil, nil):
            movedFarEnough = false
        default:
            // Gained or lost coordinates entirely — treat as a move, since the
            // map button appearing/disappearing is user-visible.
            movedFarEnough = true
        }

        if normalized(street) != normalized(old.street)
            || normalized(city) != normalized(old.city)
            || normalized(zip) != normalized(old.zip)
            || normalized(locationName) != normalized(old.locationName)
            || movedFarEnough {
            changes.insert(.location)
        }

        // `virtualLink` is compared after stripping the Zoom `pwd=` parameter,
        // because a rotated password is reported by `.online` below and would
        // otherwise double-count as both a link and a password change.
        if normalized(virtualLink ?? "") != normalized(old.virtualLink ?? "")
            || passwordValue != old.passwordValue
            || venueType != old.venueType {
            changes.insert(.online)
        }

        return changes
    }

    /// Case- and whitespace-insensitive comparison, so a server-side tidy-up of
    /// "Main St " vs "Main St" does not read as a move.
    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
