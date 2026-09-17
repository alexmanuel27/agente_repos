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
        VStack(spacing: 0) {
            header

            Form {
                Section {
                    pathList(watchFolders, icon: "folder.fill") { idx in
                        watchFolders.remove(at: idx); save()
                    }
                    Button { addFolder() } label: {
                        Label("Agregar carpeta…", systemImage: "plus")
                    }
                } header: {
                    Label("Carpetas vigiladas", systemImage: "folder")
                } footer: {
                    Text("Se revisa cada repo que haya directamente adentro.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    pathList(repos, icon: "arrow.triangle.branch") { idx in
                        repos.remove(at: idx); save()
                    }
                    Button { addRepo() } label: {
                        Label("Agregar repo…", systemImage: "plus")
                    }
                } header: {
                    Label("Repos individuales", systemImage: "shippingbox")
                }

                Section {
                    HStack {
                        Label("Revisar cada", systemImage: "clock")
                        Spacer()
                        Text("\(Int(intervalMinutes)) min")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(.tint)
                        Stepper("", value: $intervalMinutes, in: 15...1440, step: 15)
                            .labelsHidden()
                            .onChange(of: intervalMinutes) { _, _ in save() }
                    }
                } header: {
                    Label("Horario", systemImage: "timer")
                }

                Section {
                    Toggle(isOn: $signCommits) {
                        Label("Firmar commits con SSH", systemImage: "checkmark.seal")
                    }
                    .onChange(of: signCommits) { _, _ in save() }

                    if signCommits {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary)
                            Text(signingKey.isEmpty ? "Sin llave elegida" : (signingKey as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(signingKey.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Elegir…") { chooseSigningKey() }
                        }
                    }
                } header: {
                    Label("Firma de commits", systemImage: "signature")
                } footer: {
                    Text("Se aplica solo al hacer Commit / Commit + Push desde el menú, sin tocar la configuración global de git.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("RepoWatch")
                    .font(.title2.bold())
                Text("Vigilante de repos git")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func pathList(_ paths: [String], icon: String, onRemove: @escaping (Int) -> Void) -> some View {
        if paths.isEmpty {
            Label("Ninguna todavía", systemImage: "tray")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: { onRemove(idx) }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
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
