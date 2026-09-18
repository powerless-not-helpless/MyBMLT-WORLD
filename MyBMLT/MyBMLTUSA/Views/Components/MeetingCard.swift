import SwiftUI
import UIKit
import MapKit

/// The one meeting card used by every tab.
///
/// Consolidating this fixes a real defect in the pre-rewrite code, where
/// `openInMaps` and the venue-badge colours were copy-pasted into three
/// different files and had already drifted apart.
struct MeetingCard: View {
    let meeting: Meeting
    /// Time-until-start label. Supplied by callers that know the meeting's
    /// schedule relative to now; nil elsewhere.
    var timeLabel: String?
    var isInProgress: Bool = false

    @Environment(UserLists.self) private var lists: UserLists?

    /// Brief confirmation that the copy landed. Reset by a timed task.
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            locationAndAddress

            if meeting.isVirtualOrHybrid {
                virtualSection
            }

            actionRow
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isInProgress ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(meeting.weekdayName) \(meeting.formattedTime)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // A meeting in another zone shows a time the user will
                // otherwise misread against their own clock.
                if meeting.isInDifferentZoneThanDevice {
                    Text(meeting.timeZone.abbreviation() ?? meeting.timeZoneID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let timeLabel {
                    Text(timeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(timeLabelColor)
                }
                VenueBadge(venueType: meeting.venueType)
            }
        }
    }

    private var timeLabelColor: Color {
        if isInProgress { return .orange }
        return .secondary
    }

    // MARK: - Location

    @ViewBuilder
    private var locationAndAddress: some View {
        if meeting.hasPhysicalVenue {
            VStack(alignment: .leading, spacing: 2) {
                if !meeting.locationName.isEmpty {
                    Text(meeting.locationName)
                        .font(.subheadline)
                }
                if !meeting.addressLine.isEmpty {
                    Text(meeting.addressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Virtual

    private var virtualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = meeting.joinTarget {
                Link(destination: target.url) {
                    Label(target.label, systemImage: "video.fill")
                        .font(.subheadline)
                }
                .accessibilityLabel("\(target.label) for \(meeting.name)")
            } else {
                Label("Online meeting — no link listed", systemImage: "video.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Zoom password, on the card. Required by the brief, and the single
            // most common reason a user cannot get into a meeting.
            if let password = meeting.passwordValue {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                    Text("Password: \(password)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .foregroundStyle(.orange)
                .accessibilityLabel("Meeting password \(password)")
            }
        }
    }

    // MARK: - Actions

    /// Whether this meeting is a favourite, or `false` when the lists
    /// environment is absent. Kept as small computed properties so the optional
    /// is unwrapped in one place per control rather than inline in `body`.
    private var isFavorite: Bool {
        lists?.favorites.contains(meeting) ?? false
    }

    private var isExploring: Bool {
        lists?.explore.contains(meeting) ?? false
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            // 1. Map — icon only. The label was removed to keep the row short;
            // a map pin is unambiguous without the word.
            // Only for meetings with a real venue: a virtual-only meeting has
            // nowhere to go, even when the server still sends coordinates.
            if meeting.hasPhysicalVenue,
               meeting.latitude != nil, meeting.longitude != nil {
                Button {
                    MeetingActions.openInMaps(meeting)
                } label: {
                    Image(systemName: "map")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel("Show \(meeting.name) on the map")
            }

            // 2. Star → Favorite. Icon only, to match the map pin. The word was
            // dropped from the card face; the action is still announced to
            // VoiceOver. Falls back to the hollow star and no action when the
            // lists environment is absent, so the card still renders in a
            // preview or a bare test host instead of trapping.
            Button {
                lists?.favorites.toggle(meeting)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? .yellow : .secondary)
            .disabled(lists == nil)
            .accessibilityLabel(isFavorite
                                ? "Remove from Favorites"
                                : "Add to Favorites")

            // 3. Telescope → Explore.
            Button {
                lists?.explore.toggle(meeting)
            } label: {
                Label("Explore",
                      systemImage: isExploring ? "binoculars.fill" : "binoculars")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isExploring ? .purple : .secondary)
            .disabled(lists == nil)
            .accessibilityLabel("Add to Explore List")

            // 3. Copy the meeting's details, including join credentials.
            Button {
                UIPasteboard.general.string = MeetingTextExport.plainText(for: meeting)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopy ? .green : .secondary)
            .accessibilityLabel("Copy meeting details")

            Spacer()

            // Shown only when the server supplied a distance, which it does for
            // `geo_width` queries and not for ordinary area browsing. The unit
            // follows the device locale — miles or kilometres — because the
            // server sends both figures.
            if let distance = meeting.formattedDistance {
                Text(distance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Badge

struct VenueBadge: View {
    let venueType: Int

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch venueType {
        case 1: return "In-Person"
        case 2: return "Virtual"
        case 3: return "Hybrid"
        default: return "Unknown"
        }
    }

    private var color: Color {
        switch venueType {
        case 1: return .green
        case 2: return .blue
        case 3: return .orange
        default: return .secondary
        }
    }
}

enum MeetingActions {

    /// Apple Maps is the correct and only platform choice on iOS.
    static func openInMaps(_ meeting: Meeting) {
        guard let url = mapsURL(for: meeting) else { return }
        UIApplication.shared.open(url)
    }

    /// Whether the meeting has a location worth offering on a map.
    ///
    /// This is the single guard behind the "Open in Maps" button: it decides
    /// both whether the button appears and whether opening anything is
    /// attempted. Kept as a pure function of the meeting so it can be tested
    /// without a UI host.
    static func canOpenInMaps(_ meeting: Meeting) -> Bool {
        mapsURL(for: meeting) != nil
    }

    /// The Apple Maps URL for a meeting, or nil when it has no usable location.
    ///
    /// Rejects `0,0` ("null island"): meetings with no real location sometimes
    /// serialize as `0.0` rather than absent, and a pin in the Gulf of Guinea is
    /// worse than no button. Also rejects non-finite and out-of-range values.
    private static func mapsURL(for meeting: Meeting) -> URL? {
        guard let lat = meeting.latitude, let lon = meeting.longitude,
              lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon),
              !(lat == 0 && lon == 0)
        else { return nil }

        let name = meeting.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "maps://?q=\(name)&ll=\(lat),\(lon)"
        return URL(string: urlString)
    }

    /// Opens a Zoom deep link, falling back to the web URL when the app is not
    /// installed. The completion handler is what makes the fallback reliable.
    static func openJoinTarget(_ meeting: Meeting) {
        guard let target = meeting.joinTarget else { return }

        if target.url.scheme == "zoommtg" {
            UIApplication.shared.open(target.url, options: [:]) { success in
                guard !success, let web = meeting.virtualLink,
                      let webURL = URL(string: web.replacingOccurrences(of: " ", with: ""))
                else { return }
                UIApplication.shared.open(webURL)
            }
            return
        }
        UIApplication.shared.open(target.url)
    }
}

#if DEBUG

// MARK: - Previews

#Preview("Card shapes") {
    List {
        MeetingCard(meeting: PreviewData.inPerson)
        MeetingCard(meeting: PreviewData.virtual)
        MeetingCard(meeting: PreviewData.hybrid)
        MeetingCard(meeting: PreviewData.otherZone, timeLabel: "in 2 hours")
    }
    .listStyle(.plain)
    .environment(PreviewData.lists(favorite: PreviewData.inPerson,
                                   exploring: PreviewData.hybrid))
}

#Preview("No lists environment") {
    // Renders with hollow stars and disabled list buttons rather than trapping.
    List {
        MeetingCard(meeting: PreviewData.inPerson)
        MeetingCard(meeting: PreviewData.virtual)
    }
    .listStyle(.plain)
}
#endif
