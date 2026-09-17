import SwiftUI
import AppKit

let okStatus = "Todo al día ✅"
let unconfiguredStatus = "Sin repos configurados — abre Preferencias"

final class StatusModel: ObservableObject {
    @Published var status: String = "Cargando…"
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
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

    var isPending: Bool { status != okStatus && status != unconfiguredStatus }
    var iconName: String {
        if status == unconfiguredStatus { return "gearshape" }
        return isPending ? "exclamationmark.triangle.fill" : "checkmark.circle"
    }
}

// Corre check_git_repos.sh cada N minutos según Preferencias (reemplaza al
// LaunchAgent de la versión anterior: el horario ahora vive en la app).
final class Scheduler {
    private var timer: Timer?

    init() {
        NotificationCenter.default.addObserver(
            forName: .repoWatchConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reschedule() }
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        let minutes = Double(RepoWatchConfig.readSettings()["interval_minutes"] ?? "60") ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { _ in
            runScript("check_git_repos.sh")
        }
    }
}

let scheduler = Scheduler()

@main
struct GitRepoCheckerApp: App {
    @StateObject private var model = StatusModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("RepoWatch", systemImage: model.iconName) {
            Text(model.status)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 340, alignment: .leading)

            Divider()

            Button("Revisar y commitear…") { runScript("review_and_commit.sh") }
            Button("Revisar ahora") {
                runScript("check_git_repos.sh")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.refresh() }
            }
            Button("Ver log") { NSWorkspace.shared.open(RepoWatchConfig.logFile) }

            Divider()

            Button("Preferencias…") {
                // Apps de barra de menús (LSUIElement) no activan su ventana
                // sola con openWindow: hay que pasar a política normal y
                // forzar la activación, si no la ventana queda detrás.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "preferences")
            }
            Button("Salir") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Window("RepoWatch — Preferencias", id: "preferences") {
            PreferencesView()
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowResizability(.contentSize)
    }
}
