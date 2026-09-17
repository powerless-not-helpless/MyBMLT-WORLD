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

    /// Helplines arrive in whatever shape the service body typed them:
    /// bare digits ("6195841007"), parens ("(512) 480-0004"), E.164
    /// ("+61488811247"), an international prefix ("00353871386120"), two or
    /// three numbers in one field, or vanity text ("1-800-600-HOPE").
    ///
    /// This splits the field into individual, dialable numbers. It does not
    /// guess: a number keeps whatever country information the server gave it,
    /// and one that carries none is reported as domestic rather than dressed up
    /// with a country code it does not have.
    var helplines: [Helpline] {
        guard let raw = helpline else { return [] }
        return Helpline.parse(raw)
    }

    /// The first usable number, for callers that show only one.
    var primaryHelpline: Helpline? { helplines.first }

    /// Digits-only form of the primary number, for `tel:` URLs.
    var helplineDigits: String? { primaryHelpline?.dialString }

    /// Human-readable form of the primary number.
    var helplineDisplay: String? { primaryHelpline?.display }
}

/// One dialable phone number extracted from a service body's `helpline` field.
///
/// The old implementation reduced the field to digits and then formatted any
/// 10-digit result as `(XXX) XXX-XXXX`. That silently corrupted data outside the
/// NANP: the Australian local-rate number `1300 652 820` was rendered
/// `(130) 065-2820`, a well-formed US number that reaches a stranger. Stripping
/// `+` from E.164 (`+61488811247`) made real numbers undialable abroad, and
/// three numbers in one field were concatenated into one 30-digit string.
///
/// The rule now: **never claim more reachability than the server supplied.**
nonisolated struct Helpline: Equatable, Hashable {

    /// How widely the number can be reached, derived only from what the field
    /// actually contained.
    enum Reachability: Equatable, Hashable {
        /// Carries a country code, so it dials from anywhere.
        case international(countryCode: String)
        /// A NANP number with no `+`. Dialable from US/CA and most of the NANP.
        case nanp
        /// A shortcode (`988`) or local-rate line (`1300 ...`) with no country
        /// code and no international form. Reachable only from its home country,
        /// whose identity this type cannot know.
        case domesticOnly

        /// Short line shown beside a number that is not internationally dialable.
        var notice: String? {
            switch self {
            case .international: nil
            case .nanp: nil
            case .domesticOnly: "local number, may not work from abroad"
            }
        }
    }

    /// The original text this number was parsed from, trimmed.
    let raw: String
    /// Digits with a leading `+` when the number has a country code.
    let dialString: String
    /// What the user sees.
    let display: String
    let reachability: Reachability

    /// Parse a `helpline` field into zero or more numbers.
    ///
    /// Splits on the separators real data uses to hold multiple numbers —
    /// commas, slashes, pipes and semicolons — then classifies each piece
    /// independently. A piece with no digits (a bare "or") drops out.
    static func parse(_ raw: String) -> [Helpline] {
        raw
            .components(separatedBy: Self.separators)
            // A single piece can still hold two numbers joined by a word rather
            // than punctuation — verified: "352-553-2396 or 877-782-7657",
            // "(800)-733-8855 OREGON or (530) 842-7502 CA" and
            // "1-855-LIGNENA 1-855-544-6362". Splitting on separators alone
            // concatenated those into one unmatchable string.
            .flatMap(Self.splitNumberRuns)
            .compactMap { Self.parseOne($0) }
    }

    private static let separators = CharacterSet(charactersIn: ",;/|\n\r\t")

    /// Split a piece on runs of number-shaped characters.
    ///
    /// A run is a `+` followed by digits, or a bare group of digits. Ordinary
    /// words and `or` separate runs, so two numbers joined by text become two
    /// runs. Single numbers with internal punctuation (`(512) 480-0004`,
    /// `+91 90865 97717`) stay one run, because the gap between their digit
    /// groups is only punctuation or whitespace.
    ///
    /// Letters are dropped, so a vanity tail contributes only its leading
    /// digits (`1-800-600-HOPE` -> `1800600`). That fragment is then judged by
    /// length like any other number, rather than guessed at.
    ///
    /// A letter after digits closes the run: `OREGON` following
    /// `(800)-733-8855 ` must not merge into the next number.
    private static func splitNumberRuns(_ piece: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var sawLetterSinceDigits = false

        for ch in piece {
            if ch.isNumber {
                current.append(ch)
                sawLetterSinceDigits = false
            } else if ch == "+" && current.isEmpty {
                current.append(ch)
            } else if ch.isLetter {
                // Only meaningful once digits are buffered; a leading word like
                // "Bilingual" is ignored entirely.
                if !current.isEmpty { sawLetterSinceDigits = true }
            } else {
                // Punctuation and whitespace do not break a run by themselves,
                // but they do close a run that letters have already ended.
                if sawLetterSinceDigits, !current.isEmpty {
                    runs.append(current)
                    current = ""
                    sawLetterSinceDigits = false
                }
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Classify a single number, or return nil when it is junk.
    private static func parseOne(_ piece: String) -> Helpline? {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A field that is purely a vanity word ("HOPE") has no number in it.
        // `1-800-600-HOPE` does: keep the digits, drop the letters, and let the
        // resulting length decide reachability. There is no way to recover the
        // letters-to-digits mapping reliably (`HOPE` is 4673 on one exchange and
        // 600-4673 versus 800-467-3000 are both plausible), so the number is
        // reported as-is rather than guessed at.
        let hasInternationalPlus = trimmed.hasPrefix("+")
        // Keep a leading '+' as the one non-digit that carries meaning: it is
        // what makes a number dialable across borders. Everything else that is
        // not a digit is punctuation and is dropped.
        var digits = trimmed.filter(\.isNumber)
        if hasInternationalPlus { digits = "+" + digits }

        // `00` is the international access prefix in most of the world outside
        // the NANP. Ireland's `00353871386120` is `+353 87 138 6120`. This
        // translation is unambiguous — no NANP number begins `00`.
        if !hasInternationalPlus, digits.hasPrefix("00"), digits.count >= 9 {
            digits = "+" + digits.dropFirst(2)
        }

        // Placeholder junk: "0000000000", "1111111111", a lone "0".
        let bareDigits = digits.filter(\.isNumber)
        guard bareDigits.count >= 3, Set(bareDigits).count > 1 else { return nil }

        if digits.hasPrefix("+") {
            let body = digits.dropFirst()
            // `+` followed by 7+ digits is E.164. Shorter than that with a `+`
            // is not a real country-coded number; treat it as domestic rather
            // than inventing a country code.
            if body.count >= 7 {
                let cc = String(body.prefix(Self.countryCodeLength(body)))
                return Helpline(
                    raw: trimmed,
                    dialString: "+" + body,
                    display: Self.internationalDisplay("+" + body),
                    reachability: .international(countryCode: cc)
                )
            }
        }

        // Shortcodes: `988`, `911`, `1300`-style local-rate lines are short or
        // begin with a domestic prefix. These are never internationally
        // dialable, and US formatting must not touch them.
        //
        // A 4-digit run is almost always a vanity-code stub (the `1855` left
        // over from `1-855-LIGNENA`), not a real shortcode. Drop it rather than
        // offering the user a number that cannot connect.
        if bareDigits.count == 4 { return nil }
        if bareDigits.count < 7 || Self.isLocalRatePrefix(bareDigits) {
            return Helpline(
                raw: trimmed,
                dialString: bareDigits,
                display: bareDigits,
                reachability: .domesticOnly
            )
        }

        // NANP: exactly 10 digits, or 11 beginning with 1.
        if bareDigits.count == 10 {
            return Helpline(
                raw: trimmed,
                dialString: bareDigits,
                display: Self.nanpDisplay(bareDigits),
                reachability: .nanp
            )
        }
        if bareDigits.count == 11, bareDigits.hasPrefix("1") {
            return Helpline(
                raw: trimmed,
                dialString: "+" + bareDigits,
                display: "+" + bareDigits,
                reachability: .international(countryCode: "1")
            )
        }

        // Anything else: a real number of unknown origin. Show the digits
        // unformatted. Ugly, but honest — an unformatted Australian number is
        // dialable from Australia, whereas a fabricated US one is not dialable
        // from anywhere the user expects.
        return Helpline(
            raw: trimmed,
            dialString: bareDigits,
            display: bareDigits,
            reachability: .domesticOnly
        )
    }

    /// E.164 country codes are 1–3 digits. This picks the length from the
    /// leading digits using the real allocation ranges rather than assuming 2,
    /// which would read `+61488811247` as country `61` (correct) but
    /// `+353871386120` as `35` (wrong — it is `353`).
    private static func countryCodeLength(_ body: Substring) -> Int {
        guard let first = body.first else { return 1 }
        switch first {
        case "1", "7": return 1
        case "2", "3", "4", "5", "6", "8", "9":
            // 2-digit codes dominate here, but 3-digit codes exist throughout
            // these ranges (e.g. 353 Ireland, 595 Paraguay, 998 Uzbekistan).
            // Prefer 3 when the leading three digits name a known code.
            let three = String(body.prefix(3))
            return threeCountryCodes.contains(three) ? 3 : 2
        default: return 1
        }
    }

    /// Three-digit E.164 codes present in the aggregator data (verified against
    /// the bodies that supply them). Not exhaustive worldwide — only enough to
    /// avoid mis-splitting the numbers this app actually receives. A code absent
    /// here falls back to 2 digits, which is the common case.
    private static let threeCountryCodes: Set<String> = [
        "353", // Ireland
        "595", // Paraguay
        "998", // Uzbekistan
        "994", // Azerbaijan
        "995", // Georgia
        "996", // Kyrgyzstan
        "992", // Tajikistan
        "993", // Turkmenistan
        "591", // Bolivia
        "593", // Ecuador
        "597", // Suriname
        "598", // Uruguay
    ]

    /// Local-rate / domestic-only prefixes that must never be US-formatted.
    ///
    /// `1300 652 820` (Australia) is 10 digits and starts with `1300`. But a US
    /// toll-free `1-800-555-0199` is 11 digits and must not be caught here —
    /// otherwise a real NANP number is mislabelled domestic-only. Only the
    /// 10-digit `1300`/`1800` forms are the Australian local-rate pattern.
    private static func isLocalRatePrefix(_ digits: String) -> Bool {
        digits.count == 10 && (digits.hasPrefix("1300") || digits.hasPrefix("1800"))
    }

    /// Group E.164 digits for reading: `+61488811247` -> `+61 488 811 247`.
    private static func internationalDisplay(_ e164: String) -> String {
        let body = e164.dropFirst()
        let ccLength = countryCodeLength(body)
        let cc = body.prefix(ccLength)
        var rest = Array(body.dropFirst(ccLength))
        var groups: [String] = []
        // Chunk the remainder in 3s; the last group keeps whatever is left so
        // nothing is dropped.
        while rest.count > 3 {
            groups.append(String(rest.prefix(3)))
            rest.removeFirst(3)
        }
        if !rest.isEmpty { groups.append(String(rest)) }
        let grouped = ([String(cc)] + groups).joined(separator: " ")
        return grouped.isEmpty ? e164 : "+" + grouped
    }

    /// `(619) 584-1007`.
    private static func nanpDisplay(_ d: String) -> String {
        guard d.count == 10 else { return d }
        return "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.suffix(4))"
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
    func nearestHelpline(for body: ServiceBody) -> (body: ServiceBody, helpline: Helpline)? {
        var current: ServiceBody? = body
        var hops = 0
        while let node = current, hops < 8 {
            if let helpline = node.primaryHelpline {
                return (node, helpline)
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
