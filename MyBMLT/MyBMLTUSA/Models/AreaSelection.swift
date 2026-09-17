import Foundation

/// A user-chosen Area, persisted across launches.
///
/// The app supports **many** selections and one active at a time. This is the
/// structural answer to "must not assume a single home Area" — a user who
/// relocates adds a new Area rather than replacing the one they had.
nonisolated struct AreaSelection: Codable, Hashable, Identifiable {

    /// `ServiceBody.uid` — carries the root server, so the same region
    /// resolved against different servers stays distinct.
    let serviceBodyUID: String

    let serviceBodyID: Int
    let rootServerID: Int
    let displayName: String

    let discovery: Discovery

    /// When the user last had this Area active; used to order the list.
    var lastUsed: Date

    var id: String { serviceBodyUID }

    enum Discovery: String, Codable {
        case locationSuggestion
        case search
        case manual
        case bundledDefault
    }

    init(body: ServiceBody, discovery: Discovery, lastUsed: Date = Date()) {
        self.serviceBodyUID = body.uid
        self.serviceBodyID = body.id
        self.rootServerID = body.rootServerID
        self.displayName = body.name
        self.discovery = discovery
        self.lastUsed = lastUsed
    }
}

/// Everything the user has told us about where they are interested in.
nonisolated struct AreaState: Codable {
    var selections: [AreaSelection] = []
    var activeUID: String?

    var active: AreaSelection? {
        guard let uid = activeUID else { return nil }
        return selections.first { $0.serviceBodyUID == uid }
    }

    mutating func add(_ selection: AreaSelection, makeActive: Bool) {
        if let idx = selections.firstIndex(where: { $0.serviceBodyUID == selection.serviceBodyUID }) {
            selections[idx].lastUsed = Date()
        } else {
            selections.append(selection)
        }
        if makeActive { activeUID = selection.serviceBodyUID }
    }

    mutating func remove(uid: String) {
        selections.removeAll { $0.serviceBodyUID == uid }
        if activeUID == uid { activeUID = selections.first?.serviceBodyUID }
    }
}
