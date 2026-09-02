import SwiftUI

@main
struct AfterwordApp: App {
    @StateObject private var store: SessionStore
    @StateObject private var settings: AppSettings
    @StateObject private var transcriber: Transcriber
    @StateObject private var recorder: AudioRecorder
    @StateObject private var controller: RecordingController
    @StateObject private var watcher: MeetingWatcher
    @StateObject private var navigator = Navigator()

    init() {
        let store = SessionStore()
        let settings = AppSettings()
        let transcriber = Transcriber(store: store, settings: settings)
        let recorder = AudioRecorder()
        let controller = RecordingController(store: store, transcriber: transcriber, recorder: recorder)
        let watcher = MeetingWatcher(calendar: MeetingCalendar(), controller: controller,
                                     recorder: recorder, settings: settings)
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _transcriber = StateObject(wrappedValue: transcriber)
        _recorder = StateObject(wrappedValue: recorder)
        _controller = StateObject(wrappedValue: controller)
        _watcher = StateObject(wrappedValue: watcher)
    }

    private func inject<C: View>(_ content: C) -> some View {
        Themed { content }
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(transcriber)
            .environmentObject(recorder)
            .environmentObject(controller)
            .environmentObject(watcher)
            .environmentObject(navigator)
    }

    private var menuBarIcon: String {
        if recorder.isRecording { return "record.circle.fill" }
        if watcher.pending != nil { return "calendar.badge.exclamationmark" }
        return "waveform"
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            inject(ContentView())
                .frame(minWidth: 860, minHeight: 540)
                .task { transcriber.resumePending(); watcher.start() }
        }
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            inject(MenuBarView())
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            inject(SettingsView())
        }
    }
}
