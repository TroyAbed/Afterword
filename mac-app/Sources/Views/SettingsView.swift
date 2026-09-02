import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transcriber: Transcriber
    @State private var checking = false
    @State private var reachable: Bool?

    @Environment(\.palette) private var palette

    @State private var models: [String] = []
    @State private var effective = ""
    @State private var loadingModels = false

    private var api: ScribeAPI? {
        settings.baseURL.map { ScribeAPI(baseURL: $0, token: settings.token) }
    }

    var body: some View {
        Form {
            Section("Darstellung") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Farbweg").font(Brand.label(12))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)],
                              spacing: 10) {
                        ForEach(Colorway.allCases) { way in
                            ColorwayTile(way: way,
                                         dark: palette.isDark,
                                         selected: settings.colorwayValue == way,
                                         highlight: palette.accent) {
                                settings.colorwayValue = way
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Picker("Erscheinung", selection: Binding(
                    get: { settings.appearanceValue },
                    set: { settings.appearanceValue = $0 })) {
                    ForEach(Appearance.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)


                Text("Der Farbweg tauscht nur Tinte, Papier und Signalfarbe — Layout und Schrift bleiben gleich.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Server (Mac Studio)") {
                TextField("URL", text: $settings.serverURL, prompt: Text("http://localhost:8756"))
                SecureField("Token (optional)", text: $settings.token)
                HStack {
                    Button("Verbindung testen") { check() }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let r = reachable {
                        Label(LocalizedStringKey(r ? "erreichbar" : "nicht erreichbar"),
                              systemImage: r ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r ? .green : .red)
                    }
                }
            }

            Section("Sprache") {
                Picker("Oberfläche", selection: $settings.uiLanguage) {
                    Text("System").tag("system")
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                }

                Picker("Gesprochene Sprache", selection: $settings.language) {
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                    Text("Automatisch").tag("")
                }
                Text("Die Oberfläche wechselt sofort. Die gesprochene Sprache sagt dem Server, was er transkribieren soll.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Kalender") {
                Picker("Wenn ein Meeting beginnt", selection: $settings.autoRecordMode) {
                    Text("Nichts tun").tag("off")
                    Text("Nachfragen").tag("ask")
                    Text("Automatisch aufnehmen").tag("auto")
                }
                Text("Gilt nur für Termine mit Meeting-Link (Zoom, Teams, Meet …). Die Aufnahme stoppt, wenn das Meeting-Fenster verschwindet. Denk daran, die Aufnahme den Teilnehmenden anzusagen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Protokoll-Modell (Ollama)") {
                TextField("Ollama-Server", text: $settings.ollamaURL,
                          prompt: Text("Server-Standard"))
                    .onSubmit { loadModels() }
                Text("Leer = der Afterword-Server nutzt sein eigenes Ollama. Trag hier z.B. http://192.168.1.20:11434 ein, um ein anderes zu verwenden.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Modell", selection: $settings.summaryModel) {
                    Text(effective.isEmpty ? "Automatisch" : "Automatisch (\(effective))").tag("")
                    if !models.isEmpty { Divider() }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                    if !settings.summaryModel.isEmpty && !models.contains(settings.summaryModel) {
                        Text("\(settings.summaryModel) (nicht verfügbar)").tag(settings.summaryModel)
                    }
                }
                HStack {
                    Button("Modelle laden") { loadModels() }.disabled(loadingModels)
                    if loadingModels { ProgressView().controlSize(.small) }
                }
                Text("Automatisch wählt ein installiertes Modell und weicht aus, wenn eins entfernt wird.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Gespeicherte Stimmen") {
                if transcriber.voices.isEmpty {
                    Text("Noch keine. In einer Session bei einem Sprecher den Namen eintragen, dann rechts auf das Sprecher-Symbol → Als Stimme merken.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(transcriber.voices, id: \.name) { v in
                        HStack {
                            Text(v.name)
                            Text("· \(v.samples) Aufnahme\(v.samples == 1 ? "" : "n")")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Letztes Sample entfernen") { transcriber.popVoiceSample(v.name) }
                                    .disabled(v.samples <= 1)
                                Button("Ganze Stimme löschen", role: .destructive) {
                                    transcriber.deleteVoice(v.name)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(palette.paper)
        .frame(width: 460)
        .padding()
        .task { loadModels(); transcriber.loadVoices() }
    }

    private func check() {
        guard let api else { reachable = false; return }
        checking = true; reachable = nil
        Task {
            let ok = (try? await api.health()) ?? false
            reachable = ok; checking = false
            if ok { loadModels() }
        }
    }

    private func loadModels() {
        guard let api, !loadingModels else { return }
        loadingModels = true
        Task {
            if let info = try? await api.models(ollamaURL: settings.ollamaURL) {
                models = info.available
                effective = info.effective
            }
            loadingModels = false
        }
    }
}

/// One entry in the colorway grid: a miniature of the real window, so you see
/// what you get instead of a colour swatch.
private struct ColorwayTile: View {
    let way: Colorway
    let dark: Bool
    let selected: Bool
    let highlight: Color
    var action: () -> Void

    var body: some View {
        let p = way.palette(dark: dark)
        Button(action: action) {
            VStack(spacing: 5) {
                VStack(spacing: 0) {
                    Rectangle().fill(p.side).frame(height: 11)
                    HStack(spacing: 0) {
                        Rectangle().fill(p.side).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(p.ink.opacity(0.55)).frame(width: 42, height: 4)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(p.accent).frame(width: 30, height: 9)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                    }
                }
                .frame(height: 54)
                .background(p.paper)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? highlight : p.ink.opacity(0.18),
                                      lineWidth: selected ? 2.5 : 0.8)
                }

                Text(way.label)
                    .font(Brand.label(10, selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(way.note)
    }
}
