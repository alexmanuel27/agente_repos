import Foundation

// Config por usuario, compartida con los scripts embebidos en Resources/scripts
// (ver lib_discover_repos.sh / lib_settings.sh — mismo formato, mismas rutas).
enum RepoWatchConfig {
    static let configDir: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoWatch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        return dir
    }()

    static var watchFoldersFile: URL { configDir.appendingPathComponent("watch_folders.txt") }
    static var reposFile: URL { configDir.appendingPathComponent("repos.txt") }
    static var settingsFile: URL { configDir.appendingPathComponent("settings.txt") }
    static var stateFile: URL { configDir.appendingPathComponent("last_check_state.txt") }
    static var lastCheckFile: URL { configDir.appendingPathComponent("last_check.txt") }
    static var overridesFile: URL { configDir.appendingPathComponent("repo_overrides.txt") }
    static var pendingNotificationFile: URL { configDir.appendingPathComponent("pending_notification.txt") }
    static var logFile: URL { configDir.appendingPathComponent("logs/check_git_repos.log") }
    static var vaultWarningsFile: URL { configDir.appendingPathComponent("vault_warnings.txt") }

    // Carpeta de memoria (Obsidian); vacía = revisión del vault desactivada.
    static var vaultDir: String { readSettings()["vault_dir"] ?? "" }
    static var vaultReportFile: URL {
        URL(fileURLWithPath: vaultDir).appendingPathComponent("Mantenimiento del vault.md")
    }
    static var vaultLastFile: URL { configDir.appendingPathComponent("vault_last.txt") }

    // Vale un vault de Obsidian (tiene .obsidian) o una carpeta con Inicio.md
    // adentro o en una subcarpeta directa.
    static func isVaultFolder(_ path: String) -> Bool {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: root.appendingPathComponent(".obsidian").path) { return true }
        if fm.fileExists(atPath: root.appendingPathComponent("Inicio.md").path) { return true }
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.contains { fm.fileExists(atPath: $0.appendingPathComponent("Inicio.md").path) }
    }

    // "epoch avisos aplicados" de la última revisión (vault_last.txt).
    static func vaultSummary() -> String? {
        guard let text = try? String(contentsOf: vaultLastFile, encoding: .utf8) else { return nil }
        let p = text.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard p.count == 3 else { return nil }
        let minutes = Int((Date().timeIntervalSince1970 - Double(p[0])) / 60)
        let when = minutes < 1 ? "hace instantes" : "hace \(minutes) min"
        return "Última revisión \(when): \(p[2]) cambio(s) aplicado(s), \(p[1]) aviso(s)."
    }

    static var scriptsDir: String { Bundle.main.resourcePath! + "/scripts" }

    private static func readLines(_ url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
    }

    private static func writeLines(_ lines: [String], to url: URL) {
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static var watchFolders: [String] {
        get { readLines(watchFoldersFile) }
        set { writeLines(newValue, to: watchFoldersFile) }
    }

    static var repos: [String] {
        get { readLines(reposFile) }
        set { writeLines(newValue, to: reposFile) }
    }

    static func readSettings() -> [String: String] {
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return [:] }
        var dict = [String: String]()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { dict[parts[0]] = parts[1] }
        }
        return dict
    }

    static func writeSettings(_ dict: [String: String]) {
        let text = dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
        try? text.write(to: settingsFile, atomically: true, encoding: .utf8)
    }

    static var isConfigured: Bool { !watchFolders.isEmpty || !repos.isEmpty }

    // Overrides por repo (ruta TAB clave TAB valor), leídos por
    // lib_repo_config.sh del lado bash. Última línea por (ruta, clave) gana.
    static func readOverrides() -> [String: [String: String]] {
        guard let text = try? String(contentsOf: overridesFile, encoding: .utf8) else { return [:] }
        var result = [String: [String: String]]()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            result[parts[0], default: [:]][parts[1]] = parts[2]
        }
        return result
    }

    static func writeOverrides(_ overrides: [String: [String: String]]) {
        var lines: [String] = []
        for path in overrides.keys.sorted() {
            for key in (overrides[path] ?? [:]).keys.sorted() {
                lines.append("\(path)\t\(key)\t\(overrides[path]![key]!)")
            }
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(to: overridesFile, atomically: true, encoding: .utf8)
    }

    static func setSyncPreset(_ path: String, autosync: Bool) {
        var overrides = readOverrides()
        if autosync {
            overrides[path] = ["mode": "autosync", "stage": "all", "push": "auto", "sign": "false"]
        } else {
            overrides.removeValue(forKey: path)
        }
        writeOverrides(overrides)
    }

    static func isAutosync(_ path: String) -> Bool {
        readOverrides()[path]?["mode"] == "autosync"
    }
}

extension Notification.Name {
    static let repoWatchConfigChanged = Notification.Name("repoWatchConfigChanged")
}

func runScript(_ name: String, args: [String] = []) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["\(RepoWatchConfig.scriptsDir)/\(name)"] + args
    try? task.run()
}

// Corre un script y avisa en el hilo principal cuando termina (para mostrar
// progreso en la interfaz).
func runScriptAsync(_ name: String, args: [String] = [], completion: @escaping () -> Void) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["\(RepoWatchConfig.scriptsDir)/\(name)"] + args
    task.terminationHandler = { _ in DispatchQueue.main.async(execute: completion) }
    do { try task.run() } catch { DispatchQueue.main.async(execute: completion) }
}

// Corre un script y espera su salida (uso: listas cortas, como
// list_undoable.sh — nunca para los flujos que abren diálogos).
func runScriptCapture(_ name: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["\(RepoWatchConfig.scriptsDir)/\(name)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}
