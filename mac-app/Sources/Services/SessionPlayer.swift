import AVFoundation
import Combine

/// Plays a session. Everything (video track if present + every audio track) is
/// assembled into one AVMutableComposition and played by a single AVPlayer, so
/// picture and all audio stay in sync. Public API is unchanged for the views.
@MainActor
final class SessionPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var hasVideo = false

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: Any?
    private var loadToken = 0

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
    }

    /// - Parameters:
    ///   - audioURLs: mic + system tracks (any that exist)
    ///   - videoURL: local screen recording, if any
    func load(audioURLs: [URL], videoURL: URL?) {
        stop()
        loadToken &+= 1
        let token = loadToken
        let audio = audioURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        let video = videoURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        Task.detached(priority: .userInitiated) {
            let comp = AVMutableComposition()
            var maxDur = CMTime.zero

            if let video {
                let asset = AVURLAsset(url: video)
                if let vt = try? await asset.loadTracks(withMediaType: .video).first,
                   let dur = try? await asset.load(.duration),
                   let track = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
                    maxDur = max(maxDur, dur)
                }
            }
            for url in audio {
                let asset = AVURLAsset(url: url)
                if let at = try? await asset.loadTracks(withMediaType: .audio).first,
                   let dur = try? await asset.load(.duration),
                   let track = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
                    maxDur = max(maxDur, dur)
                }
            }
            await self.adopt(composition: comp, duration: maxDur, hasVideo: video != nil, token: token)
        }
    }

    private func adopt(composition: AVMutableComposition, duration dur: CMTime,
                       hasVideo: Bool, token: Int) {
        guard token == loadToken else { return }
        let item = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: item)
        duration = dur.seconds.isFinite ? dur.seconds : 0
        self.hasVideo = hasVideo
        currentTime = 0
        addObservers(for: item)
    }

    private func addObservers(for item: AVPlayerItem) {
        removeObservers()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.player.seek(to: .zero)
                self?.isPlaying = false
                self?.currentTime = 0
            }
        }
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
    }

    // MARK: transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let t = max(0, min(time, duration))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: TimeInterval) { seek(to: currentTime + seconds) }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        isPlaying = false
        currentTime = 0
        duration = 0
        hasVideo = false
    }
}
