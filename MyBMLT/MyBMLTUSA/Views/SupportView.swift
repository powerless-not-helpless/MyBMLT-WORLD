import SwiftUI

/// Support: regional helplines plus national crisis lines.
///
/// Regional numbers come from the service body graph — verified that the
/// San Diego **region** carries `helpline "6195841007"` while every sub-area
/// returns `""`, so the lookup walks up the ancestor chain rather than reading
/// only the selected Area.
///
/// National lines are bundled rather than fetched, and are rendered even when
/// the network is unavailable, because they are the safety-critical part.
struct SupportView: View {
    @Environment(AreaStore.self) private var areas

    var body: some View {
        NavigationStack {
            List {
                regionalSection
                nationalSection
                worldServiceSection
                disclaimerSection
            }
            .navigationTitle("Support")
        }
    }

    // MARK: - Regional

    @ViewBuilder
    private var regionalSection: some View {
        Section {
            if let active = areas.active, let activeBody = areas.activeBody,
               let tree = areas.tree {

                if let found = tree.nearestHelpline(for: activeBody) {
                    helplineRow(found.helpline, source: found.body.name)
                } else {
                    // Verified to be the *common* case: most sub-areas have an
                    // empty helpline. Say so plainly instead of showing nothing.
                    Text("No local helpline is listed for \(active.displayName). National lines are below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let url = activeBody.webURL {
                    Link(destination: url) {
                        Label(activeBody.name, systemImage: "safari")
                    }
                }
            } else {
                Text("Choose an Area to see local helplines.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(areas.active?.displayName ?? "Local")
        } footer: {
            Text("Local numbers come from the regional meeting server and update with it.")
        }
    }

    private func helplineRow(_ helpline: Helpline, source: String) -> some View {
        Link(destination: URL(string: "tel://\(helpline.dialString)")!) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(helpline.display, systemImage: "phone.fill")
                    // A number with no country code cannot be dialled from
                    // abroad. Say so rather than letting the user find out.
                    if let notice = helpline.reachability.notice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - National

    private var nationalSection: some View {
        Section {
            ForEach(NationalResources.all) { resource in
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: URL(string: "tel://\(resource.digits)")!) {
                        Label("\(resource.name) — \(resource.display)", systemImage: "phone.fill")
                    }
                    Text(resource.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Rendered as notes, not buttons. Each needs a keypress
                    // after connecting, which a `tel:` link cannot send —
                    // tapping one would dial the number and lose the prompt.
                    ForEach(resource.options) { option in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(option.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("National")
        } footer: {
            Text("These are phone numbers, not counseling services provided by this app.")
        }
    }

    /// Kept out of the crisis section above. The World Service Office answers
    /// literature and service questions; it is not a helpline and should never
    /// sit beside 988.
    private var worldServiceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Link(destination: URL(string: "tel://\(NAWorldServices.digits)")!) {
                    Label("\(NAWorldServices.name) — \(NAWorldServices.display)",
                          systemImage: "building.2")
                }
                Text(NAWorldServices.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Service office")
        }
    }

    private var disclaimerSection: some View {
        Section {
            Text("""
            This app displays meeting information published by local NA service \
            bodies. It does not host or run any meeting, and it is not affiliated \
            with any helpline listed here.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Bundled national resources.
///
/// **Verified against each operator's own site**, not recollection:
///
/// - 988 — 988lifeline.org: call, text, chat; Spanish via "press 2" or text
///   AYUDA; Veterans Crisis Line via "press 1" or text 838255.
/// - SAMHSA — samhsa.gov: 1-800-662-4357, 24/7, English and Spanish; TTY
///   1-800-487-4889.
///
/// **NA World Services was removed.** Its number (1-818-773-9999) is correct and
/// its other published number (818-700-0700) is a *fax*, but WSO is the
/// administrative office — literature orders, service material, employment.
/// Listing it beside 988 implied it was a crisis line; someone in crisis would
/// reach a business-hours switchboard. NA publishes no national helpline, and
/// local numbers are surfaced separately by `nearestHelpline`, which walks up to
/// the region. `1-818-773-9999` is retained below as non-crisis contact info.
struct NationalResources: Identifiable {
    let id: String
    let name: String
    let display: String
    let digits: String
    let detail: String
    /// Alternative ways to reach the same line — a language, a service for a
    /// specific group, a TTY. Kept as notes rather than separate rows because
    /// each needs a keypress the dialer cannot supply: tapping a "press 2" row
    /// would dial 988 and silently drop the 2.
    var options: [Option] = []

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let detail: String
    }

    /// Crisis and support lines. Order matters: 988 first, because it is the one
    /// to call in an emergency.
    static let all: [NationalResources] = [
        NationalResources(
            id: "988",
            name: "988 Suicide & Crisis Lifeline",
            display: "988",
            digits: "988",
            detail: "Call or text 988. Free, confidential, 24/7.",
            options: [
                Option(id: "988-es", label: "En español",
                       detail: "Call 988, then press 2. Or text AYUDA to 988."),
                Option(id: "988-vet", label: "Veterans",
                       detail: "Call 988, then press 1. Or text 838255."),
                Option(id: "988-deaf", label: "Deaf & hard of hearing",
                       detail: "ASL services are available through the website."),
            ]
        ),
        NationalResources(
            id: "samhsa",
            name: "SAMHSA National Helpline",
            display: "1-800-662-4357",
            digits: "18006624357",
            detail: "Treatment referral and information, 24/7, English and Spanish.",
            options: [
                Option(id: "samhsa-tty", label: "TTY",
                       detail: "1-800-487-4889"),
            ]
        ),
    ]
}

/// Non-crisis contact information, shown separately so it is never mistaken for
/// a helpline.
enum NAWorldServices {
    static let name = "NA World Services"
    static let display = "1-818-773-9999"
    static let digits = "18187739999"
    static let detail = "World Service Office — literature, service inquiries and general information. Not a helpline and not staffed for crisis."
}
