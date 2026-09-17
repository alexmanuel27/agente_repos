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
    static var logFile: URL { configDir.appendingPathComponent("logs/check_git_repos.log") }

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
}

extension Notification.Name {
    static let repoWatchConfigChanged = Notification.Name("repoWatchConfigChanged")
}

func runScript(_ name: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["\(RepoWatchConfig.scriptsDir)/\(name)"]
    try? task.run()
}
