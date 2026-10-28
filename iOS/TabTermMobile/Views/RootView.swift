import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.pairedMac == nil {
                PairingView()
            } else {
                NavigationStack(path: $model.path) {
                    WorkspaceListView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .terminal(let session):
                                TerminalScreen(session: session)
                                    // A new identity per terminal, so switching
                                    // panes runs the old screen's disappear and
                                    // the new one's appear.
                                    .id(session)
                            }
                        }
                }
            }
        }
        .background(Color(uiColor: TerminalTheme.background).ignoresSafeArea())
    }
}
