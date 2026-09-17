import SwiftUI

/// The Meetings tab: the active Area's meetings, searchable and filterable.
///
/// Shows a `MeetingSetStore`-cached card list immediately from disk, then
/// revalidates. The first screen never waits on the network and never requires
/// location permission.
struct MeetingsView: View {
    @Environment(AreaStore.self) private var areas
    @Environment(MeetingStore.self) private var store

    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var venueFilter: Int = -1
    @State private var dayFilter: Int = -1
    @State private var showAreaPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if areas.active == nil {
                    noAreaState
                } else if store.meetings.isEmpty, store.isLoading {
                    ProgressView("Loading meetings…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.error, store.meetings.isEmpty {
                    offlineEmptyState(error)
                } else {
                    listContent
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Name, city, street, or ZIP")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .meetingDetail(let uid):
                    if let meeting = store.meetings.first(where: { $0.uid == uid }) {
                        MeetingDetailView(meeting: meeting)
                    } else {
                        ContentUnavailableView("Meeting unavailable",
                                               systemImage: "questionmark.circle")
                    }
                case .areaPicker, .areaManage:
                    AreaPickerView()
                }
            }
            .sheet(isPresented: $showAreaPicker) {
                AreaPickerView()
            }
            .task(id: areas.active?.serviceBodyUID) {
                guard let active = areas.active else { return }
                await store.load(for: active)
            }
            .refreshable {
                guard let active = areas.active else { return }
                await store.refresh(selection: active)
            }
        }
    }

    // MARK: - Content

    private var listContent: some View {
        List {
            if store.isFromCache, let updated = store.lastUpdated {
                Section {
                    Label("Showing saved meetings from \(updated.formatted(.relative(presentation: .named)))",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(filtered) { meeting in
                    NavigationLink(value: Route.meetingDetail(meeting.uid)) {
                        MeetingCard(meeting: meeting)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            } header: {
                // Shown above the list, not below it. When a filter is active the
                // "of" clause tells the user how much is hidden from them.
                MeetingCountHeader(filtered.count, of: store.meetings.count)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Filtering

    private var filtered: [Meeting] {
        store.meetings.filter { meeting in
            let matchesVenue = venueFilter == -1 || meeting.venueType == venueFilter
            let matchesDay = dayFilter == -1 || meeting.weekday == dayFilter
            guard matchesVenue && matchesDay else { return false }
            guard !searchText.isEmpty else { return true }
            let q = searchText.lowercased()
            return meeting.name.lowercased().contains(q)
                || meeting.city.lowercased().contains(q)
                || meeting.street.lowercased().contains(q)
                || meeting.zip.lowercased().contains(q)
        }
        .sorted {
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            return $0.startTime < $1.startTime
        }
    }

    private var title: String {
        guard let active = areas.active else { return "Meetings" }
        return active.displayName
    }

    // MARK: - Empty states

    private var noAreaState: some View {
        ContentUnavailableView {
            Label("Choose where you are", systemImage: "mappin.and.ellipse")
        } description: {
            Text("Find meetings near you, or search by city, address, or ZIP code.")
        } actions: {
            Button("Set My Area") { showAreaPicker = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func offlineEmptyState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't reach the meeting server", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                guard let active = areas.active else { return }
                Task { await store.refresh(selection: active) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showAreaPicker = true
            } label: {
                Label("Change Area", systemImage: "mappin.circle")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Venue", selection: $venueFilter) {
                    Text("All Types").tag(-1)
                    Text("In-Person").tag(1)
                    Text("Virtual").tag(2)
                    Text("Hybrid").tag(3)
                }
                Picker("Day", selection: $dayFilter) {
                    Text("Any Day").tag(-1)
                    ForEach(1...7, id: \.self) { day in
                        Text(weekdayName(day)).tag(day)
                    }
                }
                if venueFilter != -1 || dayFilter != -1 {
                    Divider()
                    Button("Clear Filters", role: .destructive) {
                        venueFilter = -1
                        dayFilter = -1
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func weekdayName(_ day: Int) -> String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard day >= 1 && day <= 7 else { return "?" }
        return days[day - 1]
    }
}
