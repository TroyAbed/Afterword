import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.palette) private var palette
    @State private var selection: UUID?
    @State private var recording = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 258, max: 400)
        } detail: {
            Group {
                if let s = store.session(selection) {
                    SessionDetailView(session: s)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.paper)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { recording = true } label: {
                    Label("Aufnehmen", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.onAccent)
                .help("Neue Aufnahme")
            }
        }
        .sheet(isPresented: $recording) {
            RecordingView { newID in selection = newID }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            BrandMark(size: 64, palette: palette)
            Text("Keine Aufnahme gewählt")
                .font(Brand.display(17))
                .foregroundStyle(palette.ink)
            Text("Nimm ein Meeting oder eine Voice Note auf.")
                .font(Brand.body(12)).foregroundStyle(palette.muted)
        }
    }
}
