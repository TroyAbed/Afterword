import AVFoundation
import Combine

/// The available audio input devices, for the microphone pickers.
@MainActor
final class MicDevices: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String        // AVCaptureDevice.uniqueID
        let name: String
    }

    @Published private(set) var devices: [Device] = []

    init() { refresh() }

    func refresh() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        devices = found.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Name for a stored id, or a hint that it's gone.
    func name(for id: String) -> String {
        guard !id.isEmpty else { return "" }
        return devices.first { $0.id == id }?.name ?? "nicht verbunden"
    }

    static func device(for id: String) -> AVCaptureDevice? {
        id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)
    }
}
