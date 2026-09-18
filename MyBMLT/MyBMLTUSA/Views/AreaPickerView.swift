import SwiftUI
import MapKit

/// Chooses the active Area.
///
/// Three paths, in priority order, and **none of them require location**:
///   1. Use my location  — opt-in, explicit button
///   2. Search by city / ZIP / address
///   3. Pick from the region list
///
/// The app must never show an empty first screen because the user declined
/// location, so paths 2 and 3 are always available.
struct AreaPickerView: View {
    @Environment(AreaStore.self) private var areas
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isSuggesting = false
    @State private var suggestionNote: String?
    @State private var isGeocoding = false
    @State private var geocodeNote: String?

    var body: some View {
        NavigationStack {
            List {
                locationSection
                searchSection
                selectionsSection
                browseSection
            }
            .navigationTitle("Choose an Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationSection: some View {
        Section {
            if location.isDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Location access is off", systemImage: "location.slash")
                        .font(.subheadline)
                    Text("You can search by city or ZIP instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { location.openSettings() }
                        .font(.caption)
                }
            } else {
                Button {
                    useMyLocation()
                } label: {
                    HStack {
                        Label("Use My Location", systemImage: "location.fill")
                        Spacer()
                        if isSuggesting { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isSuggesting)

                if let suggestionNote {
                    Text(suggestionNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Nearby")
        } footer: {
            Text("Location is used once to suggest your Area. It never leaves your device.")
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            TextField("Area, city, or ZIP", text: $query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onSubmit { findNearbyPlaces() }

            // Placed directly under the field, ABOVE the match list.
            //
            // Areas are named organizationally, so a city like "Riverside" or
            // "Youngstown" matches no service body even though its meetings
            // exist under bodies named after something else entirely (Eastern
            // Inland Empire Area, Trumbull Area). Geocoding the text and asking
            // the server which bodies own meetings there answers the question
            // the name search cannot.
            //
            // It used to sit below `ForEach(matches)`. With "Riverside,
            // California" the name search returns seven California regions,
            // which pushed this row under the keyboard and off-screen — it looked
            // like the button had vanished. Keeping it first means the action is
            // always visible, and it reads as an alternative to the results below
            // it rather than an afterthought.
            if query.count >= 2 && looksLikePlace {
                Button {
                    findNearbyPlaces()
                } label: {
                    HStack {
                        Label("Find areas near “\(query)”", systemImage: "mappin.and.ellipse")
                        Spacer()
                        if isGeocoding { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isGeocoding)
            }

            ForEach(matches) { candidate in
                Button {
                    select(candidate, discovery: .search)
                } label: {
                    bodyRow(candidate)
                }
            }

            if let geocodeNote {
                Text(geocodeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Search")
        } footer: {
            Text("Areas are named by their service body, so a city may match none. Search a place name and the app will look for areas near it.")
        }
    }

    private var matches: [ServiceBody] {
        guard let tree = areas.tree, query.count >= 2 else { return [] }
        return Array(tree.search(query).prefix(25))
    }

    /// Heuristic for "this is a place name, not a service body name".
    ///
    /// A comma ("Riverside, California") or a ZIP-shaped token is a strong
    /// signal that name matching cannot help. Deliberately cheap: the button is
    /// harmless when wrong, and a false positive costs one tap.
    private var looksLikePlace: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(",") { return true }
        // 5-digit ZIP, with optional +4.
        return text.split(separator: " ").contains { token in
            let digits = token.filter(\.isNumber)
            return digits.count >= 5 && digits.count == token.count
        }
    }

    // MARK: - Saved areas

    @ViewBuilder
    private var selectionsSection: some View {
        if !areas.selections.isEmpty {
            Section("Your Areas") {
                ForEach(areas.selections) { selection in
                    Button {
                        areas.setActive(selection)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selection.displayName)
                                Text(discoveryLabel(selection.discovery))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection.serviceBodyUID == areas.active?.serviceBodyUID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        areas.remove(areas.selections[index])
                    }
                }
            }
        }
    }

    // MARK: - Browse

    @ViewBuilder
    private var browseSection: some View {
        if let tree = areas.tree {
            Section("Browse Regions") {
                if areas.isLoadingBodies && tree.bodies.isEmpty {
                    ProgressView()
                }
                ForEach(tree.regions.prefix(200)) { region in
                    Button {
                        select(region, discovery: .manual)
                    } label: {
                        bodyRow(region)
                    }
                }
            }
        } else if areas.isLoadingBodies {
            Section { ProgressView("Loading regions…") }
        } else if let error = areas.bodiesError {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load the region list.")
                        .font(.subheadline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await areas.loadServiceBodies(forceRefresh: true) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func bodyRow(_ serviceBody: ServiceBody) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceBody.name)
                    .foregroundStyle(.primary)
                if !serviceBody.type.isEmpty {
                    Text(typeLabel(serviceBody.type))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "RS": return "Region"
        case "AS": return "Area"
        case "MA": return "Metro"
        case "ZF": return "Zonal Forum"
        default: return type
        }
    }

    private func discoveryLabel(_ discovery: AreaSelection.Discovery) -> String {
        switch discovery {
        case .locationSuggestion: return "Found via location"
        case .search: return "Added by search"
        case .manual: return "Added manually"
        case .bundledDefault: return "Default"
        }
    }

    // MARK: - Actions

    private func select(_ serviceBody: ServiceBody, discovery: AreaSelection.Discovery) {
        areas.setActive(AreaSelection(body: serviceBody, discovery: discovery))
        dismiss()
    }

    /// Resolves the user's coordinates to the nearest service body.
    ///
    /// Uses the geo query to find meetings near the fix, then picks the service
    /// body that owns the most of them. That avoids needing a point-in-polygon
    /// dataset, and reflects where meetings actually are rather than where a
    /// boundary happens to fall.
    private func useMyLocation() {
        suggestionNote = nil
        isSuggesting = true

        location.requestAuthorization()

        Task {
            defer { isSuggesting = false }

            // Wait briefly for a fix rather than failing instantly.
            var attempts = 0
            while location.currentLocation == nil && attempts < 20 {
                try? await Task.sleep(for: .milliseconds(250))
                attempts += 1
            }

            guard let fix = location.currentLocation else {
                suggestionNote = location.isDenied
                    ? "Location is unavailable — search for your city or ZIP instead."
                    : "Couldn't get a location fix. Search for your city or ZIP instead."
                return
            }

            await suggest(nearest: fix)
        }
    }

    private func suggest(nearest fix: CLLocation) async {
        guard areas.tree != nil else {
            suggestionNote = "Region list still loading — try again in a moment."
            return
        }

        do {
            let nearby = try await areas.meetingsNear(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                radiusMiles: 25
            )

            guard let resolved = AreaProximity.nearestOwner(of: nearby, in: areas.tree) else {
                suggestionNote = "Found meetings nearby, but couldn't match them to an Area. Search instead."
                return
            }

            areas.setActive(AreaSelection(body: resolved, discovery: .locationSuggestion))
            dismiss()
        } catch {
            suggestionNote = "Couldn't search nearby: \(error.localizedDescription)"
        }
    }

    // MARK: - City lookup

    /// Answers "Youngstown, Ohio" — a place name that names no service body.
    ///
    /// Service bodies are named organizationally ("Trumbull Area", "NE Ohio
    /// Area"), so Youngstown matches nothing by name even though its 64 nearby
    /// meetings exist under those bodies. Geocoding the text gives coordinates,
    /// and the server then reports which bodies own meetings there.
    ///
    /// Geocoding goes through whatever Apple service the OS provides: no API
    /// key, no third-party dependency, and no new data leaving the device
    /// beyond the place name the user typed. `CLGeocoder` is used below iOS 26
    /// and `MKGeocodingRequest` at 26+, where Apple deprecated the former.
    ///
    /// The lookup goes through `GeocodeRanking.resolve`, which confines the
    /// deprecated call to one small `@available`-gated function: there is no way
    /// to write a single call that compiles warning-free against a deployment
    /// target older than the replacement, so the branch has to exist somewhere.
    private func findNearbyPlaces() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }

        geocodeNote = nil
        isGeocoding = true

        Task {
            defer { isGeocoding = false }

            do {
                let candidates = try await GeocodeRanking.resolve(text)

                // Prefer a city over a state/province.
                //
                // Verified: "Youngstown, Ohio" returns the *state* centroid as
                // the first result, which resolves to Central Ohio Area
                // (Columbus) — 200 miles from Youngstown. "Youngstown" alone
                // returns the city and correctly resolves to Trumbull Area.
                // Taking the first result therefore made the comma-separated
                // form worse than the bare city name, which is backwards.
                //
                // Falling back through county and ZIP preserves behaviour for
                // queries that really are regions or ZIPs.
                let ordered = GeocodeRanking.preferLocality(candidates)
                guard let location = ordered.first else {
                    geocodeNote = "Couldn't find “\(text)”. Try a city name or a ZIP code."
                    return
                }

                let nearby = try await areas.meetingsNear(
                    latitude: location.latitude,
                    longitude: location.longitude,
                    radiusMiles: 25
                )

                // Never mention the radius. 25 miles is an implementation
                // detail chosen to answer "which Area owns this place?" — it is
                // not a control the user has, and reporting it invites them to
                // "widen the search" when the real problem is that no Area is
                // named for what they typed. Saying "No meetings within 25 miles
                // of United Kingdom" also read as "no coverage here" when the
                // aggregator in fact holds UK meetings under a Polish-named
                // Area.
                guard !nearby.isEmpty else {
                    geocodeNote = "No areas found for “\(text)”. Try a nearby city name — areas are named by their service body, sometimes in another language."
                    return
                }

                // Proximity decides which Area covers this point — see
                // `AreaProximity`. No text matching is involved: it was measured
                // and never changed a result.
                let ranked = AreaProximity.owners(of: nearby, in: areas.tree)

                guard let best = ranked.first else {
                    geocodeNote = "Found meetings for “\(text)” but couldn't match them to an area. Try the region name instead."
                    return
                }

                if ranked.count > 1 {
                    // Naming the runner-up is honest about the guess: for
                    // "Rochester, Michigan" two areas tie and the user may want
                    // the other one.
                    let also = ranked.dropFirst().first.map { " \($0.name) also covers the area." } ?? ""
                    geocodeNote = "\(nearby.count) meetings for “\(text)” across \(ranked.count) areas. Selected \(best.name).\(also)"
                }

                areas.setActive(AreaSelection(body: best, discovery: .locationSuggestion))
                dismiss()
            } catch {
                // Geocoding fails for two very different reasons, and the user
                // needs to tell them apart: a network problem is worth retrying,
                // an unresolvable name is not. Anything else is surfaced as a
                // connection problem, because "check the spelling" is bad advice
                // for a dropped connection.
                if GeocodeRanking.isNoResult(error) {
                    geocodeNote = "Couldn't find “\(text)”. Try a city name or a ZIP code."
                } else {
                    geocodeNote = "Couldn't look up “\(text)”. Check your connection and try again."
                }
            }
        }
    }
}

/// Resolves a coordinate to the Area that owns it, from the meetings the server
/// reports nearby.
///
/// A pure function of the meeting list and the service body graph, so it is
/// testable without a window, an environment, or a network. It used to be two
/// private methods on `AreaPickerView` reading `areas.tree` from the
/// environment, which left the one decision that picks the user's Area
/// unreachable from tests.
///
/// `nonisolated`: no UI state, and it must stay callable from the nonisolated
/// `Task` bodies that fetch the meetings it ranks.
nonisolated enum AreaProximity {

    /// How many of the nearest meetings vote on the owning Area.
    ///
    /// Five is enough to be stable (a single mis-geocoded row cannot flip a
    /// 5-0 or 3-2 vote) and small enough to stay local, so an Area 20 miles away
    /// cannot outvote one whose meetings are next door.
    static let nearestSampleSize = 5

    /// The Area owning the nearest meetings, or nil when none can be placed.
    ///
    /// Shared by the location path and the city-name path.
    static func nearestOwner(of meetings: [Meeting], in tree: ServiceBodyTree?) -> ServiceBody? {
        owners(of: meetings, in: tree).first
    }

    /// Areas that own meetings near a point, best first.
    ///
    /// **The vote is a plurality inside the nearest few meetings.** Meetings are
    /// ordered by the server's own distance, truncated to `nearestSampleSize`,
    /// and the Area owning the most of those wins. Bounding the window first is
    /// what makes this geographic rather than a popularity contest: an Area with
    /// hundreds of meetings 20 miles away contributes nothing, because its rows
    /// never reach the window.
    ///
    /// Earlier revisions counted owners across every meeting within 25 miles,
    /// which metro boundaries corrupt. Measured:
    ///
    /// | City | count-based (old) | now |
    /// |---|---|---|
    /// | Tampa, FL | Bay Area (117 meetings) | Tampa Funcoast Area (0.0 mi) |
    /// | Youngstown, OH | 14-14 tie | NE Ohio Area (1.0 mi) |
    /// | Rochester, MI | 52-52 tie | Oakland County Area (0.9 mi) |
    ///
    /// The radius stopped mattering too: only the nearest few rows are consulted,
    /// so 25 or 250 miles gives the same answer.
    ///
    /// Note the ranking is **not** "the owner of the single nearest meeting":
    /// within the window it is still a count. The two differ when the nearest
    /// Area has fewer rows in the window than a slightly-further one, and the
    /// window is what keeps the difference local. `AreaProximityTests` pins the
    /// real behaviour.
    ///
    /// A name/description match used to override this — an Area whose name said
    /// "Tampa" beat one owning more nearby meetings. It was measured across ten
    /// cities and **never changed an outcome**: with it on or off, every city
    /// resolved identically, because the nearest-five vote is never tied. It was
    /// removed rather than kept as decoration.
    static func owners(of meetings: [Meeting], in tree: ServiceBodyTree?) -> [ServiceBody] {
        guard let tree, !meetings.isEmpty else { return [] }

        // Meetings arrive from a `geo_width` query already carrying the
        // server's distance, so the nearest few can be selected directly.
        //
        // Rows without a distance are **excluded entirely** once any row has
        // one -- they do not "vote last". They only participate in the
        // all-distance-absent fallback, where the server's own order is used and
        // distance cannot discriminate. An earlier comment here claimed they
        // vote last rather than not at all; that was wrong for the mixed case,
        // and `unplacedRowsAreExcludedWhenOthersArePlaced` pins the real
        // behaviour.
        let placed = meetings
            .filter { $0.distanceMiles != nil }
            .sorted { ($0.distanceMiles ?? .greatestFiniteMagnitude)
                    < ($1.distanceMiles ?? .greatestFiniteMagnitude) }

        let sample = placed.isEmpty
            ? Array(meetings.prefix(nearestSampleSize))
            : Array(placed.prefix(nearestSampleSize))

        var votes: [Int: Int] = [:]
        var nearest: [Int: Double] = [:]
        for meeting in sample {
            votes[meeting.serviceBodyID, default: 0] += 1
            let d = meeting.distanceMiles ?? .greatestFiniteMagnitude
            nearest[meeting.serviceBodyID] = min(nearest[meeting.serviceBodyID] ?? d, d)
        }

        return votes
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                // Ties are not observed in practice, but the order must still be
                // deterministic: `Dictionary` iteration order is unspecified and
                // `sorted` is not stable.
                let ad = nearest[a.key] ?? .greatestFiniteMagnitude
                let bd = nearest[b.key] ?? .greatestFiniteMagnitude
                if ad != bd { return ad < bd }
                return a.key < b.key
            }
            // An owner id absent from the graph is dropped rather than
            // rendered: it cannot be selected as an Area.
            .compactMap { id, _ in tree.bodies.first { $0.id == id } }
    }
}
