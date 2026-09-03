import SwiftUI

/// Input-device picker, bound to AppSettings.micDeviceID. "" = system default.
struct MicPicker: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var mics: MicDevices
    var compact = false

    var body: some View {
        Picker(compact ? "" : "Mikrofon", selection: $settings.micDeviceID) {
            Text("Standard").tag("")
            if !mics.devices.isEmpty { Divider() }
            ForEach(mics.devices) { Text($0.name).tag($0.id) }
            if !settings.micDeviceID.isEmpty
                && !mics.devices.contains(where: { $0.id == settings.micDeviceID }) {
                Text("\(mics.name(for: settings.micDeviceID))").tag(settings.micDeviceID)
            }
        }
        .onAppear { mics.refresh() }
    }
}

/// How many speakers to force in diarisation. 0 = automatic.
struct SpeakerCountPicker: View {
    @Binding var count: Int
    var compact = false

    var body: some View {
        Picker(compact ? "" : "Sprecher", selection: $count) {
            Text("Automatisch").tag(0)
            ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
        }
    }
}
