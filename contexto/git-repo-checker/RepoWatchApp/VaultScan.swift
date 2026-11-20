import Foundation

// Solo lectura: lee las notas del vault y el informe que escribe
// lib_vault_check.sh. Sin dependencias de la interfaz para poder probarlo
// aparte (tests/test_vault_scan.sh).

struct ProjectNote: Identifiable {
    let id: String          // ruta absoluta
    let title: String
    let zone: String        // carpeta de primer nivel dentro del vault
    let updated: String?
    let daysOld: Int?
    let estado: String
    let siguiente: String
    let ficha: String
    let fichaWords: Int
    let totalWords: Int

    var warnings: [String] {
        var w: [String] = []
        if fichaWords > 150 { w.append("Ficha de \(fichaWords) palabras") }
        if let d = daysOld, d > 30 { w.append("Sin actualizar hace \(d) días") }
        if totalWords > 1500 { w.append("\(totalWords) palabras en total") }
        return w
    }
}

struct ReportSection: Identifiable {
    var id: String { title }
    let title: String
    let items: [String]
}

enum VaultScan {
    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    // Notas con "## Ficha" (formato de memoria), de todo el vault.
    static func projects(in root: String, now: Date = Date()) -> [ProjectNote] {
        let rootURL = URL(fileURLWithPath: root)
        guard let en = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [ProjectNote] = []
        for case let url as URL in en
        where url.pathExtension == "md" && url.lastPathComponent != "Mantenimiento del vault.md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let note = parse(text, url: url, root: rootURL, now: now) else { continue }
            out.append(note)
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func parse(_ text: String, url: URL, root: URL, now: Date) -> ProjectNote? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Ficha") }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        let body = lines[(start + 1)..<end]
        let ficha = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        func field(_ key: String) -> String {
            let marker = "**\(key):**"
            guard let l = body.first(where: { $0.contains(marker) }) else { return "" }
            return l.components(separatedBy: marker).dropFirst().joined()
                .trimmingCharacters(in: .whitespaces)
        }

        var updated: String?
        var daysOld: Int?
        if let l = lines.prefix(10).first(where: { $0.hasPrefix("actualizado:") }) {
            let s = l.dropFirst("actualizado:".count).trimmingCharacters(in: .whitespaces)
            updated = s
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: s) {
                daysOld = Calendar.current.dateComponents([.day], from: d, to: now).day
            }
        }

        // resolvingSymlinksInPath: el enumerador puede devolver /private/var donde la raíz dice /var
        let rel = String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
        let zone = rel.firstIndex(of: "/").map { String(rel[..<$0]) } ?? ""
        return ProjectNote(
            id: url.path, title: url.deletingPathExtension().lastPathComponent, zone: zone,
            updated: updated, daysOld: daysOld,
            estado: field("Estado"), siguiente: field("Siguiente acción"),
            ficha: ficha, fichaWords: words(ficha), totalWords: words(text))
    }

    // Secciones con elementos de "Mantenimiento del vault.md" (omite «Ninguno.»).
    static func report(at url: URL) -> (generated: String, sections: [ReportSection]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", []) }
        var generated = ""
        var sections: [ReportSection] = []
        var title: String?
        var items: [String] = []
        func flush() {
            if let t = title, !items.isEmpty { sections.append(ReportSection(title: t, items: items)) }
            items = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("Generado:") {
                generated = line.dropFirst("Generado:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## Cambios") {
                flush(); title = "Cambios aplicados automáticamente"
            } else if line.hasPrefix("### ") {
                flush(); title = String(line.dropFirst(4))
            } else if line.hasPrefix("## Última corrección") {
                flush(); title = String(line.dropFirst(3))
            } else if line.hasPrefix("## ") {
                flush(); title = nil
            } else if line.hasPrefix("- "), title != nil, line != "- Ninguno." {
                items.append(String(line.dropFirst(2)))
            }
        }
        flush()
        return (generated, sections)
    }
}
