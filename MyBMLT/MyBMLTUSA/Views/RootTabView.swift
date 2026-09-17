import SwiftUI

/// The four shipping tabs.
///
/// "New Meetings" is not a tab — it is a badge plus a section on the Meetings
/// tab, because a badge whose number depends on which Area you last viewed is a
/// number nobody can act on, and with radius queries there is no stable
/// snapshot to diff against.
///
/// Two tabs have been removed:
///
/// - **Near Me** fetched a radius around the user and filtered in place, so the
///   visible count barely responded to the radius control, and ~24% of hours
///   returned nothing. `AreaPickerView`'s "Use My Location" covers the need.
/// - **My Network** was a personal contact list. It duplicated what iOS Contacts
///   already does, **could not be backed up** (remote sync is deliberately not
///   implemented), and was the largest privacy liability in the app. Most of its
///   value is recoverable as an export to the system contacts database, which is
///   a better home for the data: it survives a lost phone.
enum RootTab: Hashable, CaseIterable {
    case meetings, favorites, support, explore

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .favorites: return "Favorites"
        case .support: return "Support"
        case .explore: return "Explore"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: return "list.bullet"
        case .favorites: return "star.fill"
        case .support: return "lifepreserver"
        case .explore: return "binoculars"
        }
    }
}

/// A destination reachable from any tab, so meeting detail is pushed from one
/// shared place rather than duplicated per tab.
enum Route: Hashable {
    case meetingDetail(String)          // Meeting.uid
    case areaPicker
    case areaManage
}

struct RootTabView: View {
    @State private var selection: RootTab = .meetings

    @Environment(UserLists.self) private var lists

    var body: some View {
        TabView(selection: $selection) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                tabContent(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
                    .badge(badge(for: tab))
            }
        }
    }

    /// Badge count for a tab.
    ///
    /// Only the two list tabs can carry a notice. The count combines field
    /// changes with confirmed-missing meetings, because both are things the
    /// user has to act on before travelling; a deleted meeting counts once even
    /// if its cached details also moved.
    private func badge(for tab: RootTab) -> Int {
        switch tab {
        case .favorites: return count(for: lists.favorites)
        case .explore: return count(for: lists.explore)
        case .meetings, .support: return 0
        }
    }

    private func count(for store: MeetingSetStore) -> Int {
        let missing = store.confirmedMissingUIDs
        // Exclude missing meetings from the change tally so the two categories
        // do not double-count the same meeting.
        let changes = store.unseenChangeCountExcluding(missing)
        return missing.count + changes
    }

    @ViewBuilder
    private func tabContent(_ tab: RootTab) -> some View {
        switch tab {
        case .meetings:
            MeetingsView()
        case .favorites:
            FavoritesView()
        case .support:
            SupportView()
        case .explore:
            ExploreView()
        }
    }
}
