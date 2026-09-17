import SwiftUI
import AppKit

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

@main
struct GitRepoCheckerApp: App {
    @StateObject private var model = StatusModel()
    @StateObject private var scheduler = Scheduler()
    @Environment(\.openSettings) private var openSettings

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
