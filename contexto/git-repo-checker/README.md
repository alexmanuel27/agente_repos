# Git Repo Checker

Agente que revisa cada hora si alguno de los repos vigilados está desactualizado
respecto a su remoto y/o tiene cambios sin commitear, y avisa con una
notificación nativa de macOS.

## RepoWatch (app de barra de menús)

`RepoWatchApp/` es una app SwiftUI mínima (un solo archivo, sin Xcode) que
pone un ícono en la barra de menús con el mismo estado que `STATE_FILE`, y
botones para "Revisar y commitear…", "Revisar ahora" y "Ver log" — solo
llama a los scripts de abajo, no reimplementa nada. Instalada en
`/Users/alex/Applications/RepoWatch.app` y agregada a los ítems de inicio de
sesión. Para reconstruirla tras editar `main.swift` o `gen_icon.swift`:

```bash
/Users/alex/scripts/GitRepoCheckerApp/build.sh
```

No está (ni tiene sentido que esté) en la App Store: usa `Process`/`bash`
para correr los scripts y tiene rutas personales hardcodeadas — el sandbox de
la App Store bloquea justo eso, y no es un producto multiusuario.

## Qué repos vigila

1. **Todas** las subcarpetas de `/Users/alex/Nube /repos/` que contienen un
   `.git` (no hay una lista fija: cualquier repo nuevo que se ponga ahí se
   incluye automáticamente).
2. Las rutas absolutas listadas en `extra_repos.txt` (una por línea, líneas
   que empiezan con `#` se ignoran) — para repos fuera de esa carpeta.
   Instalado en `/Users/alex/scripts/extra_repos.txt`.

## Qué hace

Para cada repo:

1. Hace `git fetch` y compara `HEAD` contra su upstream (`@{u}`) con
   `git rev-list --count HEAD..@{u}`. Si el fetch falla (por ejemplo, un
   remoto en un disco externo que no está conectado), solo se registra el
   error en el log — no genera notificación falsa.
2. Corre `git status --porcelain` para detectar cambios sin commitear
   (staged, modificados o sin trackear), sin depender de que el fetch haya
   funcionado.

Si algún repo quedó desactualizado y/o con cambios sin commitear:

1. Dispara una notificación de macOS (banner con sonido).
2. Guarda el detalle en `STATE_FILE` (`/Users/alex/scripts/last_check_state.txt`).
3. Muestra automáticamente una ventana flotante (`display dialog`) con el
   detalle completo, repo por repo: cuántos commits detrás está y/o cuántos
   archivos tiene sin commitear. La ventana se queda en pantalla hasta que
   se le da OK.

No se usa un banner "clickeable" con acción — se probó con `terminal-notifier`,
pero macOS bloquea (o cuelga) las solicitudes de permiso de notificación de
apps sin firma de Apple válida en versiones recientes del sistema, así que no
es viable de forma confiable. Por eso la ventana se abre directo en vez de
depender de que el usuario toque la notificación.

Si hay repos con **cambios sin commitear**, la ventana flotante tiene un botón
extra "Revisar y commitear" que lanza `review_and_commit.sh` (ver abajo).

Además deja un registro en el log. Si todo está en orden, solo escribe una
línea en el log (sin notificación ni ventana), y borra el `STATE_FILE`.

## Revisión interactiva: add, commit firmado y push (`review_and_commit.sh`)

Recorre los repos con cambios sin commitear y, uno por uno, muestra una
ventana con: rama actual, lista de archivos cambiados (hasta 20, con conteo
del resto) y un campo de texto para el mensaje de commit — **pre-llenado con
una sugerencia** generada a partir de los archivos cambiados (lista los
nombres si son ≤3, o las carpetas de nivel superior si son más). Botones:

- **Omitir** — no toca el repo, sigue con el siguiente.
- **Commit** — `git add -A` + `git commit -S` (firmado, ver abajo).
- **Commit + Push** — lo anterior + `git push`.

Antes de tocar el repo, revisa los nombres de los archivos cambiados contra
una lista de patrones de posibles secretos (`.env`, `*.pem`, `*.key`,
`id_rsa*`, `*credentials*.json`, etc.). Si encuentra alguno, muestra una
alerta con la lista y obliga a elegir explícitamente "Continuar" antes de
seguir — por defecto omite el repo.

### Firma de commits (SSH)

Los commits se firman con `git commit -S`, usando la llave SSH ya configurada
globalmente para esto:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
```

(`commit.gpgsign` se deja sin activar a propósito, para no firmar automáticamente
los commits que hagas por fuera de este flujo.) Para que GitHub marque estos
commits como **"Verified"**, hay que agregar esa misma llave pública como
**Signing Key** (no "Authentication Key") en
[github.com/settings/keys](https://github.com/settings/keys) — paso manual,
no lo puede hacer el agente.

## Archivos

- `check_git_repos.sh` — el script principal (instalado en
  `/Users/alex/scripts/check_git_repos.sh`).
- `review_and_commit.sh` — el flujo interactivo de add/commit/push
  (instalado en `/Users/alex/scripts/review_and_commit.sh`).
- `lib_discover_repos.sh` — función compartida `discover_repos()` que
  arma la lista de repos vigilados (instalado en
  `/Users/alex/scripts/lib_discover_repos.sh`).
- `show_pending_repos.sh` — vuelve a mostrar la ventana con el último
  detalle guardado en `STATE_FILE`, para consultarlo manualmente en
  cualquier momento (instalado en `/Users/alex/scripts/show_pending_repos.sh`).
- `extra_repos.txt` — lista de repos adicionales a vigilar (instalado en
  `/Users/alex/scripts/extra_repos.txt`). Actualmente incluye `/Users/alex/Nube /nube`
  (sus remotos están en discos externos, así que el chequeo de "atrás del
  remoto" solo funciona cuando el disco está montado).
- `com.alex.checkgitrepos.plist` — LaunchAgent de macOS que ejecuta el script
  cada hora (instalado en `~/Library/LaunchAgents/com.alex.checkgitrepos.plist`).

Estos archivos son la copia de referencia versionada en git; los que
realmente se ejecutan viven fuera del repo (ver rutas arriba) porque
`launchd` no puede apuntar de forma confiable a un path dentro de una carpeta
sincronizada por otro servicio (Nube).

## Log

`/Users/alex/scripts/logs/check_git_repos.log`

## Administración

Activar/recargar el agente:

```bash
launchctl unload ~/Library/LaunchAgents/com.alex.checkgitrepos.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.alex.checkgitrepos.plist
```

Desactivarlo:

```bash
launchctl unload ~/Library/LaunchAgents/com.alex.checkgitrepos.plist
```

Ver si está corriendo:

```bash
launchctl list | grep checkgitrepos
```

Correrlo manualmente (sin esperar a la hora):

```bash
/Users/alex/scripts/check_git_repos.sh
```

Volver a ver el detalle de la última corrida sin re-chequear nada:

```bash
/Users/alex/scripts/show_pending_repos.sh
```

Lanzar la revisión interactiva (add/commit/push) directamente, sin pasar por
la notificación:

```bash
/Users/alex/scripts/review_and_commit.sh
```

## Notas

- `StartInterval` está en `3600` segundos (1 hora) y `RunAtLoad` hace que
  también corra apenas se carga el agente (por ejemplo, al iniciar sesión).
- Si se edita `check_git_repos.sh`, los cambios aplican de inmediato en la
  próxima corrida — no hace falta recargar el LaunchAgent (solo cambia si se
  edita el `.plist`).
