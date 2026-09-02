import Foundation

/// Local library. Each session is a folder under Application Support:
///   Sessions/<uuid>/ { meta.json, audio.m4a, transcript.md, summary.md }
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        root = base.appending(path: "Afterword/Sessions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: paths

    func dir(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    func audioURL(for id: UUID) -> URL {
        dir(for: id).appending(path: "audio.m4a")
    }
    func systemAudioURL(for id: UUID) -> URL {
        dir(for: id).appending(path: "system.m4a")
    }
    func videoURL(for id: UUID) -> URL {
        dir(for: id).appending(path: "video.mp4")
    }

    // MARK: load / save

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Session] = []
        for d in dirs {
            let meta = d.appending(path: "meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let s = try? JSONDecoder.iso.decode(Session.self, from: data)
            else { continue }
            loaded.append(s)
        }
        sessions = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ session: Session) {
        let d = dir(for: session.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(session) {
            try? data.write(to: d.appending(path: "meta.json"))
        }
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: dir(for: session.id))
        sessions.removeAll { $0.id == session.id }
    }

    func session(_ id: UUID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
