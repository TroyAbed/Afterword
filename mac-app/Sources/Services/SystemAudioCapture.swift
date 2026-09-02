import AVFoundation
import ScreenCaptureKit

/// Captures system / other-apps audio via ScreenCaptureKit and writes it to a file.
/// Our own output is excluded. Needs the "Screen Recording" permission (TCC).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "afterword.system-audio")

    enum CaptureError: LocalizedError {
        case noDisplay, notPermitted
        var errorDescription: String? {
            switch self {
            case .noDisplay:    return "Kein Bildschirm gefunden."
            case .notPermitted: return "Bildschirmaufnahme nicht erlaubt (Systemeinstellungen → Datenschutz)."
            }
        }
    }

    /// True if we can enumerate shareable content (i.e. permission is granted).
    static func hasPermission() async -> Bool {
        do { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); return true }
        catch { return false }
    }

    func start(to url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.notPermitted
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        // a minimal video plane is still required for the stream to run
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 6)
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)   // no-op sink

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)

        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        file = nil          // finalises the file
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let file,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = sampleBuffer.pcmBuffer else { return }
        try? file.write(from: pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudioCapture stopped: \(error.localizedDescription)")
    }
}

private extension CMSampleBuffer {
    /// Copy the audio payload into an AVAudioPCMBuffer matching the buffer's own format.
    var pcmBuffer: AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
