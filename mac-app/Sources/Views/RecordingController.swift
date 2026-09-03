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

    /// Set by the app so begin() can read the chosen input device + speaker count.
    var settings: AppSettings?

    init(store: SessionStore, transcriber: Transcriber, recorder: AudioRecorder) {
        self.store = store
        self.transcriber = transcriber
        self.recorder = recorder
    }

    func begin(kind: SessionKind, title: String, wantsSystemAudio: Bool,
               speakerCount: Int = 0, videoWindow: SCWindow? = nil) async {
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
        s.speakerCount = speakerCount
        store.save(s)
        activeSession = s

        do {
            try await recorder.start(
                micURL: store.audioURL(for: s.id),
                systemURL: useSystem ? store.systemAudioURL(for: s.id) : nil,
                deviceID: settings?.micDeviceID ?? "")
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

    /// Bring an existing audio or video file into the library and transcribe it.
    /// A video file is kept as the session's video track too, so it plays back.
    func importFile(_ url: URL, kind: SessionKind, title: String, speakerCount: Int) {
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        var s = Session(kind: kind, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title)
        s.speakerCount = speakerCount
        s.status = .uploading
        store.save(s)
        do {
            try FileManager.default.createDirectory(at: store.dir(for: s.id), withIntermediateDirectories: true)
            let dest = isVideo ? store.videoURL(for: s.id) : store.audioURL(for: s.id)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            s.hasVideo = isVideo
            store.save(s)
        } catch {
            s.status = .error
            s.errorMessage = "Datei konnte nicht importiert werden: \(error.localizedDescription)"
            store.save(s)
            return
        }
        transcriber.startProcessing(s)
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
