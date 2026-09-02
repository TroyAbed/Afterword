import Foundation

enum SessionKind: String, Codable, CaseIterable {
    case meeting, voiceNote
    var label: String { self == .meeting ? "Meeting" : "Voice Note" }
    var symbol: String { self == .meeting ? "person.2.wave.2" : "mic" }
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    let start: Double?
    let end: Double?
    let text: String
    let speaker: String?

    var id: String { "\(start ?? -1)-\(text.hashValue)" }
    var startTime: Double { start ?? 0 }

    func contains(_ t: Double) -> Bool {
        guard let start else { return false }
        return t >= start && t < (end ?? start + 4)
    }
}

enum SessionStatus: String, Codable {
    case recording, uploading, processing, transcribed, done, error

    var label: String {
        switch self {
        case .recording:   return "Aufnahme"
        case .uploading:    return "Hochladen"
        case .processing:   return "Transkribieren"
        case .transcribed:  return "Protokoll läuft"
        case .done:         return "Fertig"
        case .error:        return "Fehler"
        }
    }
    /// still working on something
    var isBusy: Bool { self == .uploading || self == .processing || self == .transcribed }
    /// transcript is available to read
    var hasTranscript: Bool { self == .transcribed || self == .done }
}

struct Session: Codable, Identifiable, Hashable {
    let id: UUID
    var kind: SessionKind
    var title: String
    var createdAt: Date
    var duration: TimeInterval?

    var status: SessionStatus
    var hasSystemAudio: Bool = false
    var hasVideo: Bool = false
    /// seconds from the start of the recording where you pressed "merken"
    var markers: [TimeInterval] = []
    var serverJobID: String?
    var transcriptMarkdown: String?
    var summaryMarkdown: String?
    var segments: [TranscriptSegment]
    var speakers: [String]                 // detected, e.g. ["SPEAKER_00", "SPEAKER_01"]
    var speakerNames: [String: String]     // SPEAKER_00 -> "Thomas"
    var language: String?
    var errorMessage: String?

    init(kind: SessionKind, title: String = "") {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.createdAt = .now
        self.status = .recording
        self.segments = []
        self.speakers = []
        self.speakerNames = [:]
    }

    func speakerLabel(for tag: String?) -> String {
        guard let tag else { return "Unbekannt" }
        return speakerNames[tag].flatMap { $0.isEmpty ? nil : $0 } ?? tag
    }

    /// Consecutive segments from the same speaker, grouped for display.
    var speakerGroups: [(speaker: String?, segments: [TranscriptSegment])] {
        var groups: [(String?, [TranscriptSegment])] = []
        for seg in segments {
            if var last = groups.last, last.0 == seg.speaker {
                last.1.append(seg)
                groups[groups.count - 1] = last
            } else {
                groups.append((seg.speaker, [seg]))
            }
        }
        return groups.map { (speaker: $0.0, segments: $0.1) }
    }

    var displayTitle: String {
        title.isEmpty ? Self.dateFormatter.string(from: createdAt) : title
    }

    // MARK: Codable — lenient about fields added after a session was already saved.
    // A default synthesized decoder would fail (and silently drop) any session
    // stored before a newer field like `hasSystemAudio` existed.

    enum CodingKeys: String, CodingKey {
        case id, kind, title, createdAt, duration, status, hasSystemAudio, hasVideo,
             markers, serverJobID, transcriptMarkdown, summaryMarkdown, segments,
             speakers, speakerNames, language, errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .voiceNote
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        status = try c.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .done
        hasSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        markers = try c.decodeIfPresent([TimeInterval].self, forKey: .markers) ?? []
        serverJobID = try c.decodeIfPresent(String.self, forKey: .serverJobID)
        transcriptMarkdown = try c.decodeIfPresent(String.self, forKey: .transcriptMarkdown)
        summaryMarkdown = try c.decodeIfPresent(String.self, forKey: .summaryMarkdown)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        language = try c.decodeIfPresent(String.self, forKey: .language)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(status, forKey: .status)
        try c.encode(hasSystemAudio, forKey: .hasSystemAudio)
        try c.encode(hasVideo, forKey: .hasVideo)
        try c.encode(markers, forKey: .markers)
        try c.encodeIfPresent(serverJobID, forKey: .serverJobID)
        try c.encodeIfPresent(transcriptMarkdown, forKey: .transcriptMarkdown)
        try c.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
        try c.encode(segments, forKey: .segments)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(speakerNames, forKey: .speakerNames)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    /// Transcript with SPEAKER_xx swapped for the names the user set.
    var renderedTranscript: String {
        Self.applySpeakerNames(to: transcriptMarkdown ?? "", names: speakerNames)
    }

    /// Summary with the SPEAKER_xx placeholders swapped for the names the user set —
    /// done locally on every render, so renaming is instant (no LLM re-run).
    var renderedSummary: String {
        Self.applySpeakerNames(to: summaryMarkdown ?? "", names: speakerNames)
    }

    static func applySpeakerNames(to text: String, names: [String: String]) -> String {
        var out = text
        for (tag, name) in names where !name.isEmpty {
            out = out.replacingOccurrences(of: "**\(tag)**", with: "**\(name)**")   // transcript headers
            out = out.replacingOccurrences(of: tag, with: name)                     // prose in the summary
        }
        // any speaker the user didn't name: SPEAKER_03 -> "Sprecher 4"
        for i in 0..<12 {
            let tag = String(format: "SPEAKER_%02d", i)
            if out.contains(tag) {
                out = out.replacingOccurrences(of: tag, with: "Sprecher \(i + 1)")
            }
        }
        return out
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_CH")
        return f
    }()
}
