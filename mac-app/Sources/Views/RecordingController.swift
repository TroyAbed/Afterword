import Foundation
import ScreenCaptureKit

/// Shared start/stop/cancel logic so both the recording sheet and the menu bar
/// drive the same recording and stay in sync.
@MainActor
final class RecordingController: ObservableObject {
    let store: SessionStore
    let transcriber: Transcriber
    let recorder: AudioRecorder

    @Published var notice: String?
    @Published private(set) var recordingVideo = false
    @Published var previewFrame: CGImage?
    /// timestamps you flagged while recording
    @Published private(set) var markers: [TimeInterval] = []
    private var activeSession: Session?
    private var videoCapture: WindowVideoCapture?

    init(store: SessionStore, transcriber: Transcriber, recorder: AudioRecorder) {
        self.store = store
        self.transcriber = transcriber
        self.recorder = recorder
    }

    func begin(kind: SessionKind, title: String, wantsSystemAudio: Bool,
               videoWindow: SCWindow? = nil) async {
        notice = nil
        guard await AudioRecorder.requestMicPermission() else {
            notice = "Mikrofonzugriff verweigert – in den Systemeinstellungen erlauben."
            return
        }
        let useSystem = kind == .meeting && wantsSystemAudio
        if (useSystem || videoWindow != nil), await !SystemAudioCapture.hasPermission() {
            notice = "Für Systemton / Video die Bildschirmaufnahme erlauben (Systemeinstellungen → "
                   + "Datenschutz), dann die App neu starten."
        }

        var s = Session(kind: kind, title: title)
        s.status = .recording
        store.save(s)
        activeSession = s

        do {
            try await recorder.start(
                micURL: store.audioURL(for: s.id),
                systemURL: useSystem ? store.systemAudioURL(for: s.id) : nil)
        } catch {
            notice = error.localizedDescription
            store.delete(s)
            activeSession = nil
            return
        }

        recordingVideo = false
        previewFrame = nil
        markers = []
        if let videoWindow {
            let cap = WindowVideoCapture()
            cap.onPreview = { [weak self] img in self?.previewFrame = img }
            do {
                try await cap.start(window: videoWindow, to: store.videoURL(for: s.id))
                videoCapture = cap
                recordingVideo = true
            } catch {
                NSLog("video capture failed: \(error.localizedDescription)")
                notice = "Video konnte nicht aufgenommen werden – Audio läuft weiter."
            }
        }
    }

    /// Flag the current moment — jumpable in the transcript afterwards.
    func addMarker() {
        guard recorder.isRecording else { return }
        markers.append(recorder.elapsed)
    }

    /// Stops, uploads, returns the finished session's id.
    @discardableResult
    func finish() async -> UUID? {
        let duration = await recorder.stop()
        await videoCapture?.stop()
        let gotVideo = recordingVideo
        videoCapture = nil
        recordingVideo = false
        previewFrame = nil

        guard var s = activeSession else { return nil }
        s.duration = duration
        s.markers = markers
        markers = []
        s.hasSystemAudio = recorder.capturedSystemAudio
        s.hasVideo = gotVideo
            && FileManager.default.fileExists(atPath: store.videoURL(for: s.id).path)
        s.status = .uploading
        store.save(s)
        transcriber.startProcessing(s)
        activeSession = nil
        return s.id
    }

    func cancel() async {
        if recorder.isRecording { _ = await recorder.stop() }
        await videoCapture?.stop()
        videoCapture = nil
        recordingVideo = false
        previewFrame = nil
        if let s = activeSession { store.delete(s) }
        activeSession = nil
    }
}
