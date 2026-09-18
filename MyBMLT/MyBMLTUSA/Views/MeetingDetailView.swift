import SwiftUI
import UIKit

/// Full meeting detail. Reached from every tab via `Route.meetingDetail`.
///
/// ## Why `UserLists` is optional here
/// `@Environment(UserLists.self) private var lists: UserLists` **traps** when the
/// value is absent — verified by rendering this view in a test host without the
/// composition root:
///
/// ```
/// Fatal error: No Observable object of type UserLists found.
/// A View.environmentObject(_:) for UserLists may be missing as an ancestor.
/// ```
///
/// That is a hard crash with no compile-time warning, and it also makes the view
/// unrenderable in a preview. Declaring the property as `UserLists?` selects a
/// *different* `Environment` initialiser (`init<T>(_ objectType:) where
/// Value == T?`, verified in the SwiftUICore interface), which returns `nil`
/// instead of trapping. The same mistake then becomes a visible, harmless
/// degradation: list controls and the change/deletion banners hide, and
/// everything else renders. The composition root still injects the value, so
/// normal operation is unchanged.
struct MeetingDetailView: View {
    let meeting: Meeting

    @Environment(UserLists.self) private var lists: UserLists?
    /// Optional for the same reason as `lists`: a non-optional `@Observable`
    /// environment lookup traps when the value is absent, which would make this
    /// view unrenderable in a preview. Absent, format labels fall back to the
    /// bundled table — see `formatLabels`.
    @Environment(MeetingStore.self) private var meetings: MeetingStore?
    @Environment(\.openURL) private var openURL

    @State private var copied = false
    @State private var showingFormatCodes = false

    /// Live format labels for the active root server, or empty when no store is
    /// in the environment (a preview or a bare test host). Empty is a safe
    /// degradation: `FormatLabels` then falls through to the bundled table and
    /// finally to the raw code.
    private var formatLabels: [String: String] { meetings?.formatLabels ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                changeBanner
                titleBlock
                Divider()
                scheduleBlock
                Divider()

                if meeting.hasPhysicalVenue {
                    locationBlock
                    Divider()
                }

                if meeting.isVirtualOrHybrid {
                    onlineBlock
                    Divider()
                }

                if !meeting.formats.isEmpty {
                    formatsBlock
                    Divider()
                }

                exportBlock
            }
            .padding()
        }
        .navigationTitle(meeting.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Hidden when the lists environment is absent: a Menu whose only
            // actions need `lists` would be a dead control.
            if let lists {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            lists.favorites.toggle(meeting)
                        } label: {
                            Label(lists.favorites.contains(meeting)
                                  ? "Remove from Favorites" : "Add to Favorites",
                                  systemImage: lists.favorites.contains(meeting)
                                  ? "star.slash" : "star")
                        }

                        Button {
                            lists.explore.toggle(meeting)
                        } label: {
                            Label(lists.explore.contains(meeting)
                                  ? "Remove from Explore" : "Add to Explore",
                                  systemImage: "binoculars")
                        }
                    } label: {
                        Label("Lists", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("Lists")
                }
            }
        }
    }

    // MARK: - Change banner

    /// Unacknowledged behavioural changes, read from the list stores rather
    /// than from the passed-in `meeting`.
    ///
    /// This matters: the banner is only meaningful for a *saved* meeting, and
    /// only the stores know whether this meeting is saved and whether a newer
    /// record has landed since. The `meeting` parameter may be an older
    /// snapshot — `MeetingsView` resolves it from `store.meetings`,
    /// `MeetingSetTabView` from `store.records` — so the notice is derived from
    /// `lists` alone and shows only for favourited/explore meetings.
    private var pendingChanges: [Meeting.Change] {
        lists?.pendingChanges(for: meeting) ?? []
    }

    /// Shown when the server has stopped returning a saved meeting.
    ///
    /// ## Why the wording is literal, not plain-language
    /// A deleted BMLT meeting is not flagged `published = 0`; the aggregator
    /// filters unpublished rows server-side, so the meeting simply disappears
    /// from responses. Verified: 377 SDICR rows and 922 geo rows, every one
    /// `published = "1"`. Absence is therefore the only signal, and it cannot by
    /// itself distinguish deletion from a server hiccup or a wrong query.
    ///
    /// So the copy states the observation and stops: **"no longer listed by the
    /// meeting server"**. It deliberately does *not* say "deleted", even though
    /// that reads better, because absence is not deletion. Slightly less direct,
    /// and it cannot be wrong.
    ///
    /// The claim is still corroborated — two consecutive clean fetches
    /// (`MeetingSetStore.missingConfirmationsRequired`), never a partial or
    /// failed one, and never for a whole large batch at once. The banner then
    /// gives a "first noticed" date rather than a deletion date, because BMLT
    /// exposes no edit timestamp (verified: `GetFieldKeys` has no
    /// publish/status/delete field at all).
    @ViewBuilder
    private var missingBanner: some View {
        if lists?.isMissing(meeting) == true {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 6) {
                    Text("This meeting is no longer listed by the meeting server")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    // The headline already states the fact, so this line carries
                    // only what the user should do about it: the saved details
                    // are a snapshot and may not match reality any more.
                    Text("The details below are the last ones saved and may be out of date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let noticed = lists?.missingFirstNoticed(meeting) {
                        Text("First noticed \(noticed.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            // Red, not the orange used for "details changed": this one is gone
            // from the source of truth, which is a different claim.
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.red.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private var changeBanner: some View {
        if !pendingChanges.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("This meeting changed since you saved it")
                        .font(.subheadline.weight(.semibold))

                    ForEach(pendingChanges, id: \.self) { change in
                        Label(change.title, systemImage: change.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Got it") {
                        lists?.acknowledgeChanges(for: meeting)
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            // Orange, not red: this is "check before you go", not "broken".
            // Matches the existing orange already used in this file for the
            // cross-time-zone notice and the password capsule.
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.35))
            }
        }
    }

    // MARK: - Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.name)
                .font(.title2.weight(.bold))

            HStack(spacing: 8) {
                VenueBadge(venueType: meeting.venueType)
                if meeting.isWheelchairAccessible {
                    Label("Wheelchair accessible", systemImage: "figure.roll")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            if !meeting.serviceBodyName.isEmpty {
                Text(meeting.serviceBodyName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Schedule", systemImage: "calendar")
                .font(.headline)

            Text("\(meeting.weekdayName) at \(meeting.formattedTime)")
                .font(.subheadline)

            Text("Runs \(meeting.formattedDuration)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Meetings carry their own time zone on the aggregator; without
            // this label a cross-country meeting's time reads as local.
            if meeting.isInDifferentZoneThanDevice {
                Label("Times shown in \(meeting.timeZone.identifier)",
                      systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let next = meeting.nextOccurrence() {
                Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var locationBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location", systemImage: "mappin.circle")
                .font(.headline)

            if !meeting.locationName.isEmpty {
                Text(meeting.locationName)
                    .font(.subheadline)
            }
            if !meeting.addressLine.isEmpty {
                Text(meeting.addressLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !meeting.locationInfo.isEmpty {
                Text(meeting.locationInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if meeting.hasPhysicalVenue,
               meeting.latitude != nil, meeting.longitude != nil {
                Button {
                    MeetingActions.openInMaps(meeting)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var onlineBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Online Meeting", systemImage: "video.circle")
                .font(.headline)

            if let target = meeting.joinTarget {
                Button {
                    MeetingActions.openJoinTarget(meeting)
                } label: {
                    Label(target.label, systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if let link = meeting.shareableLink {
                Text(link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let password = meeting.passwordValue {
                HStack(spacing: 8) {
                    Label("Password", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text(password)
                        .font(.subheadline.monospaced().weight(.medium))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
            } else {
                Text("No password listed for this meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formatsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Formats", systemImage: "list.bullet")
                    .font(.headline)
                Spacer()
                Button(showingFormatCodes ? "Names" : "Codes") {
                    showingFormatCodes.toggle()
                }
                .font(.caption)
            }

            FlowLayout(items: meeting.formats.map { code in
                showingFormatCodes ? code : FormatLabels.resolve(code, server: formatLabels)
            })
        }
    }

    private var exportBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                UIPasteboard.general.string = MeetingTextExport.plainText(
                    for: [meeting], serverLabels: formatLabels)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied!" : "Copy Meeting Details",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if let url = meeting.joinTarget?.url, meeting.isVirtualOrHybrid {
                ShareLink(item: url) {
                    Label("Share Join Link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Simple wrapping chip layout for format tags.
struct FlowLayout: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }
}

#if DEBUG

// MARK: - Previews

/// Previews for the shapes a meeting can take, plus the two banner states.
///
/// These render with the environment injected explicitly, which is also the
/// regression guard for the trap described on `MeetingDetailView`: a
/// non-optional `@Environment(UserLists.self)` crashes here rather than failing
/// to build.
#Preview("In person") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.inPerson)
    }
    .environment(PreviewData.lists(favorite: PreviewData.inPerson))
}

#Preview("Virtual, with password") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.virtual)
    }
    .environment(PreviewData.lists())
}

#Preview("Hybrid") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.hybrid)
    }
    .environment(PreviewData.lists(exploring: PreviewData.hybrid))
}

#Preview("Different time zone") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.otherZone)
    }
    .environment(PreviewData.lists())
}

#Preview("Details changed since saving") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.inPerson)
    }
    .environment(PreviewData.lists(changed: PreviewData.inPerson))
}

#Preview("No longer listed by the server") {
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.inPerson)
    }
    .environment(PreviewData.lists(missing: PreviewData.inPerson))
}

#Preview("No lists environment") {
    // The degradation path: banners and the Lists menu are absent, everything
    // else renders. Before the optional `@Environment`, this preview crashed.
    NavigationStack {
        MeetingDetailView(meeting: PreviewData.inPerson)
    }
}
#endif
