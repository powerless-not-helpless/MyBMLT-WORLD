import CoreLocation
import MapKit

/// One geocoder result, reduced to the two things the Area picker uses: where it
/// is, and how specific a match it is.
///
/// ## Why this type exists
/// `CLGeocoder` and its iOS 26 replacement return different types.
/// `CLPlacemark` carries `locality`, `subAdministrativeArea` and `postalCode`;
/// `MKMapItem` exposes only `addressRepresentations.cityName`. Ranking against a
/// shared value keeps the "prefer the city over the state" rule in one place
/// rather than duplicating it per API and letting the two drift.
///
/// The rule is not cosmetic. It was measured: "Youngstown, Ohio" returns the
/// *state* centroid first, which resolves to Central Ohio Area (Columbus) — 200
/// miles away — while "Youngstown" alone returns the city and correctly resolves
/// to Trumbull Area. Taking the first result made the comma-separated form worse
/// than the bare city name, which is backwards.
struct GeocodeCandidate: Equatable {

    let latitude: Double
    let longitude: Double

    /// Lower is more specific. Tiers, verified against "Youngstown, Ohio":
    /// city 0, county 1, ZIP 2, anything else 3.
    let rank: Int

    static let city = 0
    static let county = 1
    static let postalCode = 2
    static let other = 3

    /// `CLGeocoder` path, used below iOS 26.
    ///
    /// `postalCode` is checked *after* the administrative tiers so a ZIP match
    /// cannot outrank a real city.
    init(_ placemark: CLPlacemark) {
        latitude = placemark.location?.coordinate.latitude ?? 0
        longitude = placemark.location?.coordinate.longitude ?? 0

        if placemark.locality != nil {
            rank = Self.city
        } else if placemark.subAdministrativeArea != nil {
            rank = Self.county
        } else if placemark.postalCode != nil {
            rank = Self.postalCode
        } else {
            rank = Self.other
        }
    }

    /// `MKGeocodingRequest` path, used at iOS 26+.
    ///
    /// **Known difference from the older path.** `MKAddressRepresentations` has
    /// no county or postal-code field, so the county and ZIP tiers collapse into
    /// the fallback: a candidate is either *city* or *other*. The city-over-state
    /// preference — the case that was measured to change results — is preserved
    /// exactly.
    ///
    /// **What this does not mean.** An earlier version of this comment said "a
    /// bare ZIP can therefore rank below a state, where previously it ranked
    /// above". That was over-stated: it conflated classifying a result with
    /// resolving a query. `rank` is only a tiebreaker across *multiple*
    /// candidates — callers take `preferLocality(...).first` — so a query that
    /// returns a single candidate is unaffected no matter its rank.
    ///
    /// **Measured** by `GeocoderComparisonTests`, which calls both Apple APIs
    /// with the same queries and compares the coordinates that actually select an
    /// Area. All six agree to **0 miles**: `Youngstown, Ohio` → 41.0991, -80.6500
    /// on both (so the 200-mile state-centroid regression does *not* carry over),
    /// and `44503` → 41.1011, -80.6499 on both (so ZIP search works). The one row
    /// where the ranks differ is `Ohio` — `CLGeocoder` 3, this initialiser 0 — and
    /// the coordinate is still identical.
    ///
    /// The collapsed tiers are therefore **cosmetically inert** on every query
    /// tested: they can change a candidate's label, never its coordinates nor its
    /// position in the list. The residual unknown is multi-candidate ordering,
    /// which no test query has produced.
    @available(iOS 26.0, *)
    init(_ item: MKMapItem) {
        latitude = item.location.coordinate.latitude
        longitude = item.location.coordinate.longitude
        rank = item.addressRepresentations?.cityName != nil ? Self.city : Self.other
    }

    /// Directly constructs a candidate. Only for tests and previews, which have
    /// no geocoder to call.
    init(latitude: Double, longitude: Double, rank: Int) {
        self.latitude = latitude
        self.longitude = longitude
        self.rank = rank
    }
}

enum GeocodeRanking {

    /// Orders candidates most-specific first.
    ///
    /// Apple returns several candidates for "City, State" and does not promise
    /// the city is first, so the ordering is applied by us rather than trusted.
    ///
    /// Stable: candidates that tie keep their original relative order, so a
    /// query with no city still resolves to whatever Apple returned first.
    ///
    /// The index is part of the comparison because Swift's `sorted` is **not**
    /// guaranteed stable — the earlier version of this function relied on
    /// stability it never had, which would have let tied results shuffle between
    /// runs. Ties are broken explicitly instead of assumed.
    static func preferLocality(_ candidates: [GeocodeCandidate]) -> [GeocodeCandidate] {
        candidates.enumerated()
            .sorted { a, b in
                if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// True when the geocoder understood the request and simply had no answer,
    /// as opposed to failing to reach the service.
    ///
    /// The two Apple APIs report this differently: `CLGeocoder` throws
    /// `CLError.geocodeFoundNoResult`, while `MKGeocodingRequest` reports an
    /// empty array (normalised to the same `CLError` by `resolve`), and older
    /// MapKit paths use `MKError.placemarkNotFound`. Both spellings are checked
    /// so the message the user sees does not change with the OS version.
    static func isNoResult(_ error: Error) -> Bool {
        if let clError = error as? CLError, clError.code == .geocodeFoundNoResult {
            return true
        }
        if let mkError = error as? MKError, mkError.code == .placemarkNotFound {
            return true
        }
        return false
    }

    /// Geocodes a free-text place name into ranked candidates.
    ///
    /// `MKGeocodingRequest` is preferred at iOS 26+ because `CLGeocoder` is
    /// deprecated there. The deprecated branch is kept for the app's iOS 17–25
    /// users, who have no replacement available, and is the reason this function
    /// exists as a separate seam rather than being inlined into the view: there
    /// is no way to write one call that compiles warning-free against a
    /// deployment target older than the replacement.
    ///
    /// Reached only from `AreaPickerView`. Covered by tests at the ranking and
    /// error-classification level; the network call itself is not stubbed.
    static func resolve(_ text: String) async throws -> [GeocodeCandidate] {
        if #available(iOS 26.0, *) {
            guard let request = MKGeocodingRequest(addressString: text) else {
                // The initialiser fails only for an empty address, which callers
                // exclude, so report "nothing found" rather than a connection
                // problem.
                throw CLError(.geocodeFoundNoResult)
            }
            let items = try await request.mapItems
            // An empty array is how the new API says "nothing found", so it is
            // normalised into the thrown form the older path already uses.
            // `isNoResult` therefore needs no third case.
            guard !items.isEmpty else { throw CLError(.geocodeFoundNoResult) }
            return items.map(GeocodeCandidate.init)
        }

        // iOS 17–25. Deprecated at 26, but the only option below it.
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(text)
        } catch {
            throw isNoResult(error) ? CLError(.geocodeFoundNoResult) : error
        }
        return placemarks.map(GeocodeCandidate.init)
    }
}
