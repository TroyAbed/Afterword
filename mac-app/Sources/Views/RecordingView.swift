import SwiftUI
import ScreenCaptureKit

/// Modal: pick a kind, record, stop -> creates a Session and starts processing.
struct RecordingView: View {
    @EnvironmentObject var controller: RecordingController
    @EnvironmentObject var recorder: AudioRecorder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var onFinish: (UUID) -> Void

    @StateObject private var calendar = MeetingCalendar()
    @State private var kind: SessionKind = .voiceNote
    @State private var title = ""
    @State private var wantsSystemAudio = true
    @State private var recordVideo = false
    @State private var windows: [SCWindow] = []
    @State private var chosenWindow: CGWindowID?
    @State private var loadingWindows = false
    @State private var autoDetected = false

    private var selectedWindow: SCWindow? {
        windows.first { $0.windowID == chosenWindow }
    }

    private func refreshWindows() {
        loadingWindows = true
        Task {
            windows = await WindowVideoCapture.windows()
            loadingWindows = false
            // pre-select the window that looks like the actual call
            if let guess = WindowVideoCapture.likelyMeetingWindow(windows),
               chosenWindow == nil || !windows.contains(where: { $0.windowID == chosenWindow }) {
                chosenWindow = guess.windowID
                autoDetected = true
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                if recorder.isRecording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.4), radius: 3)
                }
                Text(LocalizedStringKey(recorder.isRecording ? "Aufnahme läuft" : "Neue Aufnahme"))
                    .font(Brand.display(14))
                    .foregroundStyle(palette.ink)
            }

            if !recorder.isRecording {
                if let event = calendar.current {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text("läuft gerade · \(event.timeRange)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if title != event.title {
                            Button("Übernehmen") { title = event.title; kind = .meeting }
                                .controlSize(.small)
                        }
                    }
                    .padding(9)
                    .background(palette.accent.opacity(palette.isDark ? 0.18 : 0.24),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                Picker("Typ", selection: $kind) {
                    ForEach(SessionKind.allCases, id: \.self) {
                        Text(LocalizedStringKey($0.label)).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Titel (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)

                if kind == .meeting {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Systemton mit aufnehmen (Teams / Zoom)", isOn: $wantsSystemAudio)
                            .toggleStyle(.checkbox)
                        Toggle("Fenster als Video aufzeichnen", isOn: $recordVideo)
                            .toggleStyle(.checkbox)
                            .onChange(of: recordVideo) { _, on in if on { refreshWindows() } }
                        if recordVideo {
                            HStack {
                                Text("Fenster wählen").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if autoDetected, selectedWindow != nil {
                                    Label("automatisch erkannt", systemImage: "sparkles")
                                        .font(.caption2).foregroundStyle(.tint)
                                }
                                Spacer()
                                Button { refreshWindows() } label: { Image(systemName: "arrow.clockwise") }
                                    .controlSize(.small).disabled(loadingWindows)
                            }
                            if windows.isEmpty {
                                Text("Keine Fenster — Bildschirmaufnahme erlauben & App neu starten.")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                WindowPickerGrid(windows: windows, selection: Binding(
                                    get: { chosenWindow },
                                    set: { chosenWindow = $0; autoDetected = false }))
                            }
                            Text("Tipp: in Teams/Zoom das Video herauslösen (pop out) → dann nur das Video, kein Chat.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                if let frame = controller.previewFrame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(SidebarView.mmss(recorder.elapsed))
                    .font(Brand.display(38)).monospacedDigit()
                    .foregroundStyle(palette.ink)
                LevelMeter(level: recorder.level).frame(height: 10)
                HStack(spacing: 12) {
                    Label(LocalizedStringKey(recorder.capturedSystemAudio
                                             ? "Mikro + Systemton" : "nur Mikrofon"),
                          systemImage: recorder.capturedSystemAudio ? "waveform.badge.plus" : "mic")
                    if controller.recordingVideo {
                        Label("Video", systemImage: "record.circle").foregroundStyle(.red)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)

                Button { controller.addMarker() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "flag.fill").font(.system(size: 10))
                            .foregroundStyle(palette.accentText)
                        Text("Stelle merken").font(Brand.label(12.5, .medium))
                        Text("⌘M").font(Brand.body(10)).foregroundStyle(palette.muted)
                    }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .keyboardShortcut("m", modifiers: [.command])
                .help("⌘M — setzt einen Zeitstempel, den du im Transkript wiederfindest")
                if !controller.markers.isEmpty {
                    Text("\(controller.markers.count) Marker · zuletzt \(SidebarView.mmss(controller.markers.last!))")
                        .font(Brand.mono(10.5)).foregroundStyle(palette.muted)
                }
            }

            if let notice = controller.notice {
                Text(notice).font(Brand.body(11)).foregroundStyle(palette.accentText)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Abbrechen") { Task { await controller.cancel(); dismiss() } }
                Spacer()
                Button(LocalizedStringKey(recorder.isRecording ? "Stopp" : "Aufnehmen")) {
                    if recorder.isRecording {
                        Task {
                            if let id = await controller.finish() { onFinish(id) }
                            dismiss()
                        }
                    } else {
                        Task {
                            await controller.begin(
                                kind: kind, title: title, wantsSystemAudio: wantsSystemAudio,
                                videoWindow: (kind == .meeting && recordVideo) ? selectedWindow : nil)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : palette.accent)
                .foregroundStyle(recorder.isRecording ? .white : palette.onAccent)
                .disabled(!recorder.isRecording && kind == .meeting && recordVideo && selectedWindow == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(palette.paper)
        .task {
            await calendar.requestAccessAndRefresh()
            if let e = calendar.current, title.isEmpty {
                title = e.title
                kind = .meeting
            }
        }
    }

    private func label(for w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let t = w.title ?? ""
        return t.isEmpty ? app : "\(app) — \(t)"
    }
}

struct LevelMeter: View {
    @Environment(\.palette) private var palette
    var level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.ink.opacity(0.12))
                Capsule().fill(palette.accent)
                    .frame(width: geo.size.width * CGFloat(max(0.02, level)))
            }
        }
    }
}

/// Grid of window thumbnails, like the screen-picker in Discord/Teams.
struct WindowPickerGrid: View {
    @Environment(\.palette) private var palette
    let windows: [SCWindow]
    @Binding var selection: CGWindowID?
    @State private var thumbs: [CGWindowID: NSImage] = [:]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                ForEach(windows, id: \.windowID) { w in
                    Button { selection = w.windowID } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(palette.side)
                                if let img = thumbs[w.windowID] {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selection == w.windowID
                                                  ? palette.accent : palette.line,
                                                  lineWidth: selection == w.windowID ? 2.5 : 1)
                            }
                            Text(label(w)).font(Brand.body(10.5)).lineLimit(2)
                                .foregroundStyle(palette.ink)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .frame(height: 220)
        .task(id: windows.map(\.windowID)) {
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                for w in windows where thumbs[w.windowID] == nil {
                    group.addTask { (w.windowID, await WindowVideoCapture.thumbnail(of: w)) }
                }
                for await (id, img) in group { if let img { thumbs[id] = img } }
            }
        }
    }

    private func label(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let t = w.title ?? ""
        return t.isEmpty || t == app ? app : "\(app) — \(t)"
    }
}
