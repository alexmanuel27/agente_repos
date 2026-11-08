import SwiftUI
import AppKit
import ServiceManagement

let brandPurple = Color(red: 0.46, green: 0.36, blue: 0.98)

enum PrefSection: String, CaseIterable, Identifiable {
    case folders, repos, schedule, signing, vault, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folders: return "Carpetas"
        case .repos: return "Repos individuales"
        case .schedule: return "Horario"
        case .signing: return "Firma de commits"
        case .vault: return "Vault"
        case .history: return "Historial"
        }
    }
    var icon: String {
        switch self {
        case .folders: return "folder.fill"
        case .repos: return "arrow.triangle.branch"
        case .schedule: return "timer"
        case .signing: return "signature"
        case .vault: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct PreferencesView: View {
    @State private var selection: PrefSection = .folders
    @State private var watchFolders: [String] = RepoWatchConfig.watchFolders
    @State private var repos: [String] = RepoWatchConfig.repos
    @State private var intervalMinutes: Double
    @State private var signCommits: Bool
    @State private var signingKey: String
    @State private var vaultDir: String
    @State private var vaultRunning = false
    @State private var vaultSummary: String? = RepoWatchConfig.vaultSummary()
    @State private var autosyncRepos: Set<String>
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var historyText: String = ""

    init() {
        let settings = RepoWatchConfig.readSettings()
        _intervalMinutes = State(initialValue: Double(settings["interval_minutes"] ?? "60") ?? 60)
        _signCommits = State(initialValue: settings["sign_commits"] == "true")
        _signingKey = State(initialValue: settings["signing_key"] ?? "")
        _vaultDir = State(initialValue: settings["vault_dir"] ?? "")
        let synced = RepoWatchConfig.readOverrides().filter { $0.value["mode"] == "autosync" }.keys
        _autosyncRepos = State(initialValue: Set(synced))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        switch selection {
                        case .folders: foldersCard
                        case .repos: reposCard
                        case .schedule: scheduleCard
                        case .signing: signingCard
                        case .vault: vaultCard
                        case .history: historyCard
                        }
                    }
                    .id(selection)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.easeInOut(duration: 0.22), value: selection)
        }
        .frame(width: 660, height: 480)
        .background(.regularMaterial)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("RepoWatch")
                    .font(.headline)
            }
            .padding(16)

            ForEach(PrefSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { selection = section }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                        Text(section.title)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == section ? brandPurple.opacity(0.18) : .clear)
                    )
                    .foregroundStyle(selection == section ? brandPurple : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(width: 200)
        .background(.ultraThinMaterial)
    }

    // MARK: Cards

    private var foldersCard: some View {
        card(title: "Carpetas vigiladas", subtitle: "Se revisa cada repo que haya directamente adentro.") {
            pathList(watchFolders, icon: "folder.fill") { path in
                watchFolders.removeAll { $0 == path }; save()
            }
            addButton("Agregar carpeta…") { addFolder() }
        }
    }

    private var reposCard: some View {
        card(title: "Repos individuales", subtitle: "Rutas sueltas, para repos fuera de las carpetas vigiladas. \"Sync\" = commit y push automáticos, sin preguntar, para carpetas de sincronización en vez de proyectos.") {
            pathList(repos, icon: "arrow.triangle.branch", showSyncToggle: true) { path in
                repos.removeAll { $0 == path }; save()
            }
            addButton("Agregar repo…") { addRepo() }
        }
    }

    private var scheduleCard: some View {
        card(title: "Horario", subtitle: "Cada cuánto se revisan todos los repos vigilados.") {
            HStack(spacing: 14) {
                Text("\(Int(intervalMinutes))")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(brandPurple)
                Text("minutos")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $intervalMinutes, in: 15...1440, step: 15)
                    .labelsHidden()
                    .onChange(of: intervalMinutes) { _, _ in save() }
            }
            Button {
                runScript("check_git_repos.sh", args: ["--manual"])
            } label: {
                Label("Revisar ahora", systemImage: "arrow.clockwise")
            }
            .tint(brandPurple)
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            Toggle(isOn: $launchAtLogin) {
                Label("Abrir RepoWatch al iniciar sesión", systemImage: "power")
            }
            .toggleStyle(.switch)
            .tint(brandPurple)
            .onChange(of: launchAtLogin) { _, enabled in
                try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        }
    }

    private var historyCard: some View {
        card(title: "Historial", subtitle: "Últimas líneas del log de actividad.") {
            ScrollView {
                Text(historyText.isEmpty ? "(vacío)" : historyText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 300)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([RepoWatchConfig.logFile])
            } label: {
                Label("Mostrar en Finder", systemImage: "folder")
            }
            .tint(brandPurple)
            .padding(.top, 4)
        }
        .onAppear {
            let text = (try? String(contentsOf: RepoWatchConfig.logFile, encoding: .utf8)) ?? ""
            historyText = text.split(separator: "\n").suffix(200).joined(separator: "\n")
        }
    }

    private var signingCard: some View {
        card(title: "Firma de commits", subtitle: "Se aplica solo al hacer Commit / Commit + Push desde el menú, sin tocar la configuración global de git.") {
            Toggle(isOn: $signCommits) {
                Label("Firmar commits con SSH", systemImage: "checkmark.seal")
            }
            .toggleStyle(.switch)
            .tint(brandPurple)
            .onChange(of: signCommits) { _, _ in save() }

            if signCommits {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(signingKey.isEmpty ? "Sin llave elegida" : (signingKey as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(signingKey.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Elegir…") { chooseSigningKey() }
                        .tint(brandPurple)
                }
                .padding(.top, 4)
            }
        }
    }

    private var vaultCard: some View {
        card(title: "Vault de Obsidian", subtitle: "Elige la carpeta raíz del vault: se revisan todas sus carpetas. En cada revisión archiva Registro largo, completa Inicio.md, enlaza entre sí los índices de cada carpeta y escribe «Mantenimiento del vault.md» con lo demás (enlaces rotos, notas sin enlazar, Fichas largas…). Guarda copia de cada nota que toca en vault_backups. Vacía = desactivado.") {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical").foregroundStyle(.secondary)
                Text(vaultDir.isEmpty ? "Sin carpeta elegida (desactivado)" : vaultDir)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(vaultDir.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !vaultDir.isEmpty {
                    Button("Quitar") { vaultDir = ""; save() }
                }
                Button("Elegir…") { chooseVaultDir() }
                    .tint(brandPurple)
            }
            if !vaultDir.isEmpty && !vaultIsValid {
                Label("Esta carpeta no parece un vault de Obsidian (sin .obsidian ni Inicio.md).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
            }
            if !vaultDir.isEmpty && vaultIsValid {
                HStack(spacing: 10) {
                    Button {
                        vaultRunning = true
                        runScriptAsync("check_vault.sh", args: ["--manual"]) {
                            vaultRunning = false
                            vaultSummary = RepoWatchConfig.vaultSummary()
                        }
                    } label: {
                        Label("Revisar ahora", systemImage: "arrow.clockwise")
                    }
                    .tint(brandPurple)
                    .disabled(vaultRunning)
                    if vaultRunning {
                        ProgressView().controlSize(.small)
                        Text("Revisando el vault y los repos…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir informe") { NSWorkspace.shared.open(RepoWatchConfig.vaultReportFile) }
                        .disabled(vaultRunning || vaultSummary == nil)
                }
                .padding(.top, 4)
                if !vaultRunning, let vaultSummary {
                    Text(vaultSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(
        title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    @ViewBuilder
    private func pathList(
        _ paths: [String], icon: String, showSyncToggle: Bool = false,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        if paths.isEmpty {
            Label("Ninguna todavía", systemImage: "tray")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            VStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Image(systemName: icon).foregroundStyle(brandPurple).frame(width: 16)
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if showSyncToggle {
                            syncModeMenu(for: path)
                        }
                        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { onRemove(path) } }) {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
    }

    private func syncModeMenu(for path: String) -> some View {
        let isSync = autosyncRepos.contains(path)
        return Menu {
            Button("Proyecto (revisar antes de commitear)") { setSyncMode(path, autosync: false) }
            Button("Carpeta de sincronización (commit + push automático)") { setSyncMode(path, autosync: true) }
        } label: {
            Text(isSync ? "Sync" : "Proyecto")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(isSync ? brandPurple.opacity(0.2) : Color.primary.opacity(0.08)))
                .foregroundStyle(isSync ? brandPurple : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setSyncMode(_ path: String, autosync: Bool) {
        RepoWatchConfig.setSyncPreset(path, autosync: autosync)
        if autosync { autosyncRepos.insert(path) } else { autosyncRepos.remove(path) }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .tint(brandPurple)
        .padding(.top, 4)
    }

    private func save() {
        RepoWatchConfig.watchFolders = watchFolders
        RepoWatchConfig.repos = repos
        RepoWatchConfig.writeSettings([
            "interval_minutes": String(Int(intervalMinutes)),
            "sign_commits": signCommits ? "true" : "false",
            "signing_key": signingKey,
            "vault_dir": vaultDir,
        ])
        NotificationCenter.default.post(name: .repoWatchConfigChanged, object: nil)
    }

    private func showValidationAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if watchFolders.contains(url.path) {
            showValidationAlert("Esa carpeta ya está en la lista.")
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { watchFolders.append(url.path) }
        save()
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if repos.contains(url.path) {
            showValidationAlert("Ese repo ya está en la lista.")
            return
        }
        var isDir: ObjCBool = false
        let gitPath = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            showValidationAlert("\"\(url.lastPathComponent)\" no parece un repo git (no tiene .git adentro).")
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { repos.append(url.path) }
        save()
    }

    private var vaultIsValid: Bool { RepoWatchConfig.isVaultFolder(vaultDir) }

    private func chooseVaultDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard RepoWatchConfig.isVaultFolder(url.path) else {
            showValidationAlert("\"\(url.lastPathComponent)\" no parece un vault de Obsidian (sin .obsidian ni Inicio.md). Elige la carpeta raíz del vault.")
            return
        }
        vaultDir = url.path
        save()
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
