import SwiftUI
import AppKit

struct PreferencesView: View {
    @State private var watchFolders: [String] = RepoWatchConfig.watchFolders
    @State private var repos: [String] = RepoWatchConfig.repos
    @State private var intervalMinutes: Double
    @State private var signCommits: Bool
    @State private var signingKey: String

    init() {
        let settings = RepoWatchConfig.readSettings()
        _intervalMinutes = State(initialValue: Double(settings["interval_minutes"] ?? "60") ?? 60)
        _signCommits = State(initialValue: settings["sign_commits"] == "true")
        _signingKey = State(initialValue: settings["signing_key"] ?? "")
    }

    var body: some View {
        Form {
            Section("Carpetas vigiladas (se revisa cada repo adentro)") {
                pathList(watchFolders) { idx in
                    watchFolders.remove(at: idx); save()
                }
                Button("Agregar carpeta…") { addFolder() }
            }

            Section("Repos individuales") {
                pathList(repos) { idx in
                    repos.remove(at: idx); save()
                }
                Button("Agregar repo…") { addRepo() }
            }

            Section("Horario") {
                Stepper("Revisar cada \(Int(intervalMinutes)) min",
                        value: $intervalMinutes, in: 15...1440, step: 15)
                    .onChange(of: intervalMinutes) { _, _ in save() }
            }

            Section("Firma de commits (SSH)") {
                Toggle("Firmar al hacer Commit / Commit + Push", isOn: $signCommits)
                    .onChange(of: signCommits) { _, _ in save() }
                if signCommits {
                    HStack {
                        Text(signingKey.isEmpty ? "(sin llave elegida)" : signingKey)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Elegir…") { chooseSigningKey() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func pathList(_ paths: [String], onRemove: @escaping (Int) -> Void) -> some View {
        if paths.isEmpty {
            Text("(ninguna)").foregroundStyle(.secondary).font(.system(size: 11))
        } else {
            ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                HStack {
                    Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(action: { onRemove(idx) }) {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func save() {
        RepoWatchConfig.watchFolders = watchFolders
        RepoWatchConfig.repos = repos
        RepoWatchConfig.writeSettings([
            "interval_minutes": String(Int(intervalMinutes)),
            "sign_commits": signCommits ? "true" : "false",
            "signing_key": signingKey,
        ])
        NotificationCenter.default.post(name: .repoWatchConfigChanged, object: nil)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            watchFolders.append(url.path)
            save()
        }
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            repos.append(url.path)
            save()
        }
    }

    private func chooseSigningKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            signingKey = url.path
            save()
        }
    }
}
