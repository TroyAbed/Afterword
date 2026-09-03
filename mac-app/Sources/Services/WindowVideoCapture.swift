import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Records one window's video (no audio) to an .mp4 via ScreenCaptureKit.
/// Needs the Screen Recording permission (same TCC grant as SystemAudioCapture).
final class WindowVideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var started = false
    private let queue = DispatchQueue(label: "afterword.window-video")

    /// Hard ceiling on the video file. Beyond this the video stops (audio keeps
    /// going) — a long meeting should never leave a multi-GB file behind.
    static let maxBytes: Int64 = 4_000_000_000
    private var outURL: URL?
    private var videoDone = false
    private var lastSizeCheck = Date.distantPast

    /// live low-fps frames for a recording-time preview
    var onPreview: ((CGImage) -> Void)?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPreview = Date.distantPast

    /// On-screen, titled windows the user could record.
    static func windows() async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true) else { return [] }
        return content.windows
            .filter { ($0.title?.isEmpty == false) && $0.frame.width > 200 && $0.frame.height > 150 }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
    }

    /// Best guess at which of these windows is the actual call — by owning app
    /// and window title, the way desktop notetakers do it.
    static func likelyMeetingWindow(_ windows: [SCWindow]) -> SCWindow? {
        windows.map { ($0, meetingScore($0)) }
            .filter { $0.1 >= 40 }
            .max { $0.1 < $1.1 }?.0
    }

    static func meetingScore(_ w: SCWindow) -> Int {
        let bundle = (w.owningApplication?.bundleIdentifier ?? "").lowercased()
        let title = (w.title ?? "").lowercased()
        var s = 0

        if bundle.contains("zoom") {
            s += 30
            if title.contains("meeting") || title.contains("webinar") { s += 50 }
            // the main "Zoom Workplace" window is not the call
            if title.isEmpty || title.contains("workplace") || title == "zoom" { s -= 60 }
        }
        if bundle.contains("teams") {
            s += 25
            if title.contains("besprechung") || title.contains("meeting")
                || title.contains("call") || title.contains("anruf") { s += 45 }
        }
        if bundle.contains("webex") { s += 55 }
        if bundle.contains("slack") && title.contains("huddle") { s += 55 }
        if bundle.contains("discord") && title.contains("voice") { s += 40 }

        // meetings running in a browser tab
        if ["chrome", "safari", "edge", "arc", "firefox", "brave"].contains(where: bundle.contains) {
            if title.contains("meet.google") || title.contains("google meet") { s += 65 }
            if title.contains("zoom.us") || title.contains("teams.microsoft") { s += 50 }
            if title.contains("whereby") || title.contains("jitsi") || title.contains("gather") { s += 45 }
        }

        if w.frame.width > 800 { s += 5 }
        return s
    }

    /// A still frame of a window, for the picker preview.
    static func thumbnail(of window: SCWindow) async -> NSImage? {
        let cfg = SCStreamConfiguration()
        let scale = window.frame.width > 640 ? 640 / window.frame.width : 1
        cfg.width = max(Int(window.frame.width * scale), 2)
        cfg.height = max(Int(window.frame.height * scale), 2)
        cfg.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: cfg) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cfg.width, height: cfg.height))
    }

    func start(window: SCWindow, to url: URL, quality: VideoQuality = .standard) async throws {
        try? FileManager.default.removeItem(at: url)
        outURL = url
        videoDone = false

        let cap = quality.widthCap
        let scale = window.frame.width > cap ? cap / window.frame.width : 1.0
        let w = max(Int(window.frame.width * scale) & ~1, 2)
        let h = max(Int(window.frame.height * scale) & ~1, 2)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: quality.fps)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let useHEVC = (AVAssetExportSession.allExportPresets()
            .contains(AVAssetExportPresetHEVCHighestQuality))
        let aw = try AVAssetWriter(url: url, fileType: .mp4)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(Int(Double(w * h) * 2.0), quality.bitrate),
                AVVideoMaxKeyFrameIntervalKey: Int(quality.fps) * 4,
            ],
        ])
        vin.expectsMediaDataInRealTime = true
        aw.add(vin)
        writer = aw
        videoInput = vin
        started = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        if let writer, writer.status == .writing {
            videoInput?.markAsFinished()
            await writer.finishWriting()
        }
        writer = nil
        videoInput = nil
        started = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let writer, let videoInput else { return }

        // skip frames flagged as non-complete (occluded / idle)
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attach.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if !videoDone && videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }

        // stop the video (not the audio) if the file gets out of hand
        if !videoDone, Date().timeIntervalSince(lastSizeCheck) > 10 {
            lastSizeCheck = Date()
            if let outURL,
               let size = try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64,
               size > Self.maxBytes {
                NSLog("WindowVideoCapture: hit \(Self.maxBytes) B cap, stopping video")
                videoDone = true
                videoInput.markAsFinished()
            }
        }

        if let onPreview, Date().timeIntervalSince(lastPreview) > 0.33,
           let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastPreview = Date()
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                DispatchQueue.main.async { onPreview(cg) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("WindowVideoCapture stopped: \(error.localizedDescription)")
    }
}
