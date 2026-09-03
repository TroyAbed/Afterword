import AppKit
import Foundation

/// Builds shareable text from a session and puts it on disk / into a share sheet.
enum SessionExport {

    static func protocolMarkdown(_ s: Session) -> String {
        var out = "# \(s.displayTitle)\n\n"
        out += "\(s.kind.label) · \(Session.dateFormatter.string(from: s.createdAt))"
        if let d = s.duration { out += " · \(mmss(d))" }
        let named = s.speakers.map { s.speakerLabel(for: $0) }.filter { !$0.hasPrefix("SPEAKER_") }
        if !named.isEmpty { out += " · \(named.joined(separator: ", "))" }
        out += "\n\n"
        out += s.renderedSummary.isEmpty ? "_(kein Protokoll)_\n" : s.renderedSummary + "\n"
        return out
    }

    static func transcriptMarkdown(_ s: Session) -> String {
        var out = "# \(s.displayTitle) — Transkript\n\n"
        out += "\(Session.dateFormatter.string(from: s.createdAt))\n\n"
        if s.segments.isEmpty {
            out += s.renderedTranscript
        } else {
            var last: String?
            for seg in s.segments {
                let who = s.speakerLabel(for: seg.speaker)
                if who != last {
                    out += "\n**\(who)**\n\n"
                    last = who
                }
                out += "`\(mmss(seg.startTime))`  \(seg.text)\n"
            }
        }
        return out
    }

    static func combinedMarkdown(_ s: Session) -> String {
        protocolMarkdown(s) + "\n---\n\n" + transcriptMarkdown(s)
    }

    /// SubRip subtitles, so the transcript can ride along with the video.
    /// The first cue carries the session title + date.
    static func srt(_ s: Session) -> String {
        var out = "1\n\(srtTime(0)) --> \(srtTime(2.5))\n"
        out += "\(s.displayTitle)\n\(Session.dateFormatter.string(from: s.createdAt))\n\n"
        for (i, seg) in s.segments.enumerated() {
            let start = seg.start ?? 0
            let end = seg.end ?? (start + 3)
            out += "\(i + 2)\n\(srtTime(start)) --> \(srtTime(end))\n"
            out += "\(s.speakerLabel(for: seg.speaker)): \(seg.text)\n\n"
        }
        return out
    }

    // MARK: writing / sharing

    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes to a temp file and opens the macOS share sheet (Mail, Nachrichten, …).
    static func share(_ text: String, name: String, from view: NSView?) {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let picker = NSSharingServicePicker(items: [url])
        if let view {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let w = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: w, preferredEdge: .minY)
        }
    }

    // MARK: helpers

    private static func mmss(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
    private static func srtTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func safeFilename(_ s: Session) -> String {
        let base = s.displayTitle.replacingOccurrences(of: "/", with: "-")
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
