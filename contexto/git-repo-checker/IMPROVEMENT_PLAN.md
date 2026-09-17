# RepoWatch — Plan de mejoras

Análisis hecho con Opus sobre el código completo de `RepoWatchApp/` (Swift +
scripts bash) más el historial de commits de esta misma carpeta. No repite
decisiones ya tomadas (ver §0); da hallazgos concretos con archivo/línea,
por qué importa, y una recomendación específica.

## 0. Decisiones ya tomadas (no se reabren aquí)

- No App Store — el sandbox bloquea `Process`/`bash`. Distribución local nada más.
- Diálogos `osascript` en vez de `terminal-notifier` — apps sin firma de Apple no obtienen permiso de notificación de forma confiable.
- Firma vía `-c gpg.format=ssh -c user.signingkey=…`, sin tocar la config global de git.
- `LSUIElement` quitado a propósito — ícono de Dock permanente.
- `Settings` scene nativa para Preferencias.
- Push al primer remoto que responda, no siempre `origin`.

## 1. Hallazgo principal: el chequeo periódico nunca ha corrido

`main.swift:56`:

```swift
let scheduler = Scheduler()
```

Es una constante global de nivel superior en un archivo compilado con
`-parse-as-library` (lo exige `@main`). Un global así en Swift se
inicializa perezosamente al primer acceso — y nada en el código accede a
`scheduler` después de declararlo. Resultado: `Scheduler.init()` nunca
corre, nunca se crea el `Timer`, y el observer de
`.repoWatchConfigChanged` nunca se registra (cambiar el intervalo en
Preferencias tampoco hace nada).

Evidencia: `~/Library/Application Support/RepoWatch/logs/` está vacío y
`last_check_state.txt` no existe, pese a que la app está instalada, es
ítem de inicio de sesión, y tiene 9+ repos configurados. Lo único que ha
corrido el checker alguna vez fue el botón manual.

**Arreglo:** que el scheduler sea propiedad de la App, no un global
perezoso — ej. `@StateObject private var scheduler = Scheduler()` dentro
de `GitRepoCheckerApp`, o un `NSApplicationDelegateAdaptor` que lo cree en
`applicationDidFinishLaunching`. Además, correr un chequeo ~30s después de
abrir, no solo tras el primer intervalo completo.

## 2. Configuración por repo — diseño concreto

### 2.1 Qué es `nube` en realidad (medido, no asumido)

`/Users/alex/Nube /nube`: 63,428 archivos trackeados, `.git` de 9.4 GB, 3
submódulos (uno sin inicializar), 121 `.DS_Store` trackeados, sin
`.gitignore`, un `.zip` de 3.1 GB ya commiteado en el historial, remotos
`origin → /Volumes/Untitled/nube.git` y `ssd → /Volumes/Alex-SSD/nube.git`
(normalmente desconectados), rama `master` con upstream `origin/master`.

Es una carpeta de sincronización, no un proyecto. La respuesta correcta
no es "molestar menos" — los archivos nuevos sí deberían commitearse, solo
que sin pedirle a un humano que escriba un mensaje.

### 2.2 Dónde deben vivir los overrides

**No extender `repos.txt`.** La mitad de los repos vigilados nunca
aparecen ahí — se descubren escaneando `watch_folders.txt`. Un override
en una línea de `repos.txt` nunca podría aplicar a esos. Los overrides
deben ir por ruta absoluta, en su propio archivo.

**Archivo nuevo:** `~/Library/Application Support/RepoWatch/repo_overrides.txt`,
una línea por override, separado por TAB:

```
/Users/alex/Nube /nube	mode	autosync
/Users/alex/Nube /nube	stage	all
/Users/alex/Nube /nube	push	auto
/Users/alex/Nube /nube	sign	false
```

Por qué este formato: las rutas tienen espacios pero nunca tabs (TAB no
necesita escapar); bash 3.2 (el de macOS) lo parsea en una línea con
`IFS=$'\t'`; Swift con `split(separator: "\t")`; ningún archivo existente
cambia de formato ni parser. Clave ausente = hereda de `settings.txt`.
Última línea gana.

### 2.3 Las 6 claves

| Clave | Valores | Default | Por qué |
|---|---|---|---|
| `enabled` | true/false | true | Silenciar un repo sin borrar su config. |
| `mode` | review/autosync | review | La respuesta para `nube`: stage + commit con mensaje generado + push, sin diálogo, solo log. |
| `stage` | all/tracked | all | `git add -u` en vez de `-A` para repos con `.gitignore` flojo. |
| `untracked` | include/ignore | include | `-uno` en el chequeo de sucio, para repos con ruido permanente. No para `nube`. |
| `sign` | true/false | hereda global | Firmar un push a un repo desnudo en un USB es teatro; en un repo de GitHub sí importa. |
| `push` | ask/auto/never | ask | `auto` para autosync; `never` para repos que se quedan locales a propósito. |

### 2.4 Presets, no 6 dropdowns

En el panel por repo: dos botones — **"Proyecto"** (comportamiento
actual) y **"Carpeta de sincronización"** (`mode=autosync`, `stage=all`,
`push=auto`, `sign=false` — esto es `nube`), más un disclosure para las
claves crudas.

### 2.5 Reglas de seguridad de `autosync` (no negociables)

`autosync` debe caer al diálogo normal (nunca commitear en silencio) si:
1. El escaneo de archivos sensibles encuentra algo (y ver Q3 — hoy está roto para directorios sin trackear).
2. Algún archivo a agregar pesa más de 100 MB (`nube` ya tiene un zip de 3.1 GB en su historial — así es como pasó).
3. Hay un merge/rebase/cherry-pick en curso.
4. HEAD está detached.
5. `user.email`/`user.name` sin configurar.

### 2.6 El problema de `.DS_Store` en `nube`

121 `.DS_Store` trackeados, sin `.gitignore` — cada ventana de Finder
ensucia el repo. Con `autosync` eso sería un commit por visita a Finder.
Arreglo nativo, no un filtro propio de RepoWatch: botón "Ignorar
.DS_Store" en el panel del repo → agrega a `.git/info/exclude` +
`git rm --cached -- '*.DS_Store'`.

## 3. Nivel 1 — Ganancias rápidas (chicas, bajo riesgo, alto valor)

- **Q1.** Scheduler nunca se inicializa (§1). El cambio de más valor de todo el documento.
- **Q2.** No hay timestamp de "última revisión" — un checker muerto es indistinguible de uno sano. Escribir `last_check.txt` en cada corrida (limpia o no) y mostrar "hace 12 min" en el menú.
- **Q3 (seguridad).** El escaneo de archivos sensibles usa `git status --short`, que colapsa un directorio sin trackear a una sola línea (`secrets/`) — `find_sensitive_files` nunca ve `secrets/id_rsa` y `git add -A` lo commitea sin avisar. Usar `git status --porcelain -uall`.
- **Q4.** Si `git` no está instalado, todo falla en silencio y el log dice que todo está bien para siempre. Verificar `git --version` al inicio y mostrar error explícito.
- **Q5.** `git fetch` sin tty puede colgarse esperando credenciales indefinidamente. Agregar `GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND` con `BatchMode=yes` y timeout.
- **Q6.** Nada evita que el Timer y "Revisar ahora" corran a la vez → `index.lock`, diálogos duplicados. Lock por directorio (`mkdir` atómico).
- **Q7.** Los diálogos de `osascript` no tienen `giving up after` — un diálogo sin responder detiene los chequeos para siempre.
- **Q8.** El diálogo de revisión no dice "repo 2 de 5".
- **Q9.** No hay forma de cancelar el loop de revisión completo (solo Omitir repo por repo).
- **Q10.** Si `git add -A` funciona pero `git commit` falla, el índice queda mutado sin deshacer.
- **Q11.** Los fallos de fetch nunca se muestran (a propósito para discos externos desconectados) — pero también esconde credenciales de GitHub expiradas. Clasificar: remoto local ausente = silencio; remoto remoto = avisar tras 3 fallos seguidos.
- **Q12.** Un repo dentro de una carpeta vigilada y además listado en `repos.txt` genera diálogo duplicado.
- **Q13.** Submódulos y worktrees tienen `.git` como archivo, no carpeta — el chequeo `-d` los ignora en silencio.
- **Q14.** Un archivo de config editado a mano sin newline final pierde la última línea.
- **Q15.** Archivos temporales en rutas fijas (`/tmp/git_fetch_err`) — usar `mktemp`.
- **Q16.** El log crece sin rotar.
- **Q17.** "Ver log" puede abrir un archivo que no existe.
- **Q18.** El estado del menú puede estar desactualizado hasta 60s; "Revisar ahora" asume 5s fijos aunque el chequeo tome más.
- **Q19.** "Revisar y commitear…" está siempre habilitado aunque no haya nada pendiente.
- **Q20.** Guardar preferencias puede pisar claves que no conoce la UI (ej. si se agregan overrides por repo después).
- **Q21.** Info.plist sin `LSMinimumSystemVersion` ni `CFBundleVersion`.
- **Q22.** Con muchos repos pendientes, el diálogo de resumen puede salirse de la pantalla.

## 4. Nivel 2 — Medio (trabajo real, alcance contenido)

- **M1.** Configuración por repo completa (§2): `repo_overrides.txt`, las 6 claves, `autosync` con sus 5 guardas, panel con presets.
- **M2.** Notificaciones nativas desde Swift (`UNUserNotificationCenter`) en vez de `osascript display notification` — hoy el banner aparece atribuido a "Script Editor", no a RepoWatch, y si el usuario alguna vez desactivó notificaciones de Script Editor, las de RepoWatch se pierden en silencio.
- **M3.** Detectar commits locales sin subir ("ahead"), no solo "behind" — y agregar acción de Pull. Hoy si ambos discos de `nube` están desconectados al hacer commit, el push se salta y el repo queda "limpio" con commits atrapados localmente, sin aviso.
- **M4.** Toggle de "abrir al iniciar sesión" en Preferencias (`SMAppService`), en vez del comando `osascript` manual del README.
- **M5.** Mostrar `git diff --stat` (no solo nombres) en el diálogo de revisión + guarda de tamaño (rechazar/avisar sobre 100 MB) — habría hecho obvio el zip de 3.1 GB antes de commitearlo.
- **M6.** Escaneo de secretos por contenido, no solo por nombre de archivo (detectar patrones tipo `AKIA…`, `gh_…`, `-----BEGIN PRIVATE KEY-----` en el diff antes de commitear).
- **M7.** Deshacer el último commit hecho por RepoWatch (solo si no se ha pusheado).
- **M8.** Vista de historial dentro de Preferencias (últimas ~200 líneas del log).
- **M9.** Posponer 1 hora en vez de solo Cerrar/Revisar.
- **M10.** Validar rutas al agregarlas (¿es un repo git? ¿ya está agregada?), marcar visualmente las que dejaron de existir.

## 5. Nivel 3 — Grande (arquitectura)

- **L1.** Reemplazar los diálogos `osascript` por una ventana SwiftUI real para la revisión (diff real, staging parcial, cancelar de verdad, sin límite de 3 botones). Es la raíz de Q7/Q8/Q9/M5. Vale la pena solo si el flujo de revisión se usa seguido — si se usa dos veces al mes, Q7–Q9+M5 dan el 80% del valor por 5% del esfuerzo.
- **L2.** Hacer el fetch multi-remoto: hoy `git fetch` sin argumentos solo trae del remoto configurado de la rama (`origin` para `nube`, el disco casi nunca conectado) — `ssd` nunca se fetchea, así que "atrás de ssd" es indetectable estructuralmente. Este es el arreglo real para el caso `nube`, más que cualquier config.
- **L3.** Una sola fuente de verdad para el parseo de config — hoy Swift y bash implementan cada uno su propio parser para los mismos formatos y ya difieren en casos borde (línea final sin newline).
- **L4.** Despersonalizar el build para "cualquiera": rutas hardcodeadas en `build.sh`, bundle id fijo, strings solo en español, `codesign --deep` (flag deprecado).
- **L5.** Un test mínimo: `selftest.sh` sin framework que arme repos de prueba en `$TMPDIR` y verifique discovery + resolución de overrides + detección de sensibles (incluyendo el caso de directorio sin trackear de Q3).

## 6. Top 3 acciones recomendadas

1. **Arreglar el scheduler (Q1) + timestamp de última revisión (Q2) juntos.** La promesa central de la app — revisar periódicamente — nunca ha funcionado, y el timestamp asegura que una futura regresión sea visible en el menú en vez de pasar meses desapercibida.
2. **Arreglar el hueco de directorios sin trackear en el escaneo de secretos (Q3), la mutación del índice sin deshacer (Q10), y la guarda de tamaño (parte de M5).** Son las tres formas en que RepoWatch puede hacerle daño irreversible a un repo hoy, y `nube` (9.4 GB de `.git` con un zip de 3.1 GB adentro) es prueba de que el caso de tamaño no es hipotético. Hacerlas antes de habilitar `autosync`, que saca al humano del loop por completo.
3. **Implementar configuración por repo (M1) con el diseño de `repo_overrides.txt` del §2, y configurar `nube` con el preset "Carpeta de sincronización".** Es el pedido original, y el diseño es deliberadamente aditivo: ningún archivo de config existente cambia de formato, ningún parser se rompe, y los dos presets mantienen la UI en un clic para todo el que no tenga un caso como `nube`.

Orden sugerido después de eso: Q4–Q7 (cuelgues, carreras, diálogos
apilados) → Q12–Q16 (parseo/higiene) → M2 (atribución de notificaciones)
→ M3 (sin subir/pull) → decidir sobre L1 solo una vez que se sepa qué
tanto se usa de verdad el flujo de revisión.
