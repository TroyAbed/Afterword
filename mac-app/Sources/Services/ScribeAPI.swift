import Foundation

struct JobMeta: Decodable {
    let id: String
    let status: String
    let transcript_md: String?
    let summary_md: String?
    let segments: [TranscriptSegment]?
    let speakers_detected: [String]?
    let auto_speakers: [String: String]?
    let detected_language: String?
    let error: String?
}

struct Voice: Decodable, Hashable { let name: String; let samples: Int }

enum ScribeError: LocalizedError {
    case badURL, http(Int, String), server(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "Server-URL ungültig"
        case .http(let c, let b): return "HTTP \(c): \(b)"
        case .server(let m): return m
        }
    }
}

struct ScribeAPI {
    let baseURL: URL
    let token: String

    private func request(_ path: String, method: String = "GET",
                         query: [URLQueryItem] = []) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = query
            url = c.url!
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func decode(_ data: Data, _ resp: URLResponse) throws -> JobMeta {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ScribeError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(JobMeta.self, from: data)
    }

    /// Upload the mic track (and, for meetings, the system-audio track); returns the created job.
    func submit(audio: URL, systemAudio: URL?, kind: SessionKind,
                title: String, language: String,
                summaryModel: String, ollamaURL: String,
                speakerCount: Int, vocab: String) async throws -> JobMeta {
        let boundary = "scribe.\(UUID().uuidString)"
        var req = request("/jobs", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        func file(_ name: String, _ url: URL) throws {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\n")
            body.append("Content-Type: audio/mp4\r\n\r\n")
            body.append(try Data(contentsOf: url))
            body.append("\r\n")
        }
        field("kind", kind == .meeting ? "meeting" : "voicenote")
        field("title", title)
        field("language", language)
        field("summary_model", summaryModel)
        field("ollama_url", ollamaURL)
        field("speaker_count", String(speakerCount))
        field("vocab", vocab)
        try file("audio", audio)
        if let systemAudio, FileManager.default.fileExists(atPath: systemAudio.path) {
            try file("system_audio", systemAudio)
        }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        return try decode(data, resp)
    }

    func job(_ id: String) async throws -> JobMeta {
        let (data, resp) = try await URLSession.shared.data(for: request("/jobs/\(id)"))
        return try decode(data, resp)
    }

    /// Regenerate the summary with speaker names substituted. Returns the new summary markdown.
    func resummarize(jobID: String, speakers: [String: String],
                     summaryModel: String, ollamaURL: String) async throws -> String {
        let boundary = "scribe.\(UUID().uuidString)"
        var req = request("/jobs/\(jobID)/resummarize", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let json = String(data: try JSONEncoder().encode(speakers), encoding: .utf8) ?? "{}"
        var body = Data()
        for (name, value) in [("speakers", json), ("summary_model", summaryModel),
                              ("ollama_url", ollamaURL)] {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ScribeError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct R: Decodable { let summary_md: String }
        return try JSONDecoder().decode(R.self, from: data).summary_md
    }

    func health() async throws -> Bool {
        let (_, resp) = try await URLSession.shared.data(for: request("/health"))
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
    }

    struct Models: Decodable { let available: [String]; let effective: String }
    func models(ollamaURL: String = "") async throws -> Models {
        let q = ollamaURL.isEmpty ? [] : [URLQueryItem(name: "ollama_url", value: ollamaURL)]
        let (data, resp) = try await URLSession.shared.data(for: request("/models", query: q))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ScribeError.http(code, "") }
        return try JSONDecoder().decode(Models.self, from: data)
    }

    // MARK: voice library

    func voices() async throws -> [Voice] {
        let (data, resp) = try await URLSession.shared.data(for: request("/voices"))
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { return [] }
        return (try? JSONDecoder().decode([Voice].self, from: data)) ?? []
    }

    func saveVoice(name: String, jobID: String, speaker: String) async throws {
        let boundary = "scribe.\(UUID().uuidString)"
        var req = request("/voices", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in [("name", name), ("job_id", jobID), ("speaker", speaker)] {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ScribeError.http(code, String(data: d, encoding: .utf8) ?? "")
        }
    }

    func deleteVoice(name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await URLSession.shared.data(for: request("/voices/\(enc)", method: "DELETE"))
    }

    func popVoiceSample(name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await URLSession.shared.data(for: request("/voices/\(enc)/pop", method: "POST"))
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}
