import Foundation
import ScreenCaptureKit

/// Watches the calendar and — depending on the setting — offers or starts a
/// recording when a meeting with a call link begins, then stops it when the
/// meeting window disappears (or the event is well over).
@MainActor
final class MeetingWatcher: ObservableObject {
    /// Set while a meeting is running and the user hasn't decided yet (mode "ask").
    @Published var pending: CalendarEvent?

    let calendar: MeetingCalendar
    private let controller: RecordingController
    private let recorder: AudioRecorder
    private let settings: AppSettings

    private var handled: Set<String> = []
    private var timer: Timer?
    private var autoEvent: CalendarEvent?
    private var watchedWindowID: CGWindowID?
    private var windowGoneSince: Date?

    init(calendar: MeetingCalendar, controller: RecordingController,
         recorder: AudioRecorder, settings: AppSettings) {
        self.calendar = calendar
        self.controller = controller
        self.recorder = recorder
        self.settings = settings
    }

    func start() {
        Task {
            await calendar.requestAccessAndRefresh()
            calendar.startPolling()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard settings.autoRecordMode != "off" else { pending = nil; return }

        if recorder.isRecording {
            if autoEvent != nil { checkAutoStop() }
            return
        }

        guard let e = calendar.current, !handled.contains(e.id) else { return }
        // only real calls — an event without a meeting link is just a calendar block
        guard e.link != nil else { return }

        if settings.autoRecordMode == "auto" {
            handled.insert(e.id)
            Task { await begin(e) }
        } else {
            pending = e
        }
    }

    func accept(_ e: CalendarEvent) {
        handled.insert(e.id)
        pending = nil
        Task { await begin(e) }
    }

    func dismiss(_ e: CalendarEvent) {
        handled.insert(e.id)
        pending = nil
    }

    private func begin(_ e: CalendarEvent) async {
        let windows = await WindowVideoCapture.windows()
        let window = WindowVideoCapture.likelyMeetingWindow(windows)
        watchedWindowID = window?.windowID
        windowGoneSince = nil
        autoEvent = e
        await controller.begin(kind: .meeting, title: e.title,
                               wantsSystemAudio: true, videoWindow: window)
    }

    private func checkAutoStop() {
        guard let e = autoEvent else { return }
        // hard stop well after the scheduled end, in case the window check never fires
        if Date() > e.end.addingTimeInterval(15 * 60) { finishAuto(); return }

        guard let id = watchedWindowID else { return }
        Task {
            let live = Set(await WindowVideoCapture.windows().map(\.windowID))
            if live.contains(id) {
                windowGoneSince = nil
            } else if let since = windowGoneSince {
                if Date().timeIntervalSince(since) > 30 { finishAuto() }
            } else {
                windowGoneSince = Date()
            }
        }
    }

    private func finishAuto() {
        Task {
            _ = await controller.finish()
            autoEvent = nil
            watchedWindowID = nil
            windowGoneSince = nil
        }
    }
}
