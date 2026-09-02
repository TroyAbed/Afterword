import Foundation

/// Drives one session from a local recording to a finished transcript:
/// upload → poll every few seconds → store results.
@MainActor
final class Transcriber: ObservableObject {
    let store: SessionStore
    let settings: AppSettings

    init(store: SessionStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    private var api: ScribeAPI? {
        guard let url = settings.baseURL else { return nil }
        return ScribeAPI(baseURL: url, token: settings.token)
    }

    /// Register a just-finished recording and kick off processing.
    func startProcessing(_ session: Session) {
        var s = session
        s.status = .uploading
        store.save(s)
        Task { await run(s.id) }
    }

    /// Sessions whose summary is currently being regenerated with speaker names.
    @Published private(set) var resummarizing: Set<UUID> = []

    // MARK: voice library

    @Published private(set) var voices: [Voice] = []

    func loadVoices() {
        guard let api else { return }
        Task { voices = (try? await api.voices()) ?? voices }
    }

    /// Label `speaker` in `session` as `name` and save that voice sample so future
    /// meetings recognise it.
    func rememberVoice(name: String, sessionID: UUID, speaker: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let api,
              var s = store.session(sessionID), let jid = s.serverJobID else { return }
        s.speakerNames[speaker] = trimmed
        store.save(s)
        Task {
            try? await api.saveVoice(name: trimmed, jobID: jid, speaker: speaker)
            voices = (try? await api.voices()) ?? voices
        }
    }

    func deleteVoice(_ name: String) {
        guard let api else { return }
        Task {
            try? await api.deleteVoice(name: name)
            voices = (try? await api.voices()) ?? voices
        }
    }

    func popVoiceSample(_ name: String) {
        guard let api else { return }
        Task {
            try? await api.popVoiceSample(name: name)
            voices = (try? await api.voices()) ?? voices
        }
    }

    /// Ask the server to regenerate the summary (optionally with speaker names
    /// baked in). Used by the manual "Neu erstellen" button.
    func resummarize(_ id: UUID) {
        guard let s = store.session(id),
              let jid = s.serverJobID,
              !resummarizing.contains(id),
              let api
        else { return }
        resummarizing.insert(id)
        Task {
            defer { resummarizing.remove(id) }
            do {
                let summary = try await api.resummarize(
                    jobID: jid, speakers: s.speakerNames,
                    summaryModel: settings.summaryModel, ollamaURL: settings.ollamaURL)
                guard var cur = store.session(id) else { return }
                cur.summaryMarkdown = summary
                if cur.status == .error {          // summary was the only thing missing
                    cur.status = .done
                    cur.errorMessage = nil
                }
                store.save(cur)
            } catch {
                // keep the previous state
            }
        }
    }

    /// Retry a failed/interrupted session.
    func retry(_ id: UUID) {
        guard var s = store.session(id) else { return }
        s.status = .uploading
        s.errorMessage = nil
        store.save(s)
        Task { await run(id) }
    }

    /// Sessions currently being worked on, so the sweeper doesn't start a second run.
    private var running: Set<UUID> = []

    private func run(_ id: UUID) async {
        guard !running.contains(id) else { return }
        running.insert(id)
        defer { running.remove(id) }

        var attempt = 0
        while true {
            let done = await attemptRun(id)
            if done { return }
            attempt += 1
            if attempt > 200 { await fail(id, "Server dauerhaft nicht erreichbar"); return }
            // keep it queued and try again — the Studio may just be asleep
            if var s = store.session(id) {
                s.errorMessage = "Warte auf den Server … (Versuch \(attempt))"
                store.save(s)
            }
            try? await Task.sleep(for: .seconds(min(60, 5 * Double(attempt))))
        }
    }

    /// One attempt. Returns true when finished (or permanently failed).
    private func attemptRun(_ id: UUID) async -> Bool {
        guard let api else { await fail(id, "Server-URL in den Einstellungen fehlt"); return true }
        guard var s = store.session(id) else { return true }
        let audio = store.audioURL(for: id)

        do {
            let sysURL = s.hasSystemAudio ? store.systemAudioURL(for: id) : nil
            let created = try await api.submit(
                audio: audio, systemAudio: sysURL, kind: s.kind,
                title: s.title, language: settings.language,
                summaryModel: settings.summaryModel, ollamaURL: settings.ollamaURL)
            s.serverJobID = created.id
            s.status = .processing
            store.save(s)

            while true {
                try await Task.sleep(for: .seconds(4))
                let job = try await api.job(created.id)
                switch job.status {
                case "transcribed":
                    // phase 1 done — show the transcript, keep polling for the summary
                    guard var cur = store.session(id) else { return true }
                    cur.transcriptMarkdown = job.transcript_md
                    cur.segments = job.segments ?? []
                    cur.speakers = job.speakers_detected ?? []
                    cur.language = job.detected_language
                    if cur.speakerNames.isEmpty, let auto = job.auto_speakers, !auto.isEmpty {
                        cur.speakerNames = auto          // recognised voices
                    }
                    if cur.status != .transcribed { cur.status = .transcribed }
                    store.save(cur)
                    s = cur
                case "done":
                    s.transcriptMarkdown = job.transcript_md
                    s.summaryMarkdown = job.summary_md
                    s.segments = job.segments ?? []
                    s.speakers = job.speakers_detected ?? []
                    s.language = job.detected_language
                    if s.speakerNames.isEmpty, let auto = job.auto_speakers, !auto.isEmpty {
                        s.speakerNames = auto
                    }
                    s.status = .done
                    s.errorMessage = nil
                    store.save(s)
                    return true
                case "error":
                    await fail(id, job.error ?? "Unbekannter Fehler auf dem Server")
                    return true
                default:
                    continue   // queued / running
                }
            }
        } catch let e as ScribeError {
            if case .http(let code, let body) = e, (400..<500).contains(code) {
                await fail(id, "HTTP \(code): \(body)")   // our bug, retrying won't help
                return true
            }
            return false                                   // 5xx — try again later
        } catch is CancellationError {
            return true
        } catch {
            return false                                   // network / server asleep
        }
    }

    private func fail(_ id: UUID, _ message: String) async {
        guard var s = store.session(id) else { return }
        s.status = .error
        s.errorMessage = message
        store.save(s)
    }

    /// Resume anything left mid-flight, and keep sweeping so a session that
    /// couldn't reach the Studio gets picked up as soon as it's back.
    func resumePending() {
        sweep()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    private func sweep() {
        for s in store.sessions where s.status.isBusy && !running.contains(s.id) {
            Task { await run(s.id) }
        }
    }
}
