import AVFoundation
import Combine

/// Records the microphone and, for meetings, the system audio in parallel
/// (SystemAudioCapture) to a second file. The two tracks are mixed on the server.
///
/// The mic path uses AVCaptureSession rather than AVAudioRecorder so a specific
/// input device can be chosen; AVAudioRecorder is stuck with the system default.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var capturedSystemAudio = false

    private let session = AVCaptureSession()
    private let fileOutput = AVCaptureAudioFileOutput()
    private var system: SystemAudioCapture?
    private var ticker: Timer?
    private var startedAt: Date?

    static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// - Parameters:
    ///   - micURL: where the mic track goes
    ///   - systemURL: if non-nil, also capture system audio here (meetings)
    ///   - deviceID: input device uniqueID; "" / unknown = system default
    func start(micURL: URL, systemURL: URL?, deviceID: String = "") async throws {
        try FileManager.default.createDirectory(
            at: micURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: micURL)

        let device = MicDevices.device(for: deviceID) ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            throw RecorderError.couldNotStart
        }

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard session.canAddInput(input) else {
            session.commitConfiguration(); throw RecorderError.couldNotStart
        }
        session.addInput(input)
        guard session.canAddOutput(fileOutput) else {
            session.commitConfiguration(); throw RecorderError.couldNotStart
        }
        session.addOutput(fileOutput)
        session.commitConfiguration()

        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                cont.resume()
            }
        }
        fileOutput.startRecording(to: micURL, outputFileType: .m4a, recordingDelegate: self)

        capturedSystemAudio = false
        if let systemURL {
            let cap = SystemAudioCapture()
            do {
                try await cap.start(to: systemURL)
                system = cap
                capturedSystemAudio = true
            } catch {
                NSLog("system audio unavailable: \(error.localizedDescription)")
            }
        }

        startedAt = .now
        elapsed = 0
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops everything and returns the recorded duration.
    @discardableResult
    func stop() async -> TimeInterval {
        ticker?.invalidate(); ticker = nil
        if fileOutput.isRecording {
            await withCheckedContinuation { cont in
                stopContinuation = cont
                fileOutput.stopRecording()
            }
        }
        session.stopRunning()
        await system?.stop()
        let d = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        system = nil
        isRecording = false
        level = 0
        return d
    }

    private var stopContinuation: CheckedContinuation<Void, Never>?

    private func tick() {
        guard let start = startedAt else { return }
        elapsed = Date().timeIntervalSince(start)
        if let ch = fileOutput.connection(with: .audio)?.audioChannels.first {
            level = max(0, min(1, (ch.averagePowerLevel + 55) / 55))
        }
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Aufnahme konnte nicht gestartet werden." }
    }
}

extension AudioRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            stopContinuation?.resume()
            stopContinuation = nil
        }
    }
}
