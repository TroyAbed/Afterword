import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.palette) private var palette
    @State private var selection: UUID?
    @State private var recording = false
    @State private var importing = false

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
                Menu {
                    Button("Aufnehmen", systemImage: "record.circle") { recording = true }
                    Button("Datei importieren …", systemImage: "square.and.arrow.down") { importing = true }
                } label: {
                    Label("Aufnehmen", systemImage: "record.circle")
                } primaryAction: {
                    recording = true
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.onAccent)
                .help("Aufnehmen oder eine Datei importieren")
            }
        }
        .sheet(isPresented: $recording) {
            RecordingView { newID in selection = newID }
        }
        .sheet(isPresented: $importing) {
            ImportView { newID in selection = newID }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            BrandMark(size: 64, palette: palette)
            Text("Keine Aufnahme gewählt")
                .font(Brand.display(17))
                .foregroundStyle(palette.ink)
            Text("Nimm ein Meeting oder eine Voice Note auf — oder importiere eine Datei.")
                .font(Brand.body(12)).foregroundStyle(palette.muted)
        }
    }
}
