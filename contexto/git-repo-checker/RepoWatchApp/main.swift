import SwiftUI
import AppKit
import UserNotifications

// Una fila por repo, de repo_status.tsv (lo escribe check_git_repos.sh).
// kind: ok · synced (se actuó solo) · info (a la espera) · problem (hay que mirarlo)
struct RepoRow: Identifiable, Equatable {
    let name: String
    let kind: String
    let detail: String
    let path: String
    var id: String { path.isEmpty ? name : path }

    var icon: String {
        switch kind {
        case "problem": return "exclamationmark.triangle.fill"
        case "synced": return "arrow.triangle.2.circlepath.circle.fill"
        case "info": return "clock.fill"
        default: return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch kind {
        case "problem": return .orange
        case "synced": return brandPurple
        case "info": return .secondary
        default: return .green
        }
    }
    var order: Int { ["problem": 0, "synced": 1, "info": 2][kind] ?? 3 }
}

final class StatusModel: ObservableObject {
    @Published var rows: [RepoRow] = []
    @Published var checking = false
    @Published var lastCheck: Date?
    @Published var configured = false
    @Published var vaultWarnings = 0
    @Published var now = Date()
    private var timer: Timer?

    // Los archivos son pequeños: se leen cada 2 s para que el panel siga en
    // vivo mientras está abierto (una revisión en curso, el resultado al
    // terminar) sin depender de que alguien dispare un refresco.
    init() {
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        now = Date()
        configured = RepoWatchConfig.isConfigured

        let lock = RepoWatchConfig.checkLockDir.path
        let lockAge = (try? FileManager.default.attributesOfItem(atPath: lock)[.modificationDate] as? Date)
            .flatMap { $0 }.map { Date().timeIntervalSince($0) }
        // Un candado de más de 20 min es de una revisión que murió, no en curso.
        checking = lockAge.map { $0 < 20 * 60 } ?? false

        let text = (try? String(contentsOf: RepoWatchConfig.repoStatusFile, encoding: .utf8)) ?? ""
        let parsed = text.split(separator: "\n").compactMap { line -> RepoRow? in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 3 else { return nil }
            return RepoRow(name: p[0], kind: p[1], detail: p[2], path: p.count > 3 ? p[3] : "")
        }
        if parsed != rows { rows = parsed }

        if let t = try? String(contentsOf: RepoWatchConfig.lastCheckFile, encoding: .utf8),
           let epoch = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastCheck = Date(timeIntervalSince1970: epoch)
        } else {
            lastCheck = nil
        }

        let warnings = (try? String(contentsOf: RepoWatchConfig.vaultWarningsFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        vaultWarnings = RepoWatchConfig.vaultDir.isEmpty ? 0 : warnings
    }

    var problems: [RepoRow] { rows.filter { $0.kind == "problem" } }
    var isPending: Bool { !problems.isEmpty }
    var isUnconfigured: Bool { !configured }

    var lastCheckText: String {
        guard let d = lastCheck else { return "nunca" }
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "hace instantes" }
        if s < 3600 { return "hace \(s / 60) min" }
        return "hace \(s / 3600) h"
    }

    // Más de 3 intervalos sin revisar: el chequeo automático dejó de correr.
    var isStale: Bool {
        guard configured else { return false }
        guard let d = lastCheck else { return true }
        let interval = Double(RepoWatchConfig.readSettings()["interval_minutes"] ?? "60") ?? 60
        return now.timeIntervalSince(d) > interval * 60 * 3
    }
}

// Corre check_git_repos.sh cada N minutos según Preferencias (reemplaza al
// LaunchAgent de la versión anterior: el horario ahora vive en la app).
// OJO: debe ser propiedad de una vista/App (@StateObject), no una constante
// global de nivel superior — un global así se inicializa perezosamente al
// primer acceso, y si nada lo lee nunca se crea el Timer (era exactamente
// el bug: el chequeo periódico nunca corrió).
final class Scheduler: ObservableObject {
    private var timer: Timer?

    init() {
        NotificationCenter.default.addObserver(
            forName: .repoWatchConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reschedule() }
        reschedule()
        // Primera corrida a los 30s, no hay que esperar el intervalo completo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            runScript("check_git_repos.sh")
            runScript("check_vault.sh")
        }
    }

    func reschedule() {
        timer?.invalidate()
        let minutes = Double(RepoWatchConfig.readSettings()["interval_minutes"] ?? "60") ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { _ in
            runScript("check_git_repos.sh")
            runScript("check_vault.sh")
        }
    }
}

// Los scripts bash escriben el texto de cada aviso en pending_notification.txt
// en vez de llamar `osascript display notification` — así el banner queda
// atribuido a RepoWatch (con su ícono) en vez de a "Script Editor", y no
// depende de que el usuario tenga permisos de notificación para Script
// Editor. Se revisa cada pocos segundos, no solo al terminar un script,
// porque check_git_repos.sh puede quedar bloqueado minutos en un diálogo
// después de escribir el archivo.
final class NotificationWatcher {
    private var timer: Timer?
    private var authorized = false

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            if let error {
                NSLog("RepoWatch: notification auth error: \(error)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkPending()
        }
    }

    private func checkPending() {
        let url = RepoWatchConfig.pendingNotificationFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: url)
        guard !body.isEmpty else { return }
        post(body)
    }

    private func post(_ body: String) {
        guard authorized else {
            // Respaldo: si el permiso nativo no se concedió (apps sin firma
            // de Apple a veces lo tienen bloqueado, como nos pasó con
            // terminal-notifier), usar el camino que ya sabíamos que
            // funciona en vez de perder el aviso en silencio.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "display notification \(appleScriptString(body)) with title \"RepoWatch\" sound name \"Ping\""]
            try? task.run()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "RepoWatch"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("RepoWatch: notification post error: \(error)")
            }
        }
    }
}

private func appleScriptString(_ s: String) -> String {
    "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

// Repos con un commit de RepoWatch que todavía se puede deshacer (HEAD sin
// cambiar desde entonces, no pusheado). "path\tname" por línea, de
// list_undoable.sh.
struct UndoableRepo: Identifiable {
    let path: String
    let name: String
    var id: String { path }
}

func undoableRepos() -> [UndoableRepo] {
    runScriptCapture("list_undoable.sh")
        .split(separator: "\n")
        .compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return UndoableRepo(path: String(parts[0]), name: String(parts[1]))
        }
}

// Botón de fila para el panel: resalta al pasar el ratón.
struct PanelButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hover && !disabled ? Color.primary.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

struct StatusPanel: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var undoable: [UndoableRepo] = []

    private var headline: (icon: String, text: String, color: Color) {
        if model.isUnconfigured { return ("gearshape.fill", "Sin repos configurados", .secondary) }
        if model.checking { return ("arrow.triangle.2.circlepath", "Revisando…", brandPurple) }
        let n = model.problems.count
        if n > 0 { return ("exclamationmark.triangle.fill", n == 1 ? "1 problema por revisar" : "\(n) problemas por revisar", .orange) }
        return ("checkmark.circle.fill", "Todo en orden", .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: headline.icon).font(.title2).foregroundStyle(headline.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline.text).font(.headline)
                    Text("Última revisión: \(model.lastCheckText)")
                        .font(.caption)
                        .foregroundStyle(model.isStale ? .red : .secondary)
                }
                Spacer()
                if model.checking { ProgressView().controlSize(.small) }
            }
            .padding(14)

            Divider()
            repoList
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                PanelButton(title: "Revisar ahora", icon: "arrow.clockwise", disabled: model.checking) {
                    runScript("check_git_repos.sh", args: ["--manual"])
                    model.refresh()
                }
                if model.isPending {
                    PanelButton(title: "Revisar problemas…", icon: "checklist") { runScript("review_and_commit.sh") }
                }
                PanelButton(title: "Pushear pendientes", icon: "arrow.up.circle") { runScript("push_pending.sh") }
                PanelButton(title: "Actualizar (pull)", icon: "arrow.down.circle") { runScript("pull_pending.sh") }
                if !undoable.isEmpty {
                    Menu {
                        ForEach(undoable) { repo in
                            Button(repo.name) { runScript("undo_commit.sh", args: [repo.path]) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward.circle").frame(width: 18).foregroundStyle(.secondary)
                            Text("Deshacer último commit")
                            Spacer()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                if model.vaultWarnings > 0 {
                    PanelButton(title: "Vault: \(model.vaultWarnings) \(model.vaultWarnings == 1 ? "aviso" : "avisos")", icon: "books.vertical") {
                        NSWorkspace.shared.open(RepoWatchConfig.vaultReportFile)
                    }
                }
                if !RepoWatchConfig.vaultDir.isEmpty {
                    PanelButton(title: "Memoria del vault…", icon: "brain") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "memory")
                    }
                }
                PanelButton(title: "Ver log", icon: "doc.text") { NSWorkspace.shared.open(RepoWatchConfig.logFile) }
                PanelButton(title: "Preferencias…", icon: "gearshape") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                PanelButton(title: "Salir", icon: "power") { NSApplication.shared.terminate(nil) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 340)
        .onAppear { undoable = undoableRepos() }
    }

    @ViewBuilder
    private var repoList: some View {
        if model.rows.isEmpty {
            Text(model.isUnconfigured ? "Agrega carpetas o repos en Preferencias." : "Todavía no hay datos: pulsa «Revisar ahora».")
                .font(.caption).foregroundStyle(.secondary)
                .padding(14)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows.sorted { ($0.order, $0.name) < ($1.order, $1.name) }) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: row.icon).foregroundStyle(row.color).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).font(.system(size: 12, weight: .semibold))
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(row.kind == "problem" ? Color.orange : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .help(row.path)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
        }
    }
}

@main
struct GitRepoCheckerApp: App {
    @StateObject private var model: StatusModel
    @StateObject private var scheduler: Scheduler
    private let notifWatcher: NotificationWatcher

    init() {
        _model = StateObject(wrappedValue: StatusModel())
        _scheduler = StateObject(wrappedValue: Scheduler())
        notifWatcher = NotificationWatcher()
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: model)
        } label: {
            // Misma forma que el logo (rama de git) en vez de íconos
            // genéricos que cambian entre sí — el estado va en un punto.
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.triangle.branch")
                    .opacity(model.isUnconfigured ? 0.4 : 1)
                if model.isPending {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Memoria del vault", id: "memory") {
            MemoryView()
        }
        .defaultSize(width: 780, height: 640)

        Settings {
            PreferencesView()
        }
        .windowResizability(.contentSize)
    }
}
