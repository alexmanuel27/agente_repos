import SwiftUI

// Git desde la app para los ajustes por repo (remotos). Las revisiones
// periódicas siguen siendo los scripts; esto solo lee/edita la config de git.
struct Remote: Identifiable, Equatable {
    let name: String
    var url: String
    var id: String { name }
}

enum Git {
    static let bin: String = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    // Síncrono: llamarlo siempre fuera del hilo principal.
    static func run(_ dir: String, _ args: [String], timeout: TimeInterval = 20) -> (out: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=10"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("", false) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, p.terminationStatus == 0)
    }

    static func repos(in folder: String) -> [String] {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        return subs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { folder + "/" + $0 }
            .filter { fm.fileExists(atPath: $0 + "/.git") }
    }

    static func remotes(_ dir: String) -> [Remote] {
        let r = run(dir, ["config", "--get-regexp", #"^remote\..*\.url$"#])
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), parts[0].hasSuffix(".url") else { return nil }
            return Remote(name: String(parts[0].dropFirst(7).dropLast(4)), url: parts[1])
        }
    }

    static func setURL(_ dir: String, _ name: String, _ url: String) -> Bool {
        run(dir, ["remote", "set-url", name, url]).ok
    }

    // Prueba que el remoto responde con las credenciales actuales (sin pedir nada).
    static func test(_ dir: String, _ name: String) -> (ok: Bool, msg: String) {
        let r = run(dir, ["ls-remote", "--heads", name], timeout: 25)
        return (r.ok, r.ok ? "responde" : (r.out.split(separator: "\n").last.map(String.init) ?? "sin respuesta"))
    }

    // https://github.com/u/r(.git) → git@github.com:u/r.git. nil si no es http(s).
    static func sshURL(_ url: String) -> String? {
        let pattern = #"^https?://(?:[^@/]+@)?([^/:]+)/(.+?)(?:\.git)?/?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let h = Range(m.range(at: 1), in: url), let p = Range(m.range(at: 2), in: url) else { return nil }
        return "git@\(url[h]):\(url[p]).git"
    }

    static func transport(_ url: String) -> String {
        if url.hasPrefix("http") { return "HTTPS" }
        if url.hasPrefix("git@") || url.hasPrefix("ssh://") { return "SSH" }
        return "local"
    }
}

struct TransportBadge: View {
    let url: String
    var body: some View {
        let t = Git.transport(url)
        Text(t)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill((t == "HTTPS" ? Color.orange : t == "SSH" ? Color.green : Color.gray).opacity(0.2)))
            .foregroundStyle(t == "HTTPS" ? Color.orange : t == "SSH" ? Color.green : Color.secondary)
    }
}

struct CommitRow: Identifiable {
    let sha: String
    let subject: String
    let when: String
    let unpushed: Bool
    var id: String { sha }
}

// Foto del estado de un repo, para la ventana de ajustes. Síncrono: fuera del hilo principal.
struct RepoState {
    var branch = "—"
    var changed = 0
    var untracked = 0
    var ahead: Int?      // vs. upstream; nil si no hay upstream
    var behind: Int?
    var unpushed = 0     // commits que no están en ninguna ref remota
    var commits: [CommitRow] = []
    var activity: [String] = []

    static func load(_ dir: String) -> RepoState {
        var st = RepoState()
        st.branch = Git.run(dir, ["rev-parse", "--abbrev-ref", "HEAD"]).out
        let status = Git.run(dir, ["-c", "core.quotepath=false", "status", "--porcelain", "--untracked-files=all"]).out
        let lines = status.split(separator: "\n")
        st.changed = lines.count
        st.untracked = lines.filter { $0.hasPrefix("??") }.count
        let lr = Git.run(dir, ["rev-list", "--left-right", "--count", "HEAD...@{u}"])
        if lr.ok {
            let n = lr.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            if n.count == 2 { st.ahead = n[0]; st.behind = n[1] }
        }
        let unpushed = Git.run(dir, ["rev-list", "--abbrev-commit", "HEAD", "--not", "--remotes"]).out
            .split(separator: "\n").map(String.init)
        st.unpushed = unpushed.count
        let log = Git.run(dir, ["log", "-12", "--date=format:%d/%m %H:%M", "--format=%h%x09%cd%x09%s"]).out
        st.commits = log.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 3 else { return nil }
            return CommitRow(sha: p[0], subject: p[2], when: p[1], unpushed: unpushed.contains(p[0]))
        }
        // Lo que RepoWatch hizo en este repo, del log de actividad.
        let name = (dir as NSString).lastPathComponent
        let text = (try? String(contentsOf: RepoWatchConfig.logFile, encoding: .utf8)) ?? ""
        st.activity = text.split(separator: "\n").map(String.init)
            .filter { $0.contains("] \(name): ") }.suffix(5).reversed()
        return st
    }
}

struct RepoInfo: Identifiable, Equatable {
    let path: String
    let remotes: [Remote]
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// Una carpeta vigilada que se despliega para mostrar sus repos.
struct FolderRow: View {
    let path: String
    let onRemove: () -> Void
    @State private var expanded = false
    @State private var loading = false
    @State private var repos: [RepoInfo] = []
    @State private var message: String?
    @State private var converting = false
    @State private var detail: RepoInfo?

    private var convertible: Int {
        repos.filter { $0.remotes.contains { Git.sshURL($0.url) != nil } }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    if expanded && repos.isEmpty { load() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Image(systemName: "folder.fill").foregroundStyle(brandPurple).frame(width: 16)
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !repos.isEmpty {
                    Text("\(repos.count) repos").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.18)) { onRemove() } }) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                if expanded && repos.isEmpty { load() }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if loading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Leyendo repos…").font(.caption).foregroundStyle(.secondary) }
                    } else if repos.isEmpty {
                        Text("No hay repos git directamente dentro de esta carpeta.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(repos) { repo in
                            Button { detail = repo } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 14)
                                    Text(repo.name).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    if let r = repo.remotes.first {
                                        TransportBadge(url: r.url)
                                    } else {
                                        Text("sin remoto").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if convertible > 0 {
                            HStack(spacing: 8) {
                                Button {
                                    convertAll()
                                } label: {
                                    Label("Pasar \(convertible) repo(s) a SSH", systemImage: "key.horizontal")
                                }
                                .tint(brandPurple)
                                .disabled(converting)
                                if converting { ProgressView().controlSize(.small) }
                            }
                            .padding(.top, 2)
                        }
                        if let message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .sheet(item: $detail, onDismiss: load) { repo in
            RepoDetailSheet(path: repo.path)
        }
    }

    private func load() {
        loading = true
        DispatchQueue.global().async {
            let list = Git.repos(in: path).map { RepoInfo(path: $0, remotes: Git.remotes($0)) }
            DispatchQueue.main.async { repos = list; loading = false }
        }
    }

    // Cambia a SSH cada remoto http(s) y comprueba que responde; si no
    // responde lo deja como estaba, para no romper un repo que funcionaba.
    private func convertAll() {
        converting = true
        message = nil
        let targets = repos
        DispatchQueue.global().async {
            var done = 0
            var failed: [String] = []
            for repo in targets {
                for r in repo.remotes {
                    guard let ssh = Git.sshURL(r.url) else { continue }
                    guard Git.setURL(repo.path, r.name, ssh) else { failed.append(repo.name); continue }
                    if Git.test(repo.path, r.name).ok {
                        done += 1
                    } else {
                        _ = Git.setURL(repo.path, r.name, r.url)
                        failed.append(repo.name)
                    }
                }
            }
            let fresh = targets.map { RepoInfo(path: $0.path, remotes: Git.remotes($0.path)) }
            DispatchQueue.main.async {
                repos = fresh
                converting = false
                message = "Pasados a SSH: \(done)." + (failed.isEmpty ? "" :
                    " No respondió por SSH (quedaron en HTTPS): \(failed.joined(separator: ", ")). Revisa tu llave SSH en ese servidor.")
            }
        }
    }
}

// Ajustes de un repo: remotos y comportamiento.
struct RepoDetailSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var remotes: [Remote] = []
    @State private var original: [Remote] = []
    @State private var results: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var loaded = false
    @State private var enabled = true
    @State private var mode = "global"
    @State private var state: RepoState?

    @ViewBuilder
    private var stateSection: some View {
        Text("Estado actual").font(.headline)
        if let st = state {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(st.branch).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Spacer()
                }
                stateLine(st.changed == 0 ? "checkmark.circle.fill" : "pencil.circle.fill",
                          st.changed == 0 ? .green : .orange,
                          st.changed == 0 ? "Sin cambios por commitear"
                                          : "\(st.changed) archivo(s) sin commitear (\(st.untracked) nuevos)")
                if let a = st.ahead, let b = st.behind {
                    stateLine(b == 0 ? "checkmark.circle.fill" : "arrow.down.circle.fill", b == 0 ? .green : .orange,
                              b == 0 ? "Al día con el remoto" : "\(b) commit(s) detrás del remoto")
                    if a > 0 { stateLine("arrow.up.circle.fill", brandPurple, "\(a) commit(s) por subir al remoto") }
                } else {
                    stateLine("questionmark.circle", .secondary, "Sin upstream configurado")
                    if st.unpushed > 0 { stateLine("arrow.up.circle.fill", brandPurple, "\(st.unpushed) commit(s) sin subir a ningún remoto") }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            Text("Historial").font(.headline)
            if st.commits.isEmpty {
                Text("Sin commits todavía.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(st.commits) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.sha).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(c.subject).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            if c.unpushed {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 10)).foregroundStyle(brandPurple)
                                    .help("Todavía no está en ningún remoto")
                            }
                            Text(c.when).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }

            if !st.activity.isEmpty {
                Text("Actividad de RepoWatch").font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(st.activity, id: \.self) { line in
                        Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func stateLine(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).font(.system(size: 12))
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent).font(.title2.bold())
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            stateSection

            Text("Remotos").font(.headline)
            if !loaded {
                ProgressView().controlSize(.small)
            } else if remotes.isEmpty {
                Text("Este repo no tiene remotos.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach($remotes) { $r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.name).font(.system(size: 12, weight: .semibold))
                        TransportBadge(url: r.url)
                        Spacer()
                        if busy.contains(r.name) { ProgressView().controlSize(.small) }
                    }
                    TextField("URL", text: $r.url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HStack(spacing: 8) {
                        if r.url != original.first(where: { $0.name == r.name })?.url {
                            Button("Guardar") { save(r.name, r.url) }.tint(brandPurple)
                        }
                        if let ssh = Git.sshURL(r.url) {
                            Button("Pasar a SSH") { r.url = ssh; save(r.name, ssh) }
                        }
                        Button("Probar") { test(r.name) }
                        if let msg = results[r.name] {
                            Text(msg).font(.caption).foregroundStyle(msg.hasPrefix("✓") ? Color.green : Color.orange)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            Divider()
            Text("Comportamiento").font(.headline)
            Toggle("Vigilar este repo", isOn: $enabled)
                .toggleStyle(.switch).tint(brandPurple)
                .onChange(of: enabled) { _, on in RepoWatchConfig.setOverride(path, "enabled", on ? nil : "false") }
            Picker("Modo", selection: $mode) {
                Text("Como el global").tag("global")
                Text("Automático (commit, pull y push solos)").tag("autosync")
                Text("Manual (te pregunta)").tag("review")
            }
            .onChange(of: mode) { _, m in RepoWatchConfig.setOverride(path, "mode", m == "global" ? nil : m) }
            }
            }

            HStack { Spacer(); Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction).tint(brandPurple) }
        }
        .padding(20)
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
    }

    private func load() {
        let o = RepoWatchConfig.readOverrides()[path] ?? [:]
        enabled = o["enabled"] != "false"
        mode = o["mode"] ?? "global"
        DispatchQueue.global().async {
            let list = Git.remotes(path)
            let st = RepoState.load(path)
            DispatchQueue.main.async { remotes = list; original = list; loaded = true; state = st }
        }
    }

    private func save(_ name: String, _ url: String) {
        busy.insert(name)
        DispatchQueue.global().async {
            let ok = Git.setURL(path, name, url.trimmingCharacters(in: .whitespaces))
            let t: (ok: Bool, msg: String) = ok ? Git.test(path, name) : (false, "no se pudo guardar")
            let fresh = Git.remotes(path)
            DispatchQueue.main.async {
                busy.remove(name)
                remotes = fresh; original = fresh
                results[name] = t.ok ? "✓ guardado, responde" : "Guardado, pero no responde: \(t.msg)"
            }
        }
    }

    private func test(_ name: String) {
        busy.insert(name)
        DispatchQueue.global().async {
            let t = Git.test(path, name)
            DispatchQueue.main.async {
                busy.remove(name)
                results[name] = t.ok ? "✓ responde" : t.msg
            }
        }
    }
}
