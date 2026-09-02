import SwiftUI
import AVKit

struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var transcriber: Transcriber
    @EnvironmentObject var navigator: Navigator
    @Environment(\.palette) private var palette
    let session: Session

    @StateObject private var player = SessionPlayer()
    @FocusState private var keyFocus: Bool
    @State private var tab: Tab = .summary
    @State private var videoFullscreen = false
    @AppStorage("videoHeight") private var videoHeight: Double = 260
    enum Tab: String, CaseIterable { case summary = "Protokoll", transcript = "Transkript" }

    private var audioURLs: [URL] {
        var urls = [store.audioURL(for: session.id)]
        if session.hasSystemAudio { urls.append(store.systemAudioURL(for: session.id)) }
        return urls
    }
    private var videoURL: URL? { session.hasVideo ? store.videoURL(for: session.id) : nil }
    private var hasPlayback: Bool {
        (audioURLs + [videoURL].compactMap { $0 })
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if player.hasVideo {
                videoPane
            }
            if hasPlayback {
                PlaybackBar(player: player, markers: session.markers)
                    .padding(.horizontal).padding(.bottom, 6).padding(.top, player.hasVideo ? 8 : 0)
            }
            if !session.markers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(session.markers.enumerated()), id: \.offset) { _, t in
                            Button { player.seek(to: t) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "flag.fill").font(.system(size: 8))
                                        .foregroundStyle(palette.accentText)
                                    Text(SidebarView.mmss(t)).font(Brand.mono(10.5))
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small).buttonBorderShape(.capsule)
                        }
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            Divider()

            if session.status.hasTranscript {
                content
            } else if session.status == .error {
                // transcription may have succeeded and only the summary failed —
                // show the transcript if we have it, with the error on top
                if session.transcriptMarkdown != nil {
                    VStack(spacing: 0) {
                        errorStrip
                        content
                    }
                } else {
                    errorBox
                }
            } else {
                switch session.status {
                case .uploading, .processing: busy
                default:                      Spacer()
                }
            }
        }
        .navigationTitle(session.displayTitle)
        .overlay { if videoFullscreen { fullscreenVideo } }
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onAppear { keyFocus = true }
        .onKeyPress { press in
            // never while a text field is being edited
            let fr = NSApp.keyWindow?.firstResponder
            if fr is NSTextView || fr is NSTextField { return .ignored }
            if press.key == .escape && videoFullscreen { videoFullscreen = false; return .handled }
            guard player.duration > 0 else { return .ignored }
            let big = press.modifiers.contains(.shift)
            switch press.key {
            case .space:      player.togglePlay();              return .handled
            case .leftArrow:  player.skip(big ? -30 : -10);     return .handled
            case .rightArrow: player.skip(big ?  30 :  10);     return .handled
            default:          return .ignored
            }
        }
        .task(id: session.id) {
            player.load(audioURLs: audioURLs, videoURL: videoURL)
            keyFocus = true
        }
        .onDisappear { player.stop() }
        .toolbar { actions }
        .onChange(of: navigator.seekRequest) { _, req in
            guard let req, req.session == session.id else { return }
            tab = .transcript
            player.seek(to: req.time)
        }
    }

    // MARK: video

    @ViewBuilder
    private var videoPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoPlayer(player: player.player)
                    .frame(height: max(120, videoHeight))
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    videoFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(7)
                        .foregroundStyle(.white)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).padding(10)
            }
            // drag handle to resize
            Rectangle()
                .fill(.clear)
                .frame(height: 10)
                .overlay(Capsule().fill(palette.muted.opacity(0.5)).frame(width: 40, height: 4))
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { g in
                        videoHeight = min(max(120, videoHeight + g.translation.height), 640)
                    })
                .onHover { NSCursor.resizeUpDown.set(); if !$0 { NSCursor.arrow.set() } }

            HStack(spacing: 6) {
                if let size = videoFileSize {
                    Text("Video · \(size)").caps(9.5).foregroundStyle(palette.muted)
                }
                Spacer()
                Button("Video löschen", role: .destructive) { deleteVideo() }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal).padding(.vertical, 4)
        }
    }

    private var videoFileSize: String? {
        guard let url = videoURL,
              let bytes = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func deleteVideo() {
        if let url = videoURL { try? FileManager.default.removeItem(at: url) }
        var s = session
        s.hasVideo = false
        store.save(s)
        player.load(audioURLs: audioURLs, videoURL: nil)
    }

    private var fullscreenVideo: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player.player).ignoresSafeArea()
            Button { videoFullscreen = false } label: {
                Image(systemName: "xmark.circle.fill").font(.title)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain).padding()
            .help("Schliessen (Esc)")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.displayTitle)
                    .font(Brand.display(24)).tracking(-0.5)
                    .foregroundStyle(palette.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(session.kind.label))
                    Text("·")
                    Text(session.createdAt, format: .dateTime.day().month().year().hour().minute())
                    if let d = session.duration { Text("· \(SidebarView.mmss(d))") }
                    if session.hasSystemAudio { Text("· Mikro + Systemton") }
                    if let l = session.language { Text("· \(l.uppercased())") }
                }
                .caps(10, tracking: 0.9)
                .foregroundStyle(palette.muted)
            }
            Spacer(minLength: 12)
            if session.status.hasTranscript || session.transcriptMarkdown != nil {
                tabPicker
            }
        }
        .padding()
        .onChange(of: session.status) { _, new in
            if new == .transcribed || (new == .error && session.transcriptMarkdown != nil) {
                tab = .transcript
            }
        }
    }

    /// Per-session actions, in the window toolbar where macOS puts them.
    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        ToolbarItemGroup {
            if session.status.hasTranscript || session.transcriptMarkdown != nil {
                Button {
                    let text = tab == .transcript ? session.renderedTranscript
                                                  : session.renderedSummary
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(LocalizedStringKey(tab == .transcript ? "Transkript kopieren"
                                                                 : "Protokoll kopieren"),
                          systemImage: "doc.on.doc")
                }
                .help(tab == .transcript ? "Transkript kopieren" : "Protokoll kopieren")
                .disabled(tab == .summary && session.summaryMarkdown == nil)

                Menu {
                    let name = SessionExport.safeFilename(session)
                    Section("Sichern als …") {
                        Button("Protokoll (.md)") {
                            SessionExport.save(SessionExport.protocolMarkdown(session),
                                               suggestedName: "\(name) — Protokoll.md")
                        }
                        .disabled(session.summaryMarkdown == nil)
                        Button("Transkript (.md)") {
                            SessionExport.save(SessionExport.transcriptMarkdown(session),
                                               suggestedName: "\(name) — Transkript.md")
                        }
                        Button("Protokoll + Transkript (.md)") {
                            SessionExport.save(SessionExport.combinedMarkdown(session),
                                               suggestedName: "\(name).md")
                        }
                        Button("Untertitel (.srt)") {
                            SessionExport.save(SessionExport.srt(session),
                                               suggestedName: "\(name).srt")
                        }
                        .disabled(session.segments.isEmpty)
                    }
                    Divider()
                    Button("Teilen …", systemImage: "square.and.arrow.up") {
                        SessionExport.share(SessionExport.combinedMarkdown(session),
                                            name: "\(name).md",
                                            from: NSApp.keyWindow?.contentView)
                    }
                } label: {
                    Label("Exportieren", systemImage: "square.and.arrow.down")
                }
            }

            if session.status == .done || session.status == .error {
                Button { transcriber.retry(session.id) } label: {
                    Label("Erneut transkribieren", systemImage: "arrow.clockwise")
                }
                .help("Nimmt die Aufnahme komplett neu auf dem Server durch (Transkript + Protokoll).")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.dir(for: session.id)])
            } label: {
                Label("Im Finder", systemImage: "folder")
            }
            .help("Im Finder zeigen")
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var errorStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.accentText)
            Text("Transkript ok, Protokoll fehlgeschlagen").font(Brand.label(11))
            Text(session.errorMessage ?? "").font(Brand.body(10.5))
                .foregroundStyle(palette.muted).lineLimit(1)
            Spacer()
            if transcriber.resummarizing.contains(session.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Protokoll erneut") { transcriber.resummarize(session.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(palette.ink)
        .background(palette.accent.opacity(palette.isDark ? 0.18 : 0.24),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var busy: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(LocalizedStringKey(session.status == .uploading
                                    ? "Wird hochgeladen…" : "Wird transkribiert…"))
                .caps(11).foregroundStyle(palette.muted)
            if let note = session.errorMessage {      // e.g. "Warte auf den Server …"
                Text(note).font(Brand.body(11)).foregroundStyle(palette.accentText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBox: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                .foregroundStyle(palette.accentText)
            Text(session.errorMessage ?? "Fehler")
                .font(Brand.body(12)).foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
            Button("Erneut versuchen") { transcriber.retry(session.id) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if tab == .transcript {
            if session.segments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !session.speakers.isEmpty { SpeakerNames(session: session); Divider() }
                        MarkdownText(text: session.renderedTranscript)
                    }
                    .padding().frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TranscriptView(session: session, player: player)
            }
        } else {
            summaryTab
        }
    }

    @ViewBuilder
    private var summaryTab: some View {
        if session.summaryMarkdown != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer()
                        if transcriber.resummarizing.contains(session.id) {
                            ProgressView().controlSize(.small)
                            Text("wird neu erstellt…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button {
                                transcriber.resummarize(session.id)
                            } label: {
                                Label("Neu erstellen", systemImage: "sparkles")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .buttonBorderShape(.capsule)
                            .help("Lässt die KI das Protokoll neu schreiben (z.B. nach Änderungen am Transkript).")
                        }
                    }
                    MarkdownText(text: session.renderedSummary)
                }
                .padding().frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.status == .error {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.xmark").font(.largeTitle).foregroundStyle(.orange)
                Text("Protokoll fehlgeschlagen").foregroundStyle(.secondary)
                Text(session.errorMessage ?? "").font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Protokoll neu erstellen") { transcriber.resummarize(session.id) }
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Protokoll wird erstellt…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Clickable transcript with playback-follow. While playing it scrolls to keep
/// the current line centred; if you scroll away it stops and shows a button to
/// jump back to the live position.
struct TranscriptView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.palette) private var palette
    let session: Session
    @ObservedObject var player: SessionPlayer

    @State private var following = true
    @State private var programmatic = false
    @State private var lastActiveID: String?

    private var activeID: String? {
        session.segments.first { $0.contains(player.currentTime) }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !session.speakers.isEmpty {
                        SpeakerNames(session: session)
                        Divider()
                    }
                    ForEach(Array(session.speakerGroups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.speakerLabel(for: group.speaker))
                                .caps(10.5)
                                .foregroundStyle(palette.muted)
                            ForEach(group.segments) { seg in segmentRow(seg) }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self,
                                           value: g.frame(in: .named("transcript")).minY)
                })
            }
            .coordinateSpace(name: "transcript")
            .onPreferenceChange(ScrollOffsetKey.self) { _ in
                if player.isPlaying && !programmatic { following = false }
            }
            .onChange(of: activeID) { _, id in
                guard following, let id, id != lastActiveID else { return }
                lastActiveID = id
                scroll(to: id, proxy)
            }
            .onChange(of: player.isPlaying) { _, playing in
                if playing { following = true }
            }
            .overlay(alignment: .bottom) {
                if !following && player.isPlaying {
                    Button {
                        following = true
                        if let id = activeID { scroll(to: id, proxy) }
                    } label: {
                        Label("Zur aktuellen Stelle", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func scroll(to id: String, _ proxy: ScrollViewProxy) {
        programmatic = true
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { programmatic = false }
    }

    @ViewBuilder
    private func segmentRow(_ seg: TranscriptSegment) -> some View {
        let active = seg.contains(player.currentTime)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SidebarView.mmss(seg.startTime))
                .font(Brand.mono(10.5))
                .foregroundStyle(active ? palette.accentText : palette.muted)
                .frame(width: 42, alignment: .trailing)
            Text(seg.text)
                .font(Brand.body(13))
                .foregroundStyle(palette.ink.opacity(active ? 1 : 0.82))
                .fontWeight(active ? .medium : .regular)
        }
        .id(seg.id)
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(active ? palette.accent.opacity(palette.isDark ? 0.22 : 0.30) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: seg.startTime)
            if !player.isPlaying { player.play() }
        }
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Play/pause + scrubber. The player is owned by SessionDetailView so the
/// transcript can share it.
struct PlaybackBar: View {
    @ObservedObject var player: SessionPlayer
    @Environment(\.palette) private var palette
    var markers: [TimeInterval] = []

    var body: some View {
        HStack(spacing: 10) {
            Button { player.skip(-10) } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain).disabled(player.duration == 0)

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 30, height: 30)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain).disabled(player.duration == 0)

            Button { player.skip(10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain).disabled(player.duration == 0)

            Scrubber(player: player, markers: markers)

            Text("\(SidebarView.mmss(player.currentTime)) / \(SidebarView.mmss(player.duration))")
                .font(Brand.mono(11)).foregroundStyle(palette.ink)
                .frame(width: 92, alignment: .trailing)
        }
    }
}

/// Editable SPEAKER_xx -> name map, with "remember this voice" per speaker.
struct SpeakerNames: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var transcriber: Transcriber
    @Environment(\.palette) private var palette
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sprecher").caps().foregroundStyle(palette.muted)
            ForEach(session.speakers, id: \.self) { tag in
                HStack(spacing: 6) {
                    Text(tag).font(.callout.monospaced()).frame(width: 104, alignment: .leading)
                    TextField("Name", text: binding(for: tag))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    voiceMenu(for: tag)
                }
            }
            if session.speakerNames.values.contains(where: { !$0.isEmpty }) {
                Text("Namen erscheinen sofort auch im Protokoll. Stimme merken erkennt die Person in künftigen Aufnahmen automatisch.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task { transcriber.loadVoices() }
    }

    @ViewBuilder
    private func voiceMenu(for tag: String) -> some View {
        let typed = session.speakerNames[tag]?.trimmingCharacters(in: .whitespaces) ?? ""
        Menu {
            if !transcriber.voices.isEmpty {
                Section("Gespeicherte Stimme zuordnen") {
                    ForEach(transcriber.voices, id: \.name) { v in
                        Button("\(v.name)  (\(v.samples))") {
                            transcriber.rememberVoice(name: v.name, sessionID: session.id, speaker: tag)
                        }
                    }
                }
            }
            if !typed.isEmpty {
                Divider()
                Button("Als Stimme merken: \(typed)", systemImage: "waveform.badge.plus") {
                    transcriber.rememberVoice(name: typed, sessionID: session.id, speaker: tag)
                }
            }
        } label: {
            Image(systemName: "person.wave.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Diese Stimme speichern oder eine gespeicherte zuordnen")
    }

    private func binding(for tag: String) -> Binding<String> {
        Binding(
            get: { session.speakerNames[tag] ?? "" },
            set: { newValue in
                var s = session
                s.speakerNames[tag] = newValue
                store.save(s)
            })
    }
}

/// Very small markdown renderer — headings, bold, bullet lists, paragraphs.
struct MarkdownText: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, raw in
                let line = String(raw)
                if line.hasPrefix("# ") {
                    Text(line.dropFirst(2))
                        .caps(11).foregroundStyle(palette.muted)
                        .padding(.top, 8)
                } else if line.hasPrefix("## ") {
                    Text(line.dropFirst(3))
                        .caps(10.5).foregroundStyle(palette.muted)
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(palette.accentText)
                            .frame(width: 5, height: 5).padding(.top, 7)
                        inline(String(line.dropFirst(2)))
                    }
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    inline(line)
                }
            }
        }
        .font(Brand.body(13))
        .foregroundStyle(palette.ink)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        (try? Text(AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))))
        ?? Text(s)
    }
}

/// Scrubber in the system's shape, with one addition the plain Slider can't
/// make: the markers you set during the recording sit on the track.
struct Scrubber: View {
    @Environment(\.palette) private var palette
    @ObservedObject var player: SessionPlayer
    var markers: [TimeInterval] = []

    var body: some View {
        GeometryReader { geo in
            let total = max(player.duration, 0.01)
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.ink.opacity(0.12))
                    .frame(height: 6)
                Capsule().fill(palette.accent)
                    .frame(width: width * fraction(player.currentTime, total), height: 6)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, t in
                    Capsule().fill(palette.ink.opacity(0.42))
                        .frame(width: 2, height: 14)
                        .offset(x: width * fraction(t, total) - 1)
                }
                Circle().fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .offset(x: width * fraction(player.currentTime, total) - 7.5)
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard player.duration > 0 else { return }
                player.seek(to: Double(g.location.x / width) * total)
            })
        }
        .frame(height: 16)
    }

    private func fraction(_ t: TimeInterval, _ total: TimeInterval) -> Double {
        min(max(t / total, 0), 1)
    }
}
