import SwiftUI

/// The popover shown from the menu-bar icon: quick record + recent sessions.
struct MenuBarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var controller: RecordingController
    @EnvironmentObject var recorder: AudioRecorder
    @EnvironmentObject var watcher: MeetingWatcher
    @Environment(\.openWindow) private var openWindow
    @Environment(\.palette) private var palette

    @State private var kind: SessionKind = .voiceNote
    @State private var wantsSystemAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = watcher.pending, !recorder.isRecording {
                VStack(alignment: .leading, spacing: 6) {
                    Label(e.title, systemImage: "calendar.badge.clock")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text("läuft gerade · \(e.timeRange)")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Aufnehmen") { watcher.accept(e) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Ignorieren") { watcher.dismiss(e) }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.accent.opacity(palette.isDark ? 0.18 : 0.24),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if recorder.isRecording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(SidebarView.mmss(recorder.elapsed))
                        .font(Brand.display(17)).monospacedDigit()
                        .foregroundStyle(palette.ink)
                    Spacer()
                    Button("Stopp") { Task { _ = await controller.finish() } }
                        .tint(.red)
                }
                Label(LocalizedStringKey(recorder.capturedSystemAudio
                                         ? "Mikro + Systemton" : "nur Mikrofon"),
                      systemImage: recorder.capturedSystemAudio ? "waveform.badge.plus" : "mic")
                    .font(.caption).foregroundStyle(.secondary)
                Button { controller.addMarker() } label: {
                    Label("Stelle merken\(controller.markers.isEmpty ? "" : " (\(controller.markers.count))")",
                          systemImage: "flag")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            } else {
                Picker("", selection: $kind) {
                    ForEach(SessionKind.allCases, id: \.self) {
                        Text(LocalizedStringKey($0.label)).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                if kind == .meeting {
                    Toggle("Systemton mit aufnehmen", isOn: $wantsSystemAudio)
                        .toggleStyle(.checkbox).font(.callout)
                }

                Button {
                    Task { await controller.begin(kind: kind, title: "",
                                                  wantsSystemAudio: wantsSystemAudio) }
                } label: {
                    Label("Aufnehmen", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }

            if !store.sessions.isEmpty {
                Divider()
                Text("Zuletzt").caps(9.5).foregroundStyle(palette.muted)
                ForEach(store.sessions.prefix(4)) { s in
                    Button {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: s.kind.symbol).foregroundStyle(.secondary).frame(width: 14)
                            Text(s.displayTitle).lineLimit(1)
                            Spacer()
                            if s.status.isBusy { ProgressView().controlSize(.mini) }
                            else if s.status == .error {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }

            Divider()
            HStack {
                Button("Fenster öffnen") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 268)
        .background(palette.paper)
    }
}
