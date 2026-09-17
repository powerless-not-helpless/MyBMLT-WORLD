import Foundation

/// A BMLT service body: a region ("RS"), area ("AS"), or other organizational
/// unit. This is what the brief calls an "Area".
///
/// IDs are **scoped to a root server**. The San Diego Imperial Counties Region
/// is `1155` on `bmlt.wszf.org` and `2313` on the aggregator — the same region,
/// same `world_id RG590`. Never persist a bare ID without its `rootServerID`.
nonisolated struct ServiceBody: Identifiable, Codable, Hashable {
    let id: Int
    let parentID: Int?
    let name: String
    /// Free-text coverage note, e.g. "Serving Mahoning and Columbiana Counties.
    /// Greater Youngstown, Austintown, East Liverpool and Salem."
    ///
    /// The only place a service body names the *cities* it covers. Names are
    /// organizational ("NE Ohio Area"), so this is what lets a city lookup
    /// confirm it picked the right area rather than a neighbour.
    let description: String?
    /// "RS" region, "AS" area, "MA" metro, "ZF" zonal forum, "RSO" ...
    let type: String
    let url: String?
    let helpline: String?
    /// Server-independent identity, e.g. "RG590". The stable key for a region.
    let worldID: String?
    let rootServerID: Int

    /// Same identity problem as `Meeting.uid`.
    var uid: String { "\(rootServerID):\(id)" }

    var isRegion: Bool { type == "RS" }

    var displayName: String { name }

    /// A usable web URL, normalizing the bare hostnames some bodies return
    /// (e.g. "www.sandiegona.org" with no scheme).
    var webURL: URL? {
        guard var raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        return URL(string: raw)
    }

    /// Helplines appear as bare digit strings ("6195841007") and formatted
    /// strings ("(512) 480-0004"). Normalize to digits for tel: URLs.
    var helplineDigits: String? {
        guard let raw = helpline else { return nil }
        let digits = raw.filter(\.isNumber)
        // Reject placeholder junk like "0000000000".
        guard digits.count >= 7, Set(digits).count > 1 else { return nil }
        return digits
    }

    var helplineDisplay: String? {
        guard let d = helplineDigits else { return nil }
        if d.count == 10 {
            let a = d.prefix(3), b = d.dropFirst(3).prefix(3), c = d.suffix(4)
            return "(\(a)) \(b)-\(c)"
        }
        if d.count == 11 && d.hasPrefix("1") {
            return "+\(d)"
        }
        return d
    }
}

/// The full service body graph, with the tree operations the UI needs.
///
/// Verified 3-level depth: `2322 -> 2313 -> 1812`, so this is a real tree, not
/// a flat region→area list.
nonisolated struct ServiceBodyTree {

    let bodies: [ServiceBody]

    private let byUID: [String: ServiceBody]
    private let childrenByParent: [Int: [ServiceBody]]

    init(_ bodies: [ServiceBody]) {
        self.bodies = bodies
        self.byUID = Dictionary(bodies.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        self.childrenByParent = Dictionary(grouping: bodies.compactMap { body in
            body.parentID.map { ($0, body) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
    }

    func body(uid: String) -> ServiceBody? { byUID[uid] }

    /// Children of a body, matched within the same root server because IDs are
    /// only unique per server.
    ///
    /// Not currently used: the picker lists regions flat and relies on
    /// `recursive=1` server-side to pull a region's areas. Kept because region
    /// drill-down is the obvious next step and this is its primitive.
    func children(of body: ServiceBody) -> [ServiceBody] {
        (childrenByParent[body.id] ?? [])
            .filter { $0.rootServerID == body.rootServerID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var regions: [ServiceBody] {
        bodies.filter(\.isRegion)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Walks up the ancestor chain from `body` and returns the first non-empty
    /// helpline.
    ///
    /// Required because verified SD data has the helpline on the **region**
    /// (2313 -> "6195841007") while every sub-area returns `""`. Reading only
    /// the selected area would show nothing.
    func nearestHelpline(for body: ServiceBody) -> (body: ServiceBody, display: String, digits: String)? {
        var current: ServiceBody? = body
        var hops = 0
        while let node = current, hops < 8 {
            if let display = node.helplineDisplay, let digits = node.helplineDigits {
                return (node, display, digits)
            }
            guard let parentID = node.parentID else { break }
            current = bodies.first { $0.id == parentID && $0.rootServerID == node.rootServerID }
            hops += 1
        }
        return nil
    }

    /// Best-effort match for a city / ZIP / area name.
    ///
    /// Service bodies carry **no geographic fields** — verified: the only
    /// searchable text is `name`, `helpline`, `url` and `worldID`. Names are
    /// organizational ("Ohio Region", "Sonoma County Area"), not postal. So a
    /// user typing "Youngstown, Ohio" cannot be answered directly: no service
    /// body mentions Youngstown, even though its meetings exist under the Ohio
    /// Region.
    ///
    /// What this can do is be forgiving about the *shape* of the query while
    /// still ranking the specific thing first:
    ///
    /// - Split on commas and whitespace, so "Sonoma, California" becomes the
    ///   tokens `sonoma` and `california` instead of one unmatchable string.
    /// - Treat a trailing region/state token as a *soft* filter. "Sonoma,
    ///   California" should surface Sonoma first and California regions after;
    ///   returning seven California regions ahead of the one place the user
    ///   named is worse than useless.
    ///
    /// The ordering is therefore: name matches the **first** token (the city or
    /// area the user led with) → then matches more of the remaining tokens →
    /// then a contiguous phrase match → then shortest name. This is deliberately
    /// loose; `AreaPickerView` names it "Area or region name" rather than
    /// promising city lookup it cannot deliver.
    func search(_ query: String) -> [ServiceBody] {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }   // drop "ca", stray punctuation

        guard let lead = tokens.first else { return [] }
        let rest = Array(tokens.dropFirst())

        // Does the leading token name anything at all? If it does, matches that
        // only hit the trailing state/region token are noise: "Sonoma,
        // California" matched eight bodies, seven of them California regions
        // that merely share the state name, burying the one place the user
        // asked for. If the lead names nothing, the trailing tokens are the
        // only lead available — which is what makes "Youngstown, Ohio" usable.
        let leadNamesSomething = bodies.contains { Self.containsWord(lead, in: $0.name.lowercased()) }

        // A generic opener ("United", "Central", "North") does not identify a
        // place. When the query starts with one, matching that word alone is not
        // enough — the rest of the query must match too. Without this, "United
        // Kingdom" returned three unrelated US areas on the strength of
        // "United", and no body is named Kingdom.
        let leadIsGeneric = Self.isNonPlaceWord(lead) && !rest.isEmpty

        return bodies
            .compactMap { body -> (body: ServiceBody, onLead: Bool, extras: Int, phrase: Bool)? in
                let name = body.name.lowercased()
                let onLead = Self.containsWord(lead, in: name)
                let extras = rest.filter { Self.containsWord($0, in: name) }.count

                if leadIsGeneric {
                    // Must match at least one of the descriptive tokens.
                    guard extras > 0 else { return nil }
                } else {
                    guard onLead || extras > 0 else { return nil }
                }

                let phrase = tokens.count > 1 && name.contains(tokens.joined(separator: " "))
                return (body, onLead, extras, phrase)
            }
            .filter { entry in
                entry.onLead || !leadNamesSomething
            }
            .sorted {
                // The place the user named first wins outright.
                if $0.onLead != $1.onLead { return $0.onLead }
                if $0.extras != $1.extras { return $0.extras > $1.extras }
                if $0.phrase != $1.phrase { return $0.phrase }
                if $0.body.name.count != $1.body.name.count {
                    return $0.body.name.count < $1.body.name.count
                }
                return $0.body.name.localizedCaseInsensitiveCompare($1.body.name) == .orderedAscending
            }
            .map(\.body)
    }

    /// Whole-word (case-insensitive) containment.
    ///
    /// Plain `contains` produced two verified false positives:
    ///
    /// - `"Mexico"` matched **New Mexico**, because `mexico` is a substring of
    ///   `new mexico`. Three New Mexico areas buried the query, and there is no
    ///   body named Mexico — so the search appeared to answer with US areas.
    /// - `"United Kingdom"` matched `Phoenix United Area`, `United Shoreline
    ///   Area` and `United East County Area`, all in the US.
    ///
    /// Whole-word matching alone fixes the second (no body contains the word
    /// `kingdom`) but not the first, since `New Mexico` genuinely contains the
    /// word `mexico`. The qualifier check handles that: a token preceded by a
    /// word that changes the place's identity is not a match.
    nonisolated static func containsWord(_ token: String, in haystack: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchStart = haystack.startIndex

        while let r = haystack.range(of: token, range: searchStart..<haystack.endIndex) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: r.lowerBound)])
            let afterOK = r.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[r.upperBound])

            if beforeOK && afterOK && !isQualified(r, in: haystack) {
                return true
            }
            guard r.upperBound < haystack.endIndex else { break }
            searchStart = r.upperBound
        }
        return false
    }

    private nonisolated static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// True when the matched word is preceded by a qualifier that turns it into
    /// a different place — `New` before `Mexico`.
    private nonisolated static func isQualified(
        _ match: Range<String.Index>, in haystack: String
    ) -> Bool {
        let prefix = haystack[haystack.startIndex..<match.lowerBound]
        guard let preceding = prefix
            .split(whereSeparator: { !isWordCharacter($0) })
            .last?
            .lowercased()
        else { return false }
        return qualifiers.contains(preceding)
    }

    /// Words that, placed before a place name, denote a *different* place.
    /// Deliberately tiny and explicit; guessing here causes more harm than it
    /// fixes.
    private nonisolated static let qualifiers: Set<String> = ["new"]

    /// Leading words that are organisational adjectives, not place names.
    ///
    /// Verified: `"United Kingdom"` matched `Phoenix United Area`, `United
    /// Shoreline Area` and `United East County Area` — all in the US. No body is
    /// named United Kingdom, and no body is named Kingdom either, so the only
    /// reason those three surfaced was the word `united`, which says nothing
    /// about where a meeting is.
    ///
    /// When the lead token is one of these, a match on that token alone is not
    /// enough: the query is trying to name a place, and a body must match the
    /// *rest* of the query to count. `"Central Area"` still works because the
    /// remaining token matches, and `"North Coastal Area"` still resolves.
    ///
    /// `"new"` is deliberately absent. It qualifies a place (`New Mexico`) but
    /// is also part of one (`New Hope Area`, `New Orleans Area`), so listing it
    /// here made `"New Mexico"` return New Hope instead.
    private nonisolated static let nonPlaceAdjectives: Set<String> = [
        "united", "greater", "area", "region",
        "central", "upper", "lower", "metro", "inner", "outer",
    ]

    /// True when the token is too generic to identify a place on its own.
    nonisolated static func isNonPlaceWord(_ token: String) -> Bool {
        nonPlaceAdjectives.contains(token.lowercased())
    }
}
