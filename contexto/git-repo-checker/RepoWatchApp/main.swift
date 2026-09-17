import SwiftUI
import AppKit
import UserNotifications

let okStatus = "Todo al día ✅"
let unconfiguredStatus = "Sin repos configurados — abre Preferencias"

final class StatusModel: ObservableObject {
    @Published var status: String = "Cargando…"
    @Published var lastCheckText: String = "nunca revisado"
    @Published var isStale: Bool = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        updateLastCheck()
        guard RepoWatchConfig.isConfigured else {
            status = unconfiguredStatus
            return
        }
        if let text = try? String(contentsOf: RepoWatchConfig.stateFile, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = text
        } else {
            status = okStatus
        }
    }

    private func updateLastCheck() {
        guard let text = try? String(contentsOf: RepoWatchConfig.lastCheckFile, encoding: .utf8),
              let epoch = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            lastCheckText = "nunca revisado"
            isStale = RepoWatchConfig.isConfigured
            return
        }
        let elapsed = Date().timeIntervalSince1970 - epoch
        let minutes = Int(elapsed / 60)
        lastCheckText = minutes < 1 ? "hace instantes" : "hace \(minutes) min"
        let intervalMinutes = Double(RepoWatchConfig.readSettings()["interval_minutes"] ?? "60") ?? 60
        isStale = elapsed > intervalMinutes * 60 * 3
    }

    var isPending: Bool { status != okStatus && status != unconfiguredStatus }
    var isUnconfigured: Bool { status == unconfiguredStatus }
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
        }
    }

    func reschedule() {
        timer?.invalidate()
        let minutes = Double(RepoWatchConfig.readSettings()["interval_minutes"] ?? "60") ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { _ in
            runScript("check_git_repos.sh")
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

@main
struct GitRepoCheckerApp: App {
    @StateObject private var model: StatusModel
    @StateObject private var scheduler: Scheduler
    private let notifWatcher: NotificationWatcher
    @Environment(\.openSettings) private var openSettings

    init() {
        _model = StateObject(wrappedValue: StatusModel())
        _scheduler = StateObject(wrappedValue: Scheduler())
        notifWatcher = NotificationWatcher()
    }

    var body: some Scene {
        MenuBarExtra {
            Text(model.status)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 340, alignment: .leading)
            Text("Última revisión: \(model.lastCheckText)")
                .font(.system(size: 10))
                .foregroundStyle(model.isStale ? .red : .secondary)

            Divider()

            Button("Revisar y commitear…") { runScript("review_and_commit.sh") }
                .disabled(!model.isPending)
            Button("Revisar ahora") {
                runScript("check_git_repos.sh")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.refresh() }
            }
            Button("Pushear pendientes") { runScript("push_pending.sh") }
            Button("Actualizar (pull)") { runScript("pull_pending.sh") }

            let undoable = undoableRepos()
            if !undoable.isEmpty {
                Menu("Deshacer último commit…") {
                    ForEach(undoable) { repo in
                        Button(repo.name) { runScript("undo_commit.sh", args: [repo.path]) }
                    }
                }
            }

            Button("Ver log") { NSWorkspace.shared.open(RepoWatchConfig.logFile) }

            Divider()

            Button("Preferencias…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Salir") { NSApplication.shared.terminate(nil) }
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
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
        }
        .windowResizability(.contentSize)
    }
}
