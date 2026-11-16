import SwiftUI
import AppKit

// Ventana «Memoria del vault»: una tarjeta por nota de proyecto (Estado,
// Siguiente acción, avisos) y el informe de mantenimiento. Solo lee; lo único
// que ejecuta es check_vault.sh, igual que Preferencias → Vault.
struct MemoryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case projects = "Proyectos", report = "Informe"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .projects
    @State private var notes: [ProjectNote] = []
    @State private var sections: [ReportSection] = []
    @State private var generated = ""
    @State private var query = ""
    @State private var onlyWarnings = false
    @State private var running = false
    @State private var copiedID: String?
    @State private var vaultDir = RepoWatchConfig.vaultDir
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vaultDir.isEmpty {
                emptyState
            } else if tab == .projects {
                projectsList
            } else {
                reportList
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(.regularMaterial)
        .onAppear(perform: reload)
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            TextField("Buscar", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            if tab == .projects {
                Toggle("Solo con avisos", isOn: $onlyWarnings)
                    .toggleStyle(.switch)
                    .tint(brandPurple)
                    .fixedSize()
            }

            Spacer()

            if running {
                ProgressView().controlSize(.small)
                Text("Revisando…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button {
                running = true
                runScriptAsync("check_vault.sh", args: ["--manual"]) {
                    running = false
                    reload()
                }
            } label: {
                Label("Revisar ahora", systemImage: "arrow.clockwise")
            }
            .tint(brandPurple)
            .disabled(running || vaultDir.isEmpty)
            Button("Abrir informe") { NSWorkspace.shared.open(RepoWatchConfig.vaultReportFile) }
                .disabled(generated.isEmpty)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Todavía no hay un vault elegido").font(.headline)
            Button("Abrir Preferencias") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .tint(brandPurple)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Proyectos

    private var filteredNotes: [ProjectNote] {
        notes.filter { n in
            (!onlyWarnings || !n.warnings.isEmpty)
                && (query.isEmpty
                    || [n.title, n.zone, n.estado, n.siguiente].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var projectsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if filteredNotes.isEmpty {
                    Text(notes.isEmpty ? "No hay notas con «## Ficha» en este vault." : "Ninguna nota coincide.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                ForEach(filteredNotes) { card($0) }
            }
            .padding(16)
        }
    }

    private func card(_ n: ProjectNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n.title).font(.headline)
                if !n.zone.isEmpty { Text(n.zone).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let u = n.updated { Text("Actualizada \(u)").font(.caption).foregroundStyle(.secondary) }
            }
            if !n.warnings.isEmpty {
                HStack(spacing: 6) {
                    ForEach(n.warnings, id: \.self) { w in
                        Text(w)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
            }
            if n.estado.isEmpty && n.siguiente.isEmpty {
                Text(n.ficha).font(.system(size: 12)).lineLimit(4)
            } else {
                labeled("Estado", n.estado)
                labeled("Siguiente", n.siguiente)
            }
            HStack(spacing: 10) {
                Button { open(n) } label: { Label("Abrir en Obsidian", systemImage: "arrow.up.forward.app") }
                Button { copyFicha(n) } label: {
                    Label(copiedID == n.id ? "Copiada" : "Copiar Ficha",
                          systemImage: copiedID == n.id ? "checkmark" : "doc.on.doc")
                }
            }
            .tint(brandPurple)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func labeled(_ label: String, _ text: String) -> some View {
        if !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(brandPurple)
                    .frame(width: 62, alignment: .leading)
                Text(text).font(.system(size: 12)).lineLimit(3)
            }
        }
    }

    // MARK: Informe

    private var reportList: some View {
        let shown: [ReportSection] = sections.compactMap { s in
            let items = query.isEmpty ? s.items : s.items.filter { $0.localizedCaseInsensitiveContains(query) }
            return items.isEmpty ? nil : ReportSection(title: s.title, items: items)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sections.isEmpty {
                    Text(generated.isEmpty ? "Sin informe todavía: pulsa «Revisar ahora»." : "Sin pendientes ni cambios.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Generado \(generated)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(shown) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(s.title) (\(s.items.count))").font(.headline)
                        ForEach(s.items, id: \.self) { item in
                            Text("• " + item).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Acciones

    private func open(_ n: ProjectNote) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let enc = n.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if let url = URL(string: "obsidian://open?path=\(enc)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: n.id))
    }

    private func copyFicha(_ n: ProjectNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Nota: \(n.id)\n\n## Ficha\n\(n.ficha)", forType: .string)
        copiedID = n.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == n.id { copiedID = nil }
        }
    }

    private func reload() {
        vaultDir = RepoWatchConfig.vaultDir
        guard !vaultDir.isEmpty else { notes = []; sections = []; generated = ""; return }
        let root = vaultDir
        let report = RepoWatchConfig.vaultReportFile
        DispatchQueue.global(qos: .userInitiated).async {
            let n = VaultScan.projects(in: root)
            let r = VaultScan.report(at: report)
            DispatchQueue.main.async {
                notes = n
                sections = r.sections
                generated = r.generated
            }
        }
    }
}
