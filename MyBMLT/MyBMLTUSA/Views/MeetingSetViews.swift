import SwiftUI

/// A tab backed by a `MeetingSetStore` (Favorites or Explore).
///
/// One view type serves both, because they differ only in copy and empty-state
/// iconography. Two near-identical views would be the duplication the
/// pre-rewrite code already suffered from.
struct MeetingSetTabView: View {
    let title: String
    let emptyTitle: String
    let emptyMessage: String
    let emptyIcon: String
    let store: MeetingSetStore
    /// Copy All is only meaningful for the Explore list (a visit plan).
    var allowsCopyAll: Bool = false

    @Environment(MeetingStore.self) private var meetings
    @Environment(UserLists.self) private var lists

    @State private var path = NavigationPath()
    @State private var copied = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.all.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: Route.self) { route in
                if case .meetingDetail(let uid) = route,
                   let meeting = store.records[uid] {
                    MeetingDetailView(meeting: meeting)
                }
            }
            // Heals saved meetings the active Area's list does not contain.
            // Gated by the store TTL, so repeated tab visits do not re-query;
            // pull-to-refresh below bypasses the gate deliberately.
            .task {
                await lists.verifyOutOfAreaFavorites(knownMeetings: meetings.meetings)
            }
            .refreshable {
                await refresh()
            }
        }
    }

    /// Force a scoped re-fetch, ignoring the TTL.
    ///
    /// For the case the TTL is specifically bad at: a user who knows a meeting
    /// moved and does not want to wait out the window.
    private func refresh() async {
        let known = Set(meetings.meetings.map(\.uid))
        guard let byRoot = store.unverifiedIDs(notIn: known) else {
            // Nothing out of Area; the Meetings fetch already covers everything.
            store.markVerified()
            return
        }
        await FavoriteVerifier.verify(byRoot: byRoot, store: store)
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(store.all) { meeting in
                    NavigationLink(value: Route.meetingDetail(meeting.uid)) {
                        HStack(spacing: 8) {
                            MeetingCard(meeting: meeting)

                            // A row-level dot so a changed or deleted meeting
                            // is findable by scrolling. Deleted wins, because
                            // it is the stronger claim and a meeting that no
                            // longer exists cannot also be "updated".
                            if store.isMissing(meeting) {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("No longer listed by the meeting server")
                            } else if !store.pendingChanges(for: meeting.uid).isEmpty {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Details changed since you saved this")
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.toggle(meeting)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } header: {
                MeetingCountHeader(store.count)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyMessage)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if allowsCopyAll && !store.all.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = MeetingTextExport.plainText(
                        for: store.all, serverLabels: meetings.formatLabels)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy All",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }
}

/// Favorites tab.
struct FavoritesView: View {
    @Environment(UserLists.self) private var lists

    var body: some View {
        MeetingSetTabView(
            title: "Favorites",
            emptyTitle: "No Favorites Yet",
            emptyMessage: "Tap the star on any meeting to add it here.",
            emptyIcon: "star",
            store: lists.favorites
        )
    }
}

/// Explore tab: meetings the user wants to visit but has not starred.
struct ExploreView: View {
    @Environment(UserLists.self) private var lists

    var body: some View {
        MeetingSetTabView(
            title: "Explore",
            emptyTitle: "Nothing to Explore Yet",
            emptyMessage: "Tap the binoculars on a meeting you'd like to visit.",
            emptyIcon: "binoculars",
            store: lists.explore,
            allowsCopyAll: true
        )
    }
}

/// Clipboard export for a list of meetings, carried over from the pre-rewrite
/// `VisitListService.copyText(from:)` which already handled address, link, and
/// password correctly.
/// "67 meetings", or "12 of 67 meetings" when a filter is narrowing the list.
///
/// Shared so every list header counts the same way. `MeetingsView` uses it
/// directly via its own `countLabel`; the other tabs use this view.
struct MeetingCountHeader: View {
    let filtered: Int
    let total: Int?

    init(_ count: Int, of total: Int? = nil) {
        self.filtered = count
        self.total = total
    }

    var body: some View {
        // `.primary` rather than `.secondary`: primary resolves to near-black in
        // light mode and near-white in dark mode automatically, which is the
        // contrast this header needs. Secondary is a dimmed grey in both, which
        // reads as de-emphasised and was hard to see against the list background.
        Text(label)
            .font(.caption)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var label: String {
        let noun = (total ?? filtered) == 1 ? "meeting" : "meetings"
        guard let total, filtered != total else { return "\(filtered) \(noun)" }
        return "\(filtered) of \(total) \(noun)"
    }
}

/// Clipboard export for a meeting, shared by the card, the detail screen and the
/// Explore tab's Copy All.
///
/// `nonisolated`: pure string formatting over value types, called from the
/// card's nonisolated context as well as from views.
nonisolated enum MeetingTextExport {

    /// Human-readable format names for a meeting's format codes.
    ///
    /// `serverLabels` is `MeetingStore.formatLabels` — the live map for the
    /// active root server. It is passed in rather than read from the
    /// environment so this stays a pure function, and it is required rather than
    /// defaulted so a caller cannot silently fall back to the bundled SDICR
    /// table, which is only correct inside that region. See `FormatLabels` for
    /// the resolution order.
    static func formatNames(for meeting: Meeting, serverLabels: [String: String]) -> [String] {
        FormatLabels.resolve(meeting.formats, server: serverLabels)
    }

    /// The copyable text for one meeting.
    ///
    /// Kept short on purpose. The earlier version added duration, venue type,
    /// time zone and service body, which made a message-length paste where the
    /// recipient needed six facts. What survives is what someone actually needs
    /// to attend: when, where, how to get in, and what kind of meeting it is.
    static func plainText(for meeting: Meeting, serverLabels: [String: String]) -> String {
        var lines: [String] = []

        lines.append("\(meeting.weekdayName) at \(meeting.formattedTime)")
        lines.append(meeting.name)

        if !meeting.formattedDuration.isEmpty {
            lines.append(meeting.formattedDuration)
        }

        if meeting.hasPhysicalVenue {
            let address = meeting.addressLine
            if !address.isEmpty { lines.append(address) }
        }

        if meeting.isVirtualOrHybrid {
            if let link = meeting.shareableLink { lines.append(link) }
            if let password = meeting.passwordValue { lines.append("Password: \(password)") }
        }

        let names = formatNames(for: meeting, serverLabels: serverLabels)
        if !names.isEmpty {
            lines.append(names.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    static func plainText(for meetings: [Meeting], serverLabels: [String: String]) -> String {
        meetings.map { plainText(for: $0, serverLabels: serverLabels) }
            .joined(separator: "\n\n")
    }
}
