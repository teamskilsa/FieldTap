import SwiftUI
import FTApp
import FTModel

/// The frame around an open capture: the sticky serving header and journey strip on top, the page picked in
/// the toolbar (Overview | Call flow | Radio), the cursor bar at the bottom, and the message sheet. The tab bar
/// is hidden here, so the pages get the height (about 874 pt on an iPhone 17, of which the frame uses ~350).
struct CaptureDetailView: View {
    @Bindable var session: CaptureSession

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ServingHeaderView(session: session)
                    JourneyStripView(session: session)
                    Divider()
                }
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CursorBar(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Page", selection: $session.page) {
                        ForEach(DetailPage.allCases, id: \.self) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    .accessibilityIdentifier("detailPagePicker")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .sheet(item: selectedEvent) { selection in
                MessageSheet(event: session.analysis.flow.events[selection.id], session: session)
                    .presentationDetents([.medium, .large])
                    .reportsScreen(.message, session: session, key: selection.id)
            }
            .reportsScreen(session.page.route, session: session, key: session.page.rawValue + (session.radioSection ?? ""))
    }

    @ViewBuilder private var page: some View {
        switch session.page {
        case .overview: OverviewPage(session: session)
        case .callflow: CallFlowPage(session: session)
        case .radio: RadioPage(session: session)
        }
    }

    /// The capture's trigger time, e.g. "Sep 21, 15:41".
    private var title: String {
        let s = session.analysis.summary
        return (s.triggerUtc ?? s.importedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The open message sheet, as the Identifiable item `.sheet(item:)` wants.
    private var selectedEvent: Binding<EventSelection?> {
        Binding(
            get: {
                session.selectedEvent.flatMap {
                    session.analysis.flow.events.indices.contains($0) ? EventSelection(id: $0) : nil
                }
            },
            set: { session.selectedEvent = $0?.id }
        )
    }
}

struct EventSelection: Identifiable, Hashable {
    var id: Int
}
