import AVFoundation
import Combine

/// Records the microphone (AVAudioRecorder) and, for meetings, the system audio
/// in parallel (SystemAudioCapture) to a second file. The two tracks are mixed
/// on the server.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var capturedSystemAudio = false

    private var mic: AVAudioRecorder?
    private var system: SystemAudioCapture?
    private var ticker: Timer?
    private var startedAt: Date?

    static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// - Parameters:
    ///   - micURL: where the mic track goes
    ///   - systemURL: if non-nil, also capture system audio here (meetings)
    func start(micURL: URL, systemURL: URL?) async throws {
        try FileManager.default.createDirectory(
            at: micURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: micURL, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderError.couldNotStart }
        mic = rec

        capturedSystemAudio = false
        if let systemURL {
            let cap = SystemAudioCapture()
            do {
                try await cap.start(to: systemURL)
                system = cap
                capturedSystemAudio = true
            } catch {
                // fall back to mic-only rather than failing the whole recording
                NSLog("system audio unavailable: \(error.localizedDescription)")
            }
        }

        startedAt = .now
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops everything and returns the recorded duration.
    @discardableResult
    func stop() async -> TimeInterval {
        ticker?.invalidate(); ticker = nil
        mic?.stop()
        await system?.stop()
        let d = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        mic = nil; system = nil
        isRecording = false
        level = 0
        return d
    }

    private func tick() {
        guard let rec = mic, let start = startedAt else { return }
        elapsed = Date().timeIntervalSince(start)
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 55) / 55))
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Aufnahme konnte nicht gestartet werden." }
    }
}
