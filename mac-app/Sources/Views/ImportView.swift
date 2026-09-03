import SwiftUI
import UniformTypeIdentifiers

/// Bring an existing audio or video file into the library and transcribe it.
struct ImportView: View {
    @EnvironmentObject var controller: RecordingController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var onFinish: (UUID) -> Void

    @State private var fileURL: URL?
    @State private var kind: SessionKind = .meeting
    @State private var title = ""
    @State private var speakerCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Datei importieren")
                .font(Brand.display(14)).foregroundStyle(palette.ink)

            HStack(spacing: 10) {
                Image(systemName: fileURL == nil ? "doc.badge.plus"
                      : (isVideo ? "film" : "waveform"))
                    .font(.title2).foregroundStyle(palette.muted).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileURL?.lastPathComponent ?? "Keine Datei gewählt")
                        .font(Brand.label(12.5)).lineLimit(1)
                    Text("Audio oder Video · wird auf dem Server transkribiert")
                        .font(Brand.body(10.5)).foregroundStyle(palette.muted)
                }
                Spacer()
                Button("Wählen …") { pick() }
            }
            .padding(10)
            .background(palette.side, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Picker("Typ", selection: $kind) {
                ForEach(SessionKind.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Titel (optional)", text: $title)
                .textFieldStyle(.roundedBorder)

            SpeakerCountPicker(count: $speakerCount)

            HStack {
                Button("Abbrechen") { dismiss() }
                Spacer()
                Button("Importieren") {
                    guard let fileURL else { return }
                    controller.importFile(fileURL, kind: kind, title: title,
                                          speakerCount: speakerCount)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(palette.accent).foregroundStyle(palette.onAccent)
                .disabled(fileURL == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(palette.paper)
    }

    private var isVideo: Bool {
        guard let ext = fileURL?.pathExtension.lowercased() else { return false }
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie,
                                     .mp3, .wav, .aiff, .mpeg4Audio]
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            kind = isVideo ? .meeting : .voiceNote
        }
    }
}
