import SwiftUI
import AppKit

let scriptsDir = "/Users/alex/scripts"
let stateFile = "\(scriptsDir)/last_check_state.txt"
let logFile = "\(scriptsDir)/logs/check_git_repos.log"
let okStatus = "Todo al día ✅"

func runScript(_ path: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [path]
    try? task.run()
}

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
        if let text = try? String(contentsOfFile: stateFile, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = text
        } else {
            status = okStatus
        }
    }

    var isPending: Bool { status != okStatus }
}

@main
struct GitRepoCheckerApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra("Git Repo Checker",
                      systemImage: model.isPending ? "exclamationmark.triangle.fill" : "checkmark.circle") {
            Text(model.status)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 340, alignment: .leading)

            Divider()

            Button("Revisar y commitear…") {
                runScript("\(scriptsDir)/review_and_commit.sh")
            }
            Button("Revisar ahora") {
                runScript("\(scriptsDir)/check_git_repos.sh")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.refresh() }
            }
            Button("Ver log") {
                NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
            }

            Divider()

            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
