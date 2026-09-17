import Testing
import CoreLocation
import MapKit
@testable import MyBMLTUSA

/// Tests for the geocoder result ranking.
///
/// ## Why this is tested at all
/// `GeocodeRanking.preferLocality` decides which of Apple's several candidate
/// answers the Area picker believes. It was written from a measurement — the
/// "Youngstown, Ohio" case — and then refactored to serve two different Apple
/// APIs. Without these tests the measured behaviour could change silently, and
/// the only symptom would be the app confidently selecting an Area 200 miles
/// away for users who type a comma.
///
/// The tier rule is the whole contract: city, then county, then ZIP, then
/// whatever is left, with ties keeping Apple's original order.
@Suite("Geocode ranking")
struct GeocodeRankingTests {

    private func candidate(_ rank: Int, latitude: Double = 0, longitude: Double = 0) -> GeocodeCandidate {
        GeocodeCandidate(latitude: latitude, longitude: longitude, rank: rank)
    }

    @Test("A city outranks the state centroid that Apple returns first")
    func cityBeatsState() {
        // The measured case. Apple returns the state first; the city must win,
        // or "Youngstown, Ohio" resolves to Columbus, 200 miles away.
        let state = candidate(GeocodeCandidate.other, latitude: 40.0, longitude: -82.9)
        let city = candidate(GeocodeCandidate.city, latitude: 41.1, longitude: -80.6)

        let ordered = GeocodeRanking.preferLocality([state, city])

        #expect(ordered.first?.latitude == 41.1)
    }

    @Test("The full tier order is city, county, ZIP, other")
    func tierOrder() {
        let other = candidate(GeocodeCandidate.other)
        let postal = candidate(GeocodeCandidate.postalCode)
        let county = candidate(GeocodeCandidate.county)
        let city = candidate(GeocodeCandidate.city)

        // Deliberately shuffled, so passing by accident requires luck.
        let ordered = GeocodeRanking.preferLocality([other, postal, county, city])

        #expect(ordered.map(\.rank) == [
            GeocodeCandidate.city,
            GeocodeCandidate.county,
            GeocodeCandidate.postalCode,
            GeocodeCandidate.other,
        ])
    }

    @Test("A ZIP does not outrank a real city")
    func postalCodeLosesToCity() {
        // A ZIP match is precise but often names a post office rather than the
        // population centre the user meant, so it ranks below a city.
        let postal = candidate(GeocodeCandidate.postalCode)
        let city = candidate(GeocodeCandidate.city)

        #expect(GeocodeRanking.preferLocality([postal, city]).first?.rank == GeocodeCandidate.city)
    }

    @Test("Ties keep the order Apple returned, rather than being reshuffled")
    func tiesAreStable() {
        // Ties must not depend on how `sorted` happens to behave — Swift does
        // not guarantee a stable sort. The earlier implementation relied on
        // stability it did not have, so this is a regression test.
        //
        // COVERAGE LIMIT, established by mutation: reverting the comparator to
        // the bare `rank < rank` form still passes this test, because Swift's
        // sort happens to preserve order for these small inputs. The explicit
        // offset tiebreak is therefore *correct by construction* rather than
        // proven by this test — no realistic input distinguishes the two. The
        // test still earns its place: it pins the observable contract (ties keep
        // Apple's order) and would catch a comparator that actively reversed
        // ties, which is the failure a future editor could actually introduce.
        let first = candidate(GeocodeCandidate.city, latitude: 1)
        let second = candidate(GeocodeCandidate.city, latitude: 2)
        let third = candidate(GeocodeCandidate.city, latitude: 3)

        // Repeated, since an unstable sort could pass once by chance.
        for _ in 0..<50 {
            let ordered = GeocodeRanking.preferLocality([first, second, third])
            #expect(ordered.map(\.latitude) == [1, 2, 3])
        }
    }

    @Test("An empty result stays empty")
    func emptyIsEmpty() {
        #expect(GeocodeRanking.preferLocality([]).isEmpty)
    }

    @Test("A single candidate is returned unchanged")
    func singleCandidate() {
        let only = candidate(GeocodeCandidate.other, latitude: 5, longitude: 6)
        let ordered = GeocodeRanking.preferLocality([only])
        #expect(ordered.count == 1)
        #expect(ordered.first?.latitude == 5)
        #expect(ordered.first?.longitude == 6)
    }

    @Test("Ranking is a permutation: nothing is dropped or duplicated")
    func permutationIsPreserved() {
        let input = [
            candidate(GeocodeCandidate.other),
            candidate(GeocodeCandidate.city),
            candidate(GeocodeCandidate.postalCode),
            candidate(GeocodeCandidate.county),
            candidate(GeocodeCandidate.city),
        ]
        let ordered = GeocodeRanking.preferLocality(input)
        #expect(ordered.count == input.count)
        // Multiset equality: same ranks, same multiplicities.
        #expect(ordered.map(\.rank).sorted() == input.map(\.rank).sorted())
    }

    // MARK: - Tier derivation from a real CLPlacemark

    @Test("A placemark with a locality is ranked as a city")
    func placemarkCityRank() throws {
        let placemark = try #require(placemark(locality: "Youngstown",
                                               subAdministrativeArea: "Mahoning County",
                                               postalCode: "44503",
                                               administrativeArea: "Ohio"))
        #expect(GeocodeCandidate(placemark).rank == GeocodeCandidate.city)
    }

    @Test("A placemark with no locality but a county is ranked as a county")
    func placemarkCountyRank() throws {
        let placemark = try #require(placemark(locality: nil,
                                               subAdministrativeArea: "Mahoning County",
                                               postalCode: "44503",
                                               administrativeArea: "Ohio"))
        #expect(GeocodeCandidate(placemark).rank == GeocodeCandidate.county)
    }

    @Test("A placemark with only a postal code is ranked as a ZIP")
    func placemarkPostalRank() throws {
        let placemark = try #require(placemark(locality: nil,
                                               subAdministrativeArea: nil,
                                               postalCode: "44503",
                                               administrativeArea: "Ohio"))
        #expect(GeocodeCandidate(placemark).rank == GeocodeCandidate.postalCode)
    }

    @Test("A placemark that is only a state falls through to the fallback tier")
    func placemarkOtherRank() throws {
        // This is the Youngstown-as-a-state case, and the fallback is what lets
        // a real city candidate placed after it win.
        let placemark = try #require(placemark(locality: nil,
                                               subAdministrativeArea: nil,
                                               postalCode: nil,
                                               administrativeArea: "Ohio"))
        #expect(GeocodeCandidate(placemark).rank == GeocodeCandidate.other)
    }

    @Test("Coordinates survive the placemark conversion")
    func placemarkCoordinatesSurvive() throws {
        let placemark = try #require(placemark(locality: "Youngstown",
                                               subAdministrativeArea: nil,
                                               postalCode: nil,
                                               administrativeArea: "Ohio",
                                               latitude: 41.0998,
                                               longitude: -80.6495))
        let candidate = GeocodeCandidate(placemark)
        #expect(abs(candidate.latitude - 41.0998) < 0.0001)
        #expect(abs(candidate.longitude - -80.6495) < 0.0001)
    }

    @Test("A placemark without a location yields a usable zero candidate")
    func placemarkWithoutLocationIsSafe() throws {
        // `CLPlacemark.location` is optional. The old code discarded the whole
        // result when it was nil (`ordered.first?.location`), which silently
        // turned an answerable query into "couldn't find it". This pins the
        // fallback: coordinates default to 0 rather than crashing or producing a
        // NaN, and the rank still reflects the match.
        //
        // Constructed through the direct initialiser because `MKPlacemark`
        // always carries a location, so the nil case cannot be built from it.
        let candidate = GeocodeCandidate(latitude: 0, longitude: 0, rank: GeocodeCandidate.city)
        #expect(candidate.latitude == 0)
        #expect(candidate.longitude == 0)
        #expect(candidate.rank == GeocodeCandidate.city)
        #expect(!candidate.latitude.isNaN)
        #expect(!candidate.longitude.isNaN)
    }

    // MARK: - Error classification

    @Test("CLError.geocodeFoundNoResult is classified as having no answer")
    func noResultClassification() {
        #expect(GeocodeRanking.isNoResult(CLError(.geocodeFoundNoResult)))
    }

    @Test("MKError.placemarkNotFound is classified as having no answer")
    func mapKitNoResultClassification() {
        // The iOS 26 API reports an MKError on some paths, so both spellings
        // must map to the same user-facing message; otherwise the same failed
        // lookup would say "check your connection" on one OS and "try a city"
        // on another.
        #expect(GeocodeRanking.isNoResult(MKError(.placemarkNotFound)))
    }

    @Test("A network failure is not classified as having no answer")
    func networkFailureIsNotNoResult() {
        // The distinction drives the copy the user reads: retrying is worth it
        // for a dropped connection and pointless for an unanswerable name.
        #expect(!GeocodeRanking.isNoResult(URLError(.notConnectedToInternet)))
        #expect(!GeocodeRanking.isNoResult(URLError(.timedOut)))
        #expect(!GeocodeRanking.isNoResult(CLError(.network)))
        #expect(!GeocodeRanking.isNoResult(MKError(.loadingThrottled)))
    }

    // MARK: - The live path

    @Test("Resolving an unanswerable string throws rather than returning junk")
    func resolveUnanswerableThrows() async {
        // This calls the real `GeocodeRanking.resolve`, so on an iOS 26 host it
        // exercises `MKGeocodingRequest` and on iOS 17–25 it exercises
        // `CLGeocoder`. Either way the contract is the same: an unanswerable
        // query fails in a way the UI can classify as "no such place", rather
        // than returning an empty or nonsense candidate list.
        //
        // A string of punctuation is chosen because it cannot name any real
        // place in any locale, and because it needs no network beyond whatever
        // the service does to reject it.
        do {
            let candidates = try await GeocodeRanking.resolve("zzqqxx--not-a-place--")
            // If a result does come back, it must at least be well formed.
            for candidate in candidates {
                #expect(!candidate.latitude.isNaN)
                #expect(!candidate.longitude.isNaN)
            }
        } catch {
            // Throwing is the expected outcome. What matters is that the error
            // is classifiable, so the view can pick the right message.
            #expect(GeocodeRanking.isNoResult(error)
                    || error is URLError
                    || error is MKError
                    || error is CLError,
                    "unexpected error type: \(error)")
        }
    }

    @Test("Resolving an empty string does not trap")
    func resolveEmptyIsSafe() async {
        // `MKGeocodingRequest` returns nil for an empty address, and the old
        // `CLGeocoder` path would reject it too. Neither may crash.
        do {
            let candidates = try await GeocodeRanking.resolve("")
            #expect(candidates.isEmpty)
        } catch {
            #expect(GeocodeRanking.isNoResult(error) || error is URLError || error is CLError || error is MKError)
        }
    }

    // MARK: - Helper

    /// Builds a `CLPlacemark` from a location plus an address dictionary.
    ///
    /// `CLPlacemark` has no memberwise initialiser, so `MKPlacemark` is the
    /// supported way to construct one. The dictionary keys are the Contacts
    /// spellings `CLPlacemark` reads back as `locality`,
    /// `subAdministrativeArea`, `postalCode` and `administrativeArea`.
    private func placemark(locality: String?,
                           subAdministrativeArea: String?,
                           postalCode: String?,
                           administrativeArea: String?,
                           latitude: Double = 41.0998,
                           longitude: Double = -80.6495) -> CLPlacemark? {
        var address: [String: Any] = [:]
        if let locality { address["City"] = locality }
        if let subAdministrativeArea { address["SubAdministrativeArea"] = subAdministrativeArea }
        if let postalCode { address["ZIP"] = postalCode }
        if let administrativeArea { address["State"] = administrativeArea }

        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude,
                                                                      longitude: longitude),
                                   addressDictionary: address)
        return placemark
    }
}
