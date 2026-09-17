import SwiftUI

@main
struct MyBMLTUSAApp: App {

    /// Composition root. Stores are created once and injected through the
    /// environment; views never construct their own.
    @State private var areas: AreaStore
    @State private var meetings: MeetingStore
    @State private var lists: UserLists
    @State private var location: LocationService

    init() {
        _areas = State(initialValue: AreaStore())
        _meetings = State(initialValue: MeetingStore())
        _lists = State(initialValue: UserLists())
        _location = State(initialValue: LocationService())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(areas)
                .environment(meetings)
                .environment(lists)
                .environment(location)
                .task {
                    await areas.loadServiceBodies()
                    await bootstrap()
                }
                // Fires after any successful Meetings fetch, including the
                // pull-to-refresh in `MeetingsView`. `bootstrap` only runs once,
                // so without this a mid-session refresh would never heal a
                // favourite.
                .onChange(of: meetings.lastUpdated) { _, _ in
                    refreshUserLists()
                }
        }
    }

    /// First-launch work: load the active Area's meetings and run the one-time
    /// migration of pre-`uid` favourites.
    private func bootstrap() async {
        guard let active = areas.active else { return }

        await meetings.load(for: active)
        refreshUserLists()
        migrateLegacySelections()
    }

    /// Heals saved favourite/explore details from data `MeetingStore` already
    /// fetched for the Meetings tab.
    ///
    /// No network call: `meetings.meetings` is in memory, so this is one
    /// dictionary pass over records we have already paid for. That is what
    /// makes it safe to run on every fetch instead of on a TTL — it costs
    /// nothing, so throttling is unnecessary.
    ///
    /// Guarded on `!isFromCache` so a disk-painted list cannot "change" a
    /// favourite into something less current than what the favourite already
    /// holds. Only a real server response may overwrite a saved record.
    private func refreshUserLists() {
        guard !meetings.isFromCache, !meetings.meetings.isEmpty else { return }
        lists.update(from: meetings.meetings)
    }

    private func migrateLegacySelections() {
        guard lists.hasPendingMigration else { return }

        let fresh = meetings.meetings
        guard !fresh.isEmpty else { return }

        let legacy = meetings.loadLegacyMeetings()
        lists.migrate(legacyMeetings: legacy, against: fresh)
        meetings.removeLegacyCache()
    }
}
