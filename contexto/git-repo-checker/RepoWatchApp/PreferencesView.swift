import SwiftUI
import AppKit

let brandPurple = Color(red: 0.46, green: 0.36, blue: 0.98)

enum PrefSection: String, CaseIterable, Identifiable {
    case folders, repos, schedule, signing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folders: return "Carpetas"
        case .repos: return "Repos individuales"
        case .schedule: return "Horario"
        case .signing: return "Firma de commits"
        }
    }
    var icon: String {
        switch self {
        case .folders: return "folder.fill"
        case .repos: return "arrow.triangle.branch"
        case .schedule: return "timer"
        case .signing: return "signature"
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

    init() {
        let settings = RepoWatchConfig.readSettings()
        _intervalMinutes = State(initialValue: Double(settings["interval_minutes"] ?? "60") ?? 60)
        _signCommits = State(initialValue: settings["sign_commits"] == "true")
        _signingKey = State(initialValue: settings["signing_key"] ?? "")
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
        card(title: "Repos individuales", subtitle: "Rutas sueltas, para repos fuera de las carpetas vigiladas.") {
            pathList(repos, icon: "arrow.triangle.branch") { path in
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
                runScript("check_git_repos.sh")
            } label: {
                Label("Revisar ahora", systemImage: "arrow.clockwise")
            }
            .tint(brandPurple)
            .padding(.top, 4)
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
    private func pathList(_ paths: [String], icon: String, onRemove: @escaping (String) -> Void) -> some View {
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
        ])
        NotificationCenter.default.post(name: .repoWatchConfigChanged, object: nil)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.easeInOut(duration: 0.18)) { watchFolders.append(url.path) }
            save()
        }
    }

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.easeInOut(duration: 0.18)) { repos.append(url.path) }
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
