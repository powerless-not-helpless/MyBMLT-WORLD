import Testing
import Foundation
@testable import MyBMLTUSA

/// Tests for the favourite/explore store, especially the migration path, which
/// is where silent data corruption would live.
///
/// Uses a temp directory so tests never touch the real Application Support.
@Suite("Meeting set store")
@MainActor
struct MeetingSetStoreTests {

    private func tempStore() -> FileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyBMLTTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStore(testDirectory: dir)
    }

    private func meeting(id: Int, root: Int, name: String = "M",
                         weekday: Int = 2, start: String = "19:00:00") -> Meeting {
        Meeting(
            id: id, rootServerID: root, name: name, weekday: weekday,
            startTime: start, duration: "01:00:00", locationName: "",
            street: "", city: "", zip: "", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: 1,
            latitude: nil, longitude: nil, timeZoneID: "", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Toggling adds then removes, keyed by uid")
    func toggle() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let m = meeting(id: 5, root: 38)

        #expect(!store.contains(m))
        store.toggle(m)
        #expect(store.contains(m))
        #expect(store.count == 1)
        store.toggle(m)
        #expect(!store.contains(m))
        #expect(store.count == 0)
    }

    @Test("Same local id on different servers are independent entries")
    func crossServerIndependence() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let a = meeting(id: 42, root: 1, name: "Austin")
        let b = meeting(id: 42, root: 38, name: "San Diego")

        store.toggle(a)

        #expect(store.contains(a))
        // The whole point of uid: favouriting one must not favourite the other.
        #expect(!store.contains(b))
        #expect(store.count == 1)
    }

    @Test("Persists across instances")
    func persistence() {
        let files = tempStore()
        let m = meeting(id: 9, root: 38)

        let first = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        first.toggle(m)

        let second = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(second.contains(m))
        #expect(second.all.count == 1)
    }

    @Test("all returns meetings sorted by weekday then start time")
    func sortedOutput() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 1, root: 1, weekday: 3, start: "10:00:00"))
        store.toggle(meeting(id: 2, root: 1, weekday: 1, start: "20:00:00"))
        store.toggle(meeting(id: 3, root: 1, weekday: 3, start: "08:00:00"))

        let order = store.all.map(\.id)
        #expect(order == [2, 3, 1])
    }

    @Test("updateRecords refreshes details without changing membership")
    func recordRefresh() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let original = meeting(id: 7, root: 38, name: "Old Name")
        store.toggle(original)

        let updated = meeting(id: 7, root: 38, name: "New Name")
        store.updateRecords(from: [updated])

        #expect(store.count == 1)
        #expect(store.all.first?.name == "New Name")
    }

    @Test("updateRecords ignores meetings that are not in the set")
    func recordRefreshIgnoresStrangers() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 1, root: 1))
        store.updateRecords(from: [meeting(id: 99, root: 1)])
        #expect(store.count == 1)
    }
}

/// Tests for field-aware change notices on saved favourites.
///
/// The contract has two halves, and both need guarding: a change the user must
/// act on raises a notice, and cosmetic churn does **not**. The second half is
/// the one that decays silently — a false-positive notice trains people to
/// ignore the banner, which is worse than shipping none.
@Suite("Change notices")
@MainActor
struct ChangeNoticeTests {

    private func tempStore() -> FileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyBMLTChange-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStore(testDirectory: dir)
    }

    private func meeting(
        id: Int = 7,
        root: Int = 38,
        name: String = "Monday Night Group",
        weekday: Int = 2,
        start: String = "19:00:00",
        duration: String = "01:00:00",
        street: String = "123 Main St",
        city: String = "San Diego",
        zip: String = "92101",
        locationName: String = "Clubhouse",
        virtualLink: String? = nil,
        virtualInfo: String? = nil,
        formats: [String] = [],
        serviceBodyName: String = "SDICR",
        venueType: Int = 1,
        latitude: Double? = 32.7157,
        longitude: Double? = -117.1611
    ) -> Meeting {
        Meeting(
            id: id, rootServerID: root, name: name, weekday: weekday,
            startTime: start, duration: duration, locationName: locationName,
            street: street, city: city, zip: zip, locationInfo: "",
            virtualLink: virtualLink, virtualInfo: virtualInfo, formats: formats,
            serviceBodyID: 1, serviceBodyName: serviceBodyName, venueType: venueType,
            latitude: latitude, longitude: longitude, timeZoneID: "",
            distanceMiles: nil, distanceKilometers: nil
        )
    }

    // MARK: - Behavioural changes raise a notice

    @Test("A start-time change raises a schedule notice")
    func scheduleChange() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(start: "20:00:00")])

        #expect(store.pendingChanges(for: saved) == [.schedule])
        #expect(store.all.first?.startTime == "20:00:00")
    }

    @Test("A street change raises a location notice")
    func locationChange() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(street: "456 Oak Ave")])

        #expect(store.pendingChanges(for: saved) == [.location])
    }

    @Test("A rotated password raises an online notice")
    func passwordChange() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(virtualLink: "https://zoom.us/j/9163380135",
                            virtualInfo: "Passcode: 11111",
                            venueType: 2)
        store.toggle(saved)

        store.updateRecords(from: [meeting(virtualLink: "https://zoom.us/j/9163380135",
                                           virtualInfo: "Passcode: 22222",
                                           venueType: 2)])

        #expect(store.pendingChanges(for: saved) == [.online])
    }

    @Test("An in-person meeting becoming virtual raises an online notice")
    func venueTypeChange() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(venueType: 2)])

        #expect(store.pendingChanges(for: saved) == [.online])
    }

    @Test("Multiple changes are reported ordered schedule, location, online")
    func multipleChangesOrdered() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(start: "21:00:00",
                                           street: "789 Elm St",
                                           venueType: 3)])

        #expect(store.pendingChanges(for: saved) == [.schedule, .location, .online])
    }

    // MARK: - Cosmetic churn stays silent

    @Test("A format-code change heals silently")
    func formatsAreCosmetic() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(formats: ["O", "D"])
        store.toggle(saved)

        store.updateRecords(from: [meeting(formats: ["D", "O", "JT"])])

        #expect(store.pendingChanges(for: saved).isEmpty)
        // The record still heals — silence is not staleness.
        #expect(store.all.first?.formats == ["D", "O", "JT"])
    }

    @Test("A sub-11m coordinate nudge is not a move")
    func tinyCoordinateDriftIsCosmetic() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        // ~5 m of drift, the kind a re-geocode of the same building produces.
        store.updateRecords(from: [meeting(latitude: 32.71575, longitude: -117.16115)])

        #expect(store.pendingChanges(for: saved).isEmpty)
    }

    @Test("A genuine venue relocation is a move")
    func realRelocationIsNotCosmetic() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(latitude: 32.8000, longitude: -117.2000)])

        #expect(store.pendingChanges(for: saved) == [.location])
    }

    @Test("Case and whitespace tidy-ups are not changes")
    func whitespaceIsCosmetic() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(street: "123 Main St")
        store.toggle(saved)

        store.updateRecords(from: [meeting(street: "123 Main St  ",
                                           city: "SAN DIEGO")])

        #expect(store.pendingChanges(for: saved).isEmpty)
    }

    // MARK: - Throttling

    @Test("A notice survives a relaunch")
    func noticePersists() {
        let files = tempStore()
        let saved = meeting()

        let first = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        first.toggle(saved)
        first.updateRecords(from: [meeting(start: "20:00:00")])
        #expect(first.pendingChanges(for: saved) == [.schedule])

        // A fresh instance reads the persisted notice, so the banner does not
        // vanish with the stale time still unsaved.
        let second = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(second.pendingChanges(for: saved) == [.schedule])
        #expect(second.unseenChangeCount == 1)
    }

    @Test("Acknowledging clears the notice permanently")
    func acknowledgementIsPermanent() {
        let files = tempStore()
        let saved = meeting()

        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        store.toggle(saved)
        store.updateRecords(from: [meeting(start: "20:00:00")])
        store.acknowledgeChanges(for: saved)
        #expect(store.pendingChanges(for: saved).isEmpty)

        let reopened = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(reopened.pendingChanges(for: saved).isEmpty)
        #expect(reopened.hasUnseenChanges == false)
    }

    @Test("Two refreshes in one unacknowledged window union their notices")
    func noticesUnionRatherThanReplace() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting(start: "20:00:00")])
        store.updateRecords(from: [meeting(start: "20:00:00", street: "456 Oak Ave")])

        #expect(store.pendingChanges(for: saved) == [.schedule, .location])
    }

    @Test("Re-saving the same meeting clears a stale notice")
    func retoggleClearsNotice() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)
        store.updateRecords(from: [meeting(start: "20:00:00")])
        #expect(!store.pendingChanges(for: saved).isEmpty)

        // Unstar then re-star at the new time: it is current again, so the
        // notice must not linger.
        store.toggle(meeting(start: "20:00:00"))
        store.toggle(meeting(start: "20:00:00"))

        #expect(store.pendingChanges(for: saved).isEmpty)
    }

    @Test("The badge counts changes, not meetings")
    func badgeCountsChanges() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let a = meeting(id: 1, name: "A")
        let b = meeting(id: 2, name: "B")
        store.toggle(a)
        store.toggle(b)

        // One meeting changed two ways, the other one way: four, not two.
        store.updateRecords(from: [
            meeting(id: 1, name: "A", start: "20:00:00", street: "456 Oak Ave"),
            meeting(id: 2, name: "B", start: "21:00:00"),
        ])

        #expect(store.unseenChangeCount == 3)
    }

    @Test("Removing a favourite drops its notice")
    func removingClearsNotice() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)
        store.updateRecords(from: [meeting(start: "20:00:00")])

        store.toggle(meeting(start: "20:00:00"))

        #expect(store.hasUnseenChanges == false)
    }

    @Test("An identical record raises nothing")
    func identicalRecordIsSilent() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting()
        store.toggle(saved)

        store.updateRecords(from: [meeting()])

        #expect(store.pendingChanges(for: saved).isEmpty)
    }

    // MARK: - Out-of-Area verification

    @Test("unverifiedIDs returns only saved meetings absent from the known set")
    func unverifiedIDsExcludesKnown() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let inArea = meeting(id: 1, root: 38)
        let outOfArea = meeting(id: 2, root: 7)
        store.toggle(inArea)
        store.toggle(outOfArea)

        let byRoot = store.unverifiedIDs(notIn: [inArea.uid])

        // Grouped by root server, because a bare id is ambiguous server-side.
        #expect(byRoot == [7: [2]])
    }

    @Test("unverifiedIDs returns nil when everything saved is already known")
    func unverifiedIDsNilWhenCovered() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let m = meeting(id: 1, root: 38)
        store.toggle(m)

        #expect(store.unverifiedIDs(notIn: [m.uid]) == nil)
    }

    @Test("unverifiedIDs groups ids across several root servers")
    func unverifiedIDsGroupsByServer() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 5, root: 7))
        store.toggle(meeting(id: 6, root: 7))
        store.toggle(meeting(id: 9, root: 12))

        let byRoot = store.unverifiedIDs(notIn: [])

        #expect(byRoot?[7]?.sorted() == [5, 6])
        #expect(byRoot?[12] == [9])
    }

    @Test("A fresh list needs no verification; an unverified one does")
    func verificationGate() {
        let files = tempStore()
        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)

        // Empty list: nothing to verify, so the tab never fires a request.
        #expect(store.needsVerification == false)

        store.toggle(meeting(id: 1, root: 38))
        // Just saved, but never reconciled with the server.
        #expect(store.needsVerification == true)

        store.markVerified()
        #expect(store.needsVerification == false)
    }

    @Test("The verification clock survives a relaunch")
    func verificationClockPersists() {
        let files = tempStore()
        let first = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        first.toggle(meeting(id: 1, root: 38))
        first.markVerified()

        let second = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        // Without persistence the 6 h gate would reset on every launch and
        // re-query on each cold start.
        #expect(second.needsVerification == false)
        #expect(second.lastVerified != nil)
    }

    @Test("An expired verification window re-opens the gate")
    func verificationWindowExpires() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 1, root: 38))

        // Older than CachePolicy.meetings (6 h).
        store.markVerified(at: Date().addingTimeInterval(-7 * 60 * 60))

        #expect(store.needsVerification == true)
    }

    @Test("applyVerified heals a record and raises its notice")
    func applyVerifiedRaisesNotice() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        store.applyVerified([meeting(id: 2, root: 7, start: "21:00:00")])

        #expect(store.pendingChanges(for: saved) == [.schedule])
        #expect(store.needsVerification == false)
    }

    @Test("applyVerified cannot add a meeting that is not saved")
    func applyVerifiedRespectsMembership() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        store.toggle(meeting(id: 1, root: 38))

        // A response for a meeting the user never saved must not be inserted.
        store.applyVerified([meeting(id: 999, root: 7)])

        #expect(store.count == 1)
        #expect(store.all.first?.id == 1)
    }

    @Test("A record from the wrong root server is not applied")
    func wrongServerIsRejected() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        // Saved as root 7 id 2.
        let saved = meeting(id: 2, root: 7, name: "Saved")
        store.toggle(saved)

        // The aggregator resolves a bare id against whichever server owns it
        // first. This row shares the id but is a different meeting on root 38,
        // so its uid differs and it must be ignored rather than diffed.
        store.applyVerified([meeting(id: 2, root: 38, name: "Unrelated")])

        #expect(store.all.first?.uid == "7:2")
        #expect(store.all.first?.name == "Saved")
        #expect(store.pendingChanges(for: saved).isEmpty)
    }

    // MARK: - Deleted meetings

    @Test("One absence is not enough to call a meeting deleted")
    func singleAbsenceIsNotConfirmed() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // A lone empty response could be a hiccup, so the banner must wait.
        store.recordObservations(requested: [saved.uid], returned: [])

        #expect(store.confirmedMissingUIDs.isEmpty)
        #expect(store.isMissing(saved) == false)
    }

    @Test("Two consecutive absences confirm a meeting as missing")
    func twoAbsencesConfirm() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])

        #expect(store.isMissing(saved))
        #expect(store.confirmedMissingUIDs == [saved.uid])
        #expect(store.missingFirstNoticed(saved) != nil)
    }

    @Test("A whole batch coming back empty is treated as a bad query, not deletions")
    func allAbsentIsRefused() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        // A batch at or above the mass-absence threshold, where a wrong
        // root_server_ids[] is far likelier than simultaneous deletions.
        let saved = (1...6).map { meeting(id: $0, root: 7, name: "M\($0)") }
        saved.forEach { store.toggle($0) }
        let uids = Set(saved.map(\.uid))

        for _ in 0..<5 {
            store.recordObservations(requested: uids, returned: [])
        }

        #expect(store.confirmedMissingUIDs.isEmpty)
        #expect(saved.allSatisfy { !store.isMissing($0) })
    }

    @Test("A small all-absent batch is still recorded")
    func smallAllAbsentIsRecorded() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // One favourite, deleted. This is ordinary and must not be mistaken
        // for the systematic-failure case above.
        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])

        #expect(store.isMissing(saved))
    }

    @Test("A mixed batch records only the absent ones")
    func partialAbsenceIsRecorded() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let live = meeting(id: 1, root: 7, name: "Live")
        let gone = meeting(id: 2, root: 7, name: "Gone")
        store.toggle(live)
        store.toggle(gone)

        for _ in 0..<2 {
            store.recordObservations(requested: [live.uid, gone.uid], returned: [live.uid])
        }

        #expect(store.isMissing(gone))
        #expect(store.isMissing(live) == false)
    }

    @Test("A meeting reappearing clears its deletion banner")
    func reappearanceClearsMissing() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])
        #expect(store.isMissing(saved))

        // The server returns it again. A false positive must be recoverable
        // without the user doing anything.
        store.recordObservations(requested: [saved.uid], returned: [saved.uid])

        #expect(store.isMissing(saved) == false)
        #expect(store.confirmedMissingUIDs.isEmpty)
    }

    @Test("A confirmed deletion is forgotten once the meeting is unstarred")
    func unstarringClearsMissing() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)
        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])
        #expect(store.isMissing(saved))

        // Re-starring must not resurrect the old flag either.
        store.toggle(saved)
        store.toggle(saved)

        #expect(store.isMissing(saved) == false)
    }

    @Test("A deletion notice survives a relaunch")
    func missingPersistsAcrossInstances() {
        let files = tempStore()
        let saved = meeting(id: 2, root: 7)

        let first = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        first.toggle(saved)
        first.recordObservations(requested: [saved.uid], returned: [])
        first.recordObservations(requested: [saved.uid], returned: [])

        let second = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(second.isMissing(saved))
        #expect(second.missingCount == 1)
    }

    @Test("A deleted meeting keeps rendering from its saved record")
    func missingMeetingRetainsRecord() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7, name: "Gone Group")
        store.toggle(saved)
        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])

        // Detection must never be destructive: the user still sees the last
        // known details and decides for themselves when to remove it.
        #expect(store.count == 1)
        #expect(store.all.first?.name == "Gone Group")
    }

    @Test("A deleted meeting is not asked about again once flagged")
    func missingMeetingStillRequested() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)
        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])

        // Still queried, so a reappearing meeting heals. It is absent from the
        // in-area known set, so the out-of-area path covers it.
        #expect(store.unverifiedIDs(notIn: [])?[7] == [2])
    }

    @Test("The badge counts a deleted meeting once, not twice")
    func badgeDoesNotDoubleCount() {
        let store = MeetingSetStore(kind: .favorites, store: tempStore())
        let saved = meeting(id: 2, root: 7)
        store.toggle(saved)

        // A change notice first, then the meeting vanishes.
        store.updateRecords(from: [meeting(id: 2, root: 7, start: "22:00:00")])
        store.recordObservations(requested: [saved.uid], returned: [])
        store.recordObservations(requested: [saved.uid], returned: [])

        let missing = store.confirmedMissingUIDs
        #expect(missing == [saved.uid])
        // Excluded from the change tally, so 1 missing + 0 changes = 1.
        #expect(store.unseenChangeCountExcluding(missing) == 0)
    }
}

/// Tests for the legacy migration.
///
/// The legacy format stored a bare `[Int]` of `id_bigint`s from
/// `bmlt.wszf.org`. Those IDs do not transfer to the aggregator (SDICR is 1155
/// there and 2313 here, with different meeting IDs), so matching must be by
/// content fingerprint.
@Suite("Legacy migration")
@MainActor
struct MigrationTests {

    private func tempStore() -> FileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyBMLTMigrate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileStore(testDirectory: dir)
    }

    private func meeting(id: Int, root: Int, name: String,
                         weekday: Int = 2, start: String = "19:00:00") -> Meeting {
        Meeting(
            id: id, rootServerID: root, name: name, weekday: weekday,
            startTime: start, duration: "01:00:00", locationName: "",
            street: "", city: "", zip: "", locationInfo: "",
            virtualLink: nil, virtualInfo: nil, formats: [],
            serviceBodyID: 1, serviceBodyName: "", venueType: 1,
            latitude: nil, longitude: nil, timeZoneID: "", distanceMiles: nil, distanceKilometers: nil
        )
    }

    @Test("Migrates a legacy favourite onto the aggregator meeting with the same content")
    func migratesByFingerprint() {
        let files = tempStore()
        // Legacy: wszf ids, and the pre-rewrite app stored these with root 0.
        files.write([16533], to: "favorites_cache.json")

        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(store.pendingLegacyIDs == [16533])

        // The same physical meeting on the aggregator has a different id.
        let legacyMeeting = meeting(id: 16533, root: 0, name: "Monday Night Group")
        let freshMeeting = meeting(id: 148885, root: 38, name: "Monday Night Group")

        store.resolveLegacy(legacyMeetings: [legacyMeeting], against: [freshMeeting])

        #expect(store.count == 1)
        #expect(store.all.first?.uid == "38:148885")
        #expect(store.pendingLegacyIDs.isEmpty)
    }

    @Test("Drops a legacy favourite whose meeting is ambiguous rather than guessing")
    func dropsAmbiguous() {
        let files = tempStore()
        files.write([100], to: "favorites_cache.json")

        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)

        // Two distinct meetings share name + weekday + start time. This is real:
        // verified 10 such pairs in the actual 372-meeting SDICR cache.
        let legacyMeeting = meeting(id: 100, root: 0, name: "Solo Por Hoy")
        let twinA = meeting(id: 18176, root: 38, name: "Solo Por Hoy")
        let twinB = meeting(id: 18271, root: 38, name: "Solo Por Hoy")

        store.resolveLegacy(legacyMeetings: [legacyMeeting], against: [twinA, twinB])

        // A lost favourite is recoverable; one silently pointing at a different
        // meeting is not.
        #expect(store.count == 0)
    }

    @Test("Drops a legacy favourite with no counterpart on the server")
    func dropsUnmatched() {
        let files = tempStore()
        files.write([999], to: "favorites_cache.json")

        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        let legacyMeeting = meeting(id: 999, root: 0, name: "Gone Forever")

        store.resolveLegacy(legacyMeetings: [legacyMeeting], against: [])

        #expect(store.count == 0)
        #expect(store.pendingLegacyIDs.isEmpty)
    }

    @Test("Migration runs once and removes the legacy file")
    func runsOnce() {
        let files = tempStore()
        files.write([1], to: "favorites_cache.json")

        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        store.resolveLegacy(legacyMeetings: [], against: [])
        store.resolveLegacy(legacyMeetings: [], against: [])

        #expect(!files.exists("favorites_cache.json"))
        #expect(store.count == 0)
    }

    @Test("Is a no-op when there is no legacy file")
    func noLegacyFile() {
        let files = tempStore()
        let store = MeetingSetStore(kind: .favorites, store: files, legacyStore: files)
        #expect(store.pendingLegacyIDs.isEmpty)
    }
}

/// Tests for the service body tree, especially the helpline ancestor walk.
/// Verified in real data: the SDICR region carries the helpline and every
/// sub-area returns an empty string.
@Suite("Service body tree")
struct ServiceBodyTreeTests {

    private let region = ServiceBody(
        id: 2313, parentID: 1812, name: "San Diego Imperial Counties Region", description: nil, type: "RS", url: "www.sandiegona.org", helpline: "6195841007",
        worldID: "RG590", rootServerID: 38
    )

    private let area = ServiceBody(
        id: 2315, parentID: 2313, name: "Central Area", description: nil, type: "AS",
        url: "http://www.sdcentralareana.org/", helpline: "",
        worldID: "AR59004", rootServerID: 38
    )

    private let subArea = ServiceBody(
        id: 2320, parentID: 2313, name: "South East Barrio Area", description: nil, type: "AS",
        url: nil, helpline: "", worldID: "AR59008", rootServerID: 38
    )

    @Test("Finds the region's helpline from a child area")
    func helplineWalk() throws {
        let tree = ServiceBodyTree([region, area, subArea])
        let found = try #require(tree.nearestHelpline(for: area))

        #expect(found.helpline.dialString == "6195841007")
        #expect(found.helpline.display == "(619) 584-1007")
        // Must attribute the number to the region, not the area that lacks one.
        #expect(found.body.id == 2313)
    }

    @Test("Returns nil when no ancestor has a helpline")
    func noHelpline() {
        let orphan = ServiceBody(id: 9999, parentID: nil, name: "Nowhere", description: nil, type: "AS", url: nil, helpline: "",
                                 worldID: nil, rootServerID: 38)
        let tree = ServiceBodyTree([orphan])
        #expect(tree.nearestHelpline(for: orphan) == nil)
    }

    @Test("Rejects placeholder helplines made entirely of zeros")
    func rejectsPlaceholder() {
        // Verified: some bodies literally return "0000000000".
        let junk = ServiceBody(id: 2, parentID: nil, name: "Junk", description: nil, type: "AS",
                               url: nil, helpline: "0000000000",
                               worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([junk])
        #expect(tree.nearestHelpline(for: junk) == nil)
    }

    @Test("Normalizes bare hostnames into https URLs")
    func urlNormalization() throws {
        // Verified: the SDICR returns "www.sandiegona.org" with no scheme.
        let url = try #require(region.webURL)
        #expect(url.scheme == "https")
        #expect(url.host == "www.sandiegona.org")
    }

    @Test("Children are matched within the same root server only")
    func childrenAreServerScoped() {
        // A different server reusing id 2313 as a parent must not adopt the
        // SDICR's areas.
        let impostor = ServiceBody(id: 5000, parentID: 2313, name: "Impostor", description: nil, type: "AS", url: nil, helpline: "",
                                   worldID: nil, rootServerID: 99)
        let tree = ServiceBodyTree([region, area, subArea, impostor])

        let kids = tree.children(of: region)
        #expect(kids.count == 2)
        #expect(!kids.contains { $0.rootServerID == 99 })
    }

    @Test("uid namespaces service bodies by root server")
    func bodyUID() {
        #expect(region.uid == "38:2313")
    }

    @Test("Search matches on name substring")
    func search() {
        let tree = ServiceBodyTree([region, area, subArea])
        #expect(tree.search("central").count == 1)
        #expect(tree.search("San Diego").count == 1)
        // Too short to be useful.
        #expect(tree.search("a").isEmpty)
    }

    /// Real report: searching "Sonoma, California" returned seven California
    /// regions alongside the one area the user actually named.
    @Test("Search tolerates a comma-separated city, state query")
    func searchCommaSeparated() {
        let sonoma = ServiceBody(id: 100, parentID: 1, name: "Sonoma County Area", description: nil, type: "AS", url: nil, helpline: "",
                                 worldID: nil, rootServerID: 1)
        let california = ServiceBody(id: 101, parentID: 1, name: "Northern California Region", description: nil, type: "RS", url: nil, helpline: "",
                                     worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([sonoma, california])

        let hits = tree.search("Sonoma, California")
        // Only the named area: Sonoma matched, so the state token adds nothing.
        #expect(hits.count == 1)
        #expect(hits.first?.name == "Sonoma County Area")
    }

    @Test("Search falls back to the state when no body names the city")
    func searchFallsBackToState() {
        // Youngstown's meetings live under the Ohio Region; nothing says
        // "Youngstown". Matching the state token is the best available answer.
        let ohioRegion = ServiceBody(id: 930, parentID: 1, name: "Ohio Region", description: nil, type: "RS", url: nil, helpline: "",
                                     worldID: nil, rootServerID: 27)
        let neOhio = ServiceBody(id: 1575, parentID: 930, name: "NE Ohio Area", description: nil, type: "AS", url: nil, helpline: "",
                                 worldID: nil, rootServerID: 27)
        let tree = ServiceBodyTree([ohioRegion, neOhio])

        let hits = tree.search("Youngstown, Ohio")
        #expect(hits.count == 2)
        // Shortest name first within the same token score.
        #expect(hits.first?.name == "Ohio Region")
    }

    /// Real bug: "Mexico" matched "New Mexico" because it was a substring.
    @Test("A qualifier makes a different place — Mexico is not New Mexico")
    func mexicoIsNotNewMexico() {
        let newMexico = ServiceBody(id: 1, parentID: nil, name: "Southern New Mexico Area",
                                    description: nil, type: "AS", url: nil, helpline: "",
                                    worldID: nil, rootServerID: 1)
        let realMexico = ServiceBody(id: 2, parentID: nil, name: "Mexico Area",
                                     description: nil, type: "AS", url: nil, helpline: "",
                                     worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([newMexico, realMexico])

        let hits = tree.search("Mexico")
        // New Mexico must not match, because "New" changes which place it is.
        #expect(!hits.contains { $0.name.contains("New Mexico") })
        #expect(hits.contains { $0.name == "Mexico Area" })
    }

    @Test("Searching New Mexico still finds New Mexico")
    func newMexicoStillWorks() {
        let newMexico = ServiceBody(id: 1, parentID: nil, name: "Southern New Mexico Area",
                                    description: nil, type: "AS", url: nil, helpline: "",
                                    worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([newMexico])
        #expect(tree.search("New Mexico").contains { $0.name.contains("New Mexico") })
    }

    /// Real bug: "United Kingdom" surfaced three unrelated US areas because the
    /// generic word "united" matched them.
    @Test("A generic opener needs the rest of the query to match")
    func genericOpenerNeedsRest() {
        let phoenix = ServiceBody(id: 1, parentID: nil, name: "Phoenix United Area",
                                  description: nil, type: "AS", url: nil, helpline: "",
                                  worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([phoenix])
        // "United Kingdom" names a place no service body covers.
        #expect(tree.search("United Kingdom").isEmpty)
        // A bare generic token with nothing after it is unaffected.
        #expect(!tree.search("United").isEmpty)
    }

    @Test("A contiguous phrase outranks scattered token matches")
    func searchPhrasePreference() {
        let sanDiego = ServiceBody(id: 2313, parentID: 1, name: "San Diego Imperial Counties Region", description: nil, type: "RS", url: nil, helpline: "",
                                   worldID: "RG590", rootServerID: 38)
        let sanJose = ServiceBody(id: 999, parentID: 1, name: "San Jose", description: nil, type: "AS", url: nil, helpline: "",
                                  worldID: nil, rootServerID: 1)
        let tree = ServiceBodyTree([sanJose, sanDiego])

        // Both contain "san"; only one contains "san diego".
        #expect(tree.search("san diego").first?.name == "San Diego Imperial Counties Region")
    }
}

/// Helpline parsing, pinned against the exact strings the live aggregator
/// returns. Every case here is a real service body field, not a hypothetical.
///
/// The regression this suite exists to prevent: `1300 652 820` (an Australian
/// local-rate number) used to render `(130) 065-2820`, a well-formed US number
/// that dials a stranger.
@Suite("Helpline parsing")
struct HelplineTests {

    private func parse(_ s: String) -> [Helpline] { Helpline.parse(s) }

    @Test("US 10-digit is NANP-formatted")
    func nanpTen() throws {
        let h = try #require(parse("6195841007").first)
        #expect(h.display == "(619) 584-1007")
        #expect(h.dialString == "6195841007")
        #expect(h.reachability == .nanp)
    }

    @Test("Parens and dashes are normalized away")
    func nanpFormatted() throws {
        let h = try #require(parse("(512) 480-0004").first)
        #expect(h.display == "(512) 480-0004")
        #expect(h.dialString == "5124800004")
    }

    @Test("Existing + is preserved and dialable")
    func e164Preserved() throws {
        // Australian Region id 490, verbatim from the server.
        let h = try #require(parse("+61488811247").first)
        #expect(h.dialString == "+61488811247")
        #expect(h.reachability == .international(countryCode: "61"))
        // The old code stripped the '+' and made this undialable abroad.
        #expect(h.dialString.hasPrefix("+"))
    }

    @Test("Three-digit country code 353 is split correctly")
    func threeDigitCountryCode() throws {
        // Ireland: +353, not +35.
        let h = try #require(parse("+353871386120").first)
        #expect(h.reachability == .international(countryCode: "353"))
    }

    @Test("Australian local-rate is NOT rendered as a US number")
    func australianLocalRateNotLiesAsUS() throws {
        // South / Western Australia ids 504, 507. This is the headline
        // regression: it previously displayed "(130) 065-2820".
        let h = try #require(parse("1300 652 820").first)
        #expect(h.display != "(130) 065-2820")
        #expect(h.display == "1300652820")
        #expect(h.reachability == .domesticOnly)
        #expect(h.reachability.notice != nil)
    }

    @Test("00 international prefix becomes +")
    func doubleZeroBecomesPlus() throws {
        // Southern Area of Ireland id 2418.
        let h = try #require(parse("00353871386120").first)
        #expect(h.dialString == "+353871386120")
        #expect(h.reachability == .international(countryCode: "353"))
    }

    @Test("988 is a shortcode, not a NANP number")
    func shortcodeIsDomestic() throws {
        let h = try #require(parse("988").first)
        #expect(h.reachability == .domesticOnly)
        #expect(h.display == "988")
        #expect(h.dialString == "988")
    }

    @Test("Multiple numbers in one field are split, not concatenated")
    func splitMultipleNumbers() throws {
        // Northeast Washington Area, verbatim: three numbers in one field.
        // Previously concatenated into one 30-digit unmatchable string.
        let got = parse("509-325-5045, 208-746-7632, 208-883-5006")
        #expect(got.count == 3)
        #expect(got.map(\.dialString) == ["5093255045", "2087467632", "2088835006"])
    }

    @Test("Two numbers joined by the word 'or' are split")
    func splitOnWordOr() throws {
        // Verified live: "352-553-2396 or 877-782-7657". The word 'or' is not a
        // punctuation separator, so separator-splitting alone concatenated these
        // into one unmatchable 20-digit string.
        let got = parse("352-553-2396 or 877-782-7657")
        #expect(got.map(\.dialString) == ["3525532396", "8777827657"])
    }

    @Test("A number followed by a place name keeps only the number")
    func splitOnTrailingPlaceName() throws {
        // Verified live: "(800)-733-8855 OREGON or (530) 842-7502 CALIFORNIA".
        let got = parse("(800)-733-8855 OREGON or (530) 842-7502 CALIFORNIA")
        #expect(got.map(\.dialString) == ["8007338855", "5308427502"])
    }

    @Test("A vanity stub run is dropped, the real number kept")
    func vanityStubDropped() throws {
        // Verified live: "1-855-LIGNENA 1-855-544-6362". The first half is a
        // vanity stub whose letters cannot be mapped back reliably; it yields
        // the 4-digit fragment 1855. Only the dialable number survives.
        let got = parse("1-855-LIGNENA 1-855-544-6362")
        #expect(!got.contains { $0.dialString == "1855" })
        #expect(got.contains { $0.dialString == "+18555446362" })
    }

    @Test("A slash with surrounding words still splits")
    func slashWithWords() throws {
        // Verified live: "(888) 322-6817 / Bilingual (818) 427-4212".
        let got = parse("(888) 322-6817  /  Bilingual (818) 427-4212")
        #expect(got.map(\.dialString) == ["8883226817", "8184274212"])
    }

    @Test("Vanity numbers keep their digits rather than being mangled")
    func vanityNumber() throws {
        // "1-844-530-HOPE" -> digits only. Not guessed at: the letters-to-digits
        // mapping is ambiguous, so the raw digits are reported.
        let h = try #require(parse("1-844-530-HOPE").first)
        #expect(h.dialString == "1844530")
        #expect(h.reachability == .domesticOnly)
    }

    @Test("A vanity code that yields only a fragment is dropped")
    func vanityFragmentDropped() {
        // "1-800-GET-HOPE" leaves the 4-digit stub 1800, which is not a number
        // anyone can dial. Better to show nothing than a dead line.
        #expect(parse("1-800-GET-HOPE").isEmpty)
    }

    @Test("Trailing junk does not corrupt the number")
    func trailingJunk() throws {
        // Martha's Vineyard Area: "866-686-2669|wwww1".
        let got = parse("866-686-2669|wwww1")
        #expect(got.first?.dialString == "8666862669")
    }

    @Test("Placeholder zeros are rejected")
    func rejectsZeros() {
        #expect(parse("0000000000").isEmpty)
        #expect(parse("1111111111").isEmpty)
    }

    @Test("Empty and non-numeric fields yield nothing")
    func rejectsJunk() {
        #expect(parse("").isEmpty)
        #expect(parse("   ").isEmpty)
        #expect(parse("n/a").isEmpty)
    }

    @Test("1+10 digits is treated as NANP with an explicit +1")
    func elevenDigitNANP() throws {
        let h = try #require(parse("1-800-555-0199").first)
        #expect(h.dialString == "+18005550199")
        #expect(h.reachability == .international(countryCode: "1"))
    }

    @Test("ServiceBody exposes only reachable numbers")
    func bodyIntegration() {
        let none = ServiceBody(id: 1, parentID: nil, name: "N", description: nil, type: "AS",
                               url: nil, helpline: "0000000000", worldID: nil, rootServerID: 1)
        #expect(none.primaryHelpline == nil)
        #expect(none.helplineDisplay == nil)

        let au = ServiceBody(id: 490, parentID: nil, name: "Australian Region", description: nil,
                             type: "RS", url: nil, helpline: "+61488811247",
                             worldID: nil, rootServerID: 1)
        #expect(au.helplineDigits == "+61488811247")
    }
}
