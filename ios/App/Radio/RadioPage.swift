import SwiftUI
import FTApp
import FTModel

/// The Radio page: section chips (signal, DL, UL, CSI, NR, antennas, carriers, RACH, not available) and the
/// charts of the chosen section, all on the capture's one visible window and time cursor.
struct RadioPage: View {
    @Bindable var session: CaptureSession

    enum Section: String, CaseIterable, Identifiable {
        case signal, dl, ul, csi, nr, antennas, carriers, rach, unavailable
        var id: String { rawValue }

        var title: String {
            switch self {
            case .signal: "Signal"
            case .dl: "DL"
            case .ul: "UL"
            case .csi: "CSI"
            case .nr: "NR"
            case .antennas: "Antennas"
            case .carriers: "Carriers"
            case .rach: "RACH"
            case .unavailable: "Not available"
            }
        }
    }

    private var section: Section { session.radioSection.flatMap(Section.init(rawValue:)) ?? .signal }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                SwiftUI.Section {
                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                } header: {
                    chips
                }
            }
        }
        // Room under the last chart for the floating cursor bar (CapturePageLayout).
        .contentMargins(.bottom, CapturePageLayout.scrollBottomInset, for: .scrollContent)
        .onAppear { if session.radioSection == nil { session.radioSection = Section.signal.rawValue } }
        .accessibilityIdentifier("radioPage")
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Section.allCases) { s in
                        Button {
                            session.radioSection = s.rawValue
                        } label: {
                            Text(s.title)
                                .font(.subheadline.weight(s == section ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(s == section ? Theme.accent : Color.secondary.opacity(0.12)))
                                .foregroundStyle(s == section ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(s)
                        .accessibilityAddTraits(s == section ? .isSelected : [])
                        .accessibilityIdentifier("radioSection-\(s.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(section, anchor: .center) }
            .onChange(of: section) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
        }
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .signal: SignalSection(session: session)
        case .dl: DownlinkSection(session: session)
        case .ul: UplinkSection(session: session)
        case .csi: CsiSection(session: session)
        case .nr: NrSection(session: session)
        case .antennas: AntennaPanel(session: session)
        case .carriers: CarriersGrid(session: session)
        case .rach: RachSection(session: session)
        case .unavailable: UnavailableSection(session: session)
        }
    }
}
