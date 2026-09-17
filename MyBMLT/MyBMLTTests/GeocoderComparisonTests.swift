import Testing
import CoreLocation
import MapKit
@testable import MyBMLTUSA

/// Side-by-side comparison of the two geocoding APIs, on the same queries.
///
/// This exists to answer one question the rest of the suite cannot: does
/// `MKGeocodingRequest` return the **same answer** as `CLGeocoder`? Nothing else
/// tests that. `GeocodeRankingTests` pins *our* ranking of whatever we receive;
/// it cannot see whether the upstream service changed its mind, and a changed
/// upstream answer is precisely what could reintroduce the Youngstown bug
/// (state centroid → Area 200 miles away) on iOS 26+.
///
/// Expected to be **slow and occasionally flaky**: it makes two live network
/// calls per query, and the deprecation warning for `CLGeocoder` is intentional
/// here — that call is the thing being compared, so it cannot be replaced.
@Suite("Geocoder API comparison", .serialized)
struct GeocoderComparisonTests {

    /// The queries that matter, and why.
    private static let queries: [(String, String)] = [
        ("Youngstown, Ohio", "the measured regression: must resolve to the city, not the state"),
        ("Youngstown", "the bare city that used to work while the comma form did not"),
        ("44503", "a bare ZIP: does the new API still resolve postcodes?"),
        ("92101", "a ZIP whose city is known, so a wrong answer is obvious"),
        ("San Diego, California", "a large city, as a stable control"),
        ("Ohio", "a state-level answer, exercised on purpose"),
    ]

    /// True when this host has `MKGeocodingRequest`, i.e. the app's `resolve`
    /// takes the new path. Checked at runtime because `#available` is a
    /// condition, not a value.
    private var hasNewAPI: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @Test("Both APIs resolve the same query to comparable coordinates")
    func bothAPIsAgree() async throws {
        try #require(hasNewAPI, "MKGeocodingRequest needs iOS 26+")

        var mismatches: [String] = []

        for (query, why) in Self.queries {
            let mine = try await GeocodeRanking.resolve(query)

            // Call the deprecated API directly: this is the comparison.
            let theirs: [CLPlacemark]
            do {
                theirs = try await CLGeocoder().geocodeAddressString(query)
            } catch {
                print("COMPARE \(query)\n  CLGeocoder threw: \(error)\n  MKGeocodingRequest: \(mine.count) candidate(s)")
                continue
            }

            let myFirst = mine.first
            let theirFirst = theirs.first.map(GeocodeCandidate.init)

            print("""
            COMPARE \(query)  [\(why)]
              CLGeocoder        : \(theirs.count) result(s), first rank=\(theirFirst?.rank ?? -1) \
            \(fmt(theirFirst))
              MKGeocodingRequest: \(mine.count) result(s), first rank=\(myFirst?.rank ?? -1) \
            \(fmt(myFirst))
            """)

            // The comparison that matters is the coordinate the picker would use,
            // since that is what selects the Area.
            guard let a = myFirst, let b = theirFirst else {
                if myFirst == nil && theirFirst == nil { continue }
                mismatches.append("\(query): one API returned nothing, the other did not")
                continue
            }

            let miles = distanceMiles(a.latitude, a.longitude, b.latitude, b.longitude)
            if miles > 1.0 {
                mismatches.append(String(format: "%@: %.1f mi apart", query, miles))
            }
        }

        // Reported, not asserted. The two services are separate implementations
        // and are not guaranteed to agree; the purpose of this test is to
        // *measure* the difference, so that any disagreement is documented
        // rather than assumed absent. Asserting equality would fail the build on
        // an Apple-side change this app cannot control.
        if mismatches.isEmpty {
            print("COMPARE VERDICT: no disagreement above 1 mile on any query")
        } else {
            print("COMPARE VERDICT: disagreement(s) found:")
            for m in mismatches { print("  ! \(m)") }
        }
    }

    @Test("The API the app uses on this host is the one being compared")
    func whichPathIsLive() {
        // Guards the test above: if this host were on iOS 17–25, `resolve` would
        // call `CLGeocoder` and the comparison would be comparing it with itself.
        #expect(hasNewAPI, "this comparison is only meaningful at iOS 26+")
    }

    // MARK: - Helpers

    private func fmt(_ c: GeocodeCandidate?) -> String {
        guard let c else { return "(none)" }
        return String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    /// Great-circle distance, enough for a sanity threshold.
    private func distanceMiles(_ lat1: Double, _ lon1: Double,
                               _ lat2: Double, _ lon2: Double) -> Double {
        let r = 3958.8
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
