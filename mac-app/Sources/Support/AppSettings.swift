import Foundation
import Combine

/// Persisted app settings. Plain UserDefaults-backed so bindings work everywhere.
final class AppSettings: ObservableObject {
    @Published var serverURL: String     { didSet { d.set(serverURL, forKey: "serverURL") } }
    @Published var token: String         { didSet { d.set(token, forKey: "token") } }
    @Published var language: String      { didSet { d.set(language, forKey: "language") } }
    /// "" = let the server decide (config default + auto-fallback)
    @Published var summaryModel: String  { didSet { d.set(summaryModel, forKey: "summaryModel") } }
    /// "off" | "ask" | "auto" — what to do when a calendar meeting starts
    @Published var autoRecordMode: String { didSet { d.set(autoRecordMode, forKey: "autoRecordMode") } }
    /// Colorway.rawValue — swaps the palette, never the layout
    @Published var colorway: String      { didSet { d.set(colorway, forKey: "colorway") } }
    /// Appearance.rawValue — "light" | "dark" | "system"
    @Published var appearance: String    { didSet { d.set(appearance, forKey: "appearance") } }
    /// Interface language: "system" follows macOS, otherwise "de" | "en"
    @Published var uiLanguage: String    { didSet { d.set(uiLanguage, forKey: "uiLanguage") } }

    private let d = UserDefaults.standard

    init() {
        serverURL = d.string(forKey: "serverURL") ?? "http://localhost:8756"
        token = d.string(forKey: "token") ?? ""
        language = d.string(forKey: "language") ?? "de"
        summaryModel = d.string(forKey: "summaryModel") ?? ""
        autoRecordMode = d.string(forKey: "autoRecordMode") ?? "ask"
        colorway = d.string(forKey: "colorway") ?? Colorway.schwefel.rawValue
        appearance = d.string(forKey: "appearance") ?? Appearance.system.rawValue
        uiLanguage = d.string(forKey: "uiLanguage") ?? "system"
    }

    /// nil = follow the system, which is what SwiftUI does with no override.
    var uiLocale: Locale? {
        uiLanguage == "system" ? nil : Locale(identifier: uiLanguage)
    }

    var colorwayValue: Colorway {
        get { Colorway(rawValue: colorway) ?? .schwefel }
        set { colorway = newValue.rawValue }
    }

    var appearanceValue: Appearance {
        get { Appearance(rawValue: appearance) ?? .system }
        set { appearance = newValue.rawValue }
    }

    var baseURL: URL? {
        let t = serverURL.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : URL(string: t)
    }
}
