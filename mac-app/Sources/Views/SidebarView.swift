import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var transcriber: Transcriber
    @EnvironmentObject var navigator: Navigator
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: UUID?
    @State private var search = ""
    @State private var renaming: Session?
    @State private var newTitle = ""

    private struct Result: Identifiable {
        let session: Session
        let hits: [TranscriptSegment]
        var id: UUID { session.id }
    }

    private var results: [Result] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.sessions.map { Result(session: $0, hits: []) } }
        return store.sessions.compactMap { s in
            let inTitle = s.displayTitle.lowercased().contains(q)
            let inSummary = (s.summaryMarkdown ?? "").lowercased().contains(q)
            let hits = s.segments.filter { $0.text.lowercased().contains(q) }
            let inFlat = s.segments.isEmpty
                && (s.transcriptMarkdown ?? "").lowercased().contains(q)
            guard inTitle || inSummary || inFlat || !hits.isEmpty else { return nil }
            return Result(session: s, hits: Array(hits.prefix(5)))
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        // Rows are drawn by hand rather than through List's selection:
                        // the system fills a selected row with the tint and forces
                        // white text, which is unreadable on a light accent.
                        Button { selection = r.session.id } label: {
                            row(r.session, selected: selection == r.session.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Umbenennen") { renaming = r.session; newTitle = r.session.title }
                            if r.session.status == .error {
                                Button("Erneut versuchen") { transcriber.retry(r.session.id) }
                            }
                            Button("Löschen", role: .destructive) { store.delete(r.session) }
                        }
                        ForEach(r.hits) { seg in
                            Button {
                                selection = r.session.id
                                navigator.jump(to: r.session.id, at: seg.startTime)
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(SidebarView.mmss(seg.startTime))
                                        .font(Brand.mono(10))
                                        .foregroundStyle(palette.accentText)
                                    Text(snippet(seg.text))
                                        .font(Brand.body(10.5))
                                        .foregroundStyle(palette.muted)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .padding(.leading, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text("Aufnahmen").caps().foregroundStyle(palette.muted)
            }

            if !search.isEmpty && results.isEmpty {
                Text("Keine Treffer")
                    .font(Brand.body(11)).foregroundStyle(palette.muted)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            BrandLockup()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13.5))
                            .foregroundStyle(palette.muted)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Einstellungen (⌘,)")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .searchable(text: $search, prompt: "In allen Aufnahmen suchen")
        .navigationTitle("Afterword")
        .onMoveCommand { direction in step(direction) }
        .sheet(item: $renaming) { s in
            VStack(alignment: .leading, spacing: 14) {
                Text("Umbenennen").font(Brand.display(15))
                TextField("Titel", text: $newTitle)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { commitRename(s) }
                HStack {
                    Spacer()
                    Button("Abbrechen") { renaming = nil }
                    Button("Sichern") { commitRename(s) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    /// Arrow keys still walk the list even though selection is drawn by hand.
    private func step(_ direction: MoveCommandDirection) {
        let ids = results.map(\.session.id)
        guard !ids.isEmpty else { return }
        guard let current = selection, let i = ids.firstIndex(of: current) else {
            selection = ids.first
            return
        }
        switch direction {
        case .up:   if i > 0 { selection = ids[i - 1] }
        case .down: if i < ids.count - 1 { selection = ids[i + 1] }
        default: break
        }
    }

    /// A short window of text around the search term.
    private func snippet(_ text: String) -> String {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let r = text.range(of: q, options: .caseInsensitive) else {
            return String(text.prefix(90))
        }
        let start = text.index(r.lowerBound, offsetBy: -40,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 50,
                             limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    private func commitRename(_ s: Session) {
        var updated = s
        updated.title = newTitle.trimmingCharacters(in: .whitespaces)
        store.save(updated)
        renaming = nil
    }

    @ViewBuilder
    private func row(_ s: Session, selected: Bool) -> some View {
        let fg = selected ? palette.onAccent : palette.ink
        HStack(spacing: 9) {
            Image(systemName: s.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? palette.onAccent.opacity(0.8) : palette.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle)
                    .font(Brand.label(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(s.createdAt, style: .date)
                    if let d = s.duration { Text("· \(Self.mmss(d))") }
                    if !s.markers.isEmpty { Image(systemName: "flag.fill").font(.system(size: 7)) }
                }
                .font(Brand.body(10.5))
                .foregroundStyle(selected ? palette.onAccent.opacity(0.65) : palette.muted)
            }
            Spacer(minLength: 4)
            statusBadge(s.status, selected: selected)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.accent)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusBadge(_ st: SessionStatus, selected: Bool) -> some View {
        switch st {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(selected ? palette.onAccent : .orange)
        case .done:
            dot(selected ? palette.onAccent.opacity(0.55) : palette.muted)
        case .transcribed:
            dot(selected ? palette.onAccent : palette.accentText)
        default:
            ProgressView().controlSize(.mini)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    static func mmss(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
