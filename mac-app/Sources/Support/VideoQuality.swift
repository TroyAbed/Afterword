import CoreGraphics

/// Presets for the meeting-window recording. Set a default in Settings; override
/// per recording — screen-sharing needs legible text, a talking-heads call does
/// not. Even the top preset stays well under ~1.2 GB/h, and WindowVideoCapture
/// hard-stops the video at `WindowVideoCapture.maxBytes` regardless.
enum VideoQuality: String, CaseIterable, Identifiable {
    case sparsam, standard, bildschirm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sparsam:    return "Sparsam"
        case .standard:   return "Standard"
        case .bildschirm: return "Bildschirm"
        }
    }

    var detail: String {
        switch self {
        case .sparsam:    return "854 px · 5 fps · ~200 MB/h — reicht für Gesichter"
        case .standard:   return "1280 px · 10 fps · ~550 MB/h"
        case .bildschirm: return "1600 px · 10 fps · ~1,1 GB/h — Text bleibt scharf"
        }
    }

    var widthCap: CGFloat {
        switch self {
        case .sparsam:    return 854
        case .standard:   return 1280
        case .bildschirm: return 1600
        }
    }

    var fps: Int32 {
        switch self {
        case .sparsam:    return 5
        case .standard:   return 10
        case .bildschirm: return 10
        }
    }

    /// average bitrate ceiling; the encoder also scales with pixel count
    var bitrate: Int {
        switch self {
        case .sparsam:    return 500_000
        case .standard:   return 1_500_000
        case .bildschirm: return 3_000_000
        }
    }
}
