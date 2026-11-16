import Foundation

// Lo compila tests/test_vault_scan.sh junto a VaultScan.swift. Uso: scan <vault> <informe.md>
let root = CommandLine.arguments[1]
let reportPath = CommandLine.arguments[2]
var fail = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   \(name)" : "FALLA \(name)")
    if !ok { fail = true }
}

let notes = VaultScan.projects(in: root)
let byTitle = Dictionary(uniqueKeysWithValues: notes.map { ($0.title, $0) })

check("solo notas con Ficha (sin MOC, sin ocultas)", Set(byTitle.keys) == ["Vieja", "Fresca", "Larga"])
check("Estado y Siguiente acción leídos", byTitle["Fresca"]?.estado == "todo bien" && byTitle["Fresca"]?.siguiente == "seguir")
check("zona = carpeta de primer nivel", byTitle["Larga"]?.zone == "IA compartida")
check("nota vieja avisa", byTitle["Vieja"]?.warnings.contains { $0.hasPrefix("Sin actualizar hace") } == true)
check("nota fresca sin avisos", byTitle["Fresca"]?.warnings.isEmpty == true)
check("Ficha larga avisa", byTitle["Larga"]?.warnings.contains { $0.hasPrefix("Ficha de") } == true)
check("la Ficha no incluye otras secciones", byTitle["Fresca"]?.ficha.contains("fuera de la ficha") == false)

let r = VaultScan.report(at: URL(fileURLWithPath: reportPath))
check("fecha del informe", r.generated == "2026-11-15 10:00")
check("secciones con elementos, sin «Ninguno.»", r.sections.map(\.title) == ["Cambios aplicados automáticamente", "Enlaces rotos"])
check("elementos del informe", r.sections.last?.items == ["Nota R → «Rota»"])
check("informe inexistente no rompe", VaultScan.report(at: URL(fileURLWithPath: "/no/existe.md")).sections.isEmpty)

exit(fail ? 1 : 0)
