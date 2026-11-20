# RepoWatch

App de barra de menús para macOS (SwiftUI, un solo target, sin Xcode) que
vigila repos git configurables por el usuario: cada tantos minutos revisa
si están desactualizados respecto a su remoto y/o tienen cambios sin
commitear, avisa con notificación + ventana flotante, y deja hacer
`add` / `commit` (firmado opcionalmente) / `push` repo por repo desde ahí
mismo.

No depende de rutas de un usuario en particular ni de un LaunchAgent
externo — todo vive dentro de la app (source en `RepoWatchApp/`) y del
directorio de config por usuario en
`~/Library/Application Support/RepoWatch/`. No está en la App Store: usa
`Process`/`bash` para correr los scripts, y el sandbox de la App Store
bloquea justo eso.

Las notificaciones son nativas de la app (`UNUserNotificationCenter`,
verificado que sí obtiene permiso pese a estar firmada ad-hoc — a
diferencia de `terminal-notifier`, que falló con esto); si el permiso
nativo llegara a fallar, cae automáticamente a `osascript display
notification` como respaldo (`NotificationWatcher` en `main.swift`).

## Instalar / compilar

```bash
RepoWatchApp/build.sh
```

Compila y firma (ad-hoc) `/Users/alex/Applications/RepoWatch.app` — para
usarlo en otra cuenta, cambiar esa ruta en `build.sh`. El toggle "Abrir
RepoWatch al iniciar sesión" en Preferencias → Horario lo registra como
ítem de inicio vía `SMAppService` (no hace falta el comando `osascript`
de versiones anteriores de este README).

## Configuración (Preferencias, desde el menú de la app)

Todo editable en la UI, sin tocar archivos a mano:

- **Carpetas vigiladas**: se revisan todos los repos que haya directamente
  adentro (subcarpetas con `.git`).
- **Repos individuales**: rutas sueltas, para repos fuera de esas carpetas.
- **Horario**: cada cuántos minutos revisar (15–1440).
- **Firma de commits (SSH)**: activar/desactivar, y qué llave pública usar.
  Se aplica solo al hacer commit desde la app (`git -c gpg.format=ssh -c
  user.signingkey=...`), sin tocar la config global de git del usuario. Para
  que GitHub marque los commits como **"Verified"**, la llave pública elegida
  debe estar agregada como **Signing Key** (no "Authentication Key") en
  [github.com/settings/keys](https://github.com/settings/keys) — paso manual
  del usuario.

Los datos por usuario quedan en `~/Library/Application Support/RepoWatch/`:
`watch_folders.txt`, `repos.txt`, `settings.txt`, `repo_overrides.txt`,
`last_check_state.txt`, `last_check.txt` (timestamp de la última corrida,
se muestra como "hace N min" en el menú) y `logs/check_git_repos.log`.

### Configuración por repo (`repo_overrides.txt`)

Un repo no tiene por qué comportarse como un proyecto normal de GitHub —
por ejemplo uno que es en realidad una carpeta de sincronización personal,
con remotos en discos externos que a veces no están conectados. Para esos
casos, en **Repos individuales** cada fila tiene un botón que alterna entre:

- **Proyecto** (default): revisión normal, diálogo por commit.
- **Sync**: `mode=autosync` — commitea y pushea solo, sin diálogo, cada vez
  que hay cambios. Antes de tocar el repo corre las mismas guardas de
  seguridad que el flujo interactivo (archivos sensibles, archivos > 100MB,
  merge/rebase en curso, HEAD separado, `user.email`/`user.name` sin
  configurar) — si alguna salta, cae al flujo normal en vez de commitear
  a ciegas.

El archivo es texto plano, `ruta TAB clave TAB valor`, una línea por
override (última línea gana). Claves: `enabled`, `mode`, `stage`
(`all`/`tracked`, o sea `git add -A` vs `-u`), `untracked`
(`include`/`ignore`), `sign`, `push` (`ask`/`auto`/`never`). Se resuelven
con `repo_get()` en `lib_repo_config.sh`, compartida por
`check_git_repos.sh` y `review_and_commit.sh`.

## Qué hace, repo por repo

1. `git fetch` con `GIT_TERMINAL_PROMPT=0` (nunca se cuelga pidiendo
   credenciales sin tty); si falla (ej. remoto en un disco externo
   desconectado), solo se registra en el log, sin alertar.
2. Compara `HEAD` contra su upstream: cuántos commits atrás (`behind`) y
   cuántos sin subir (`ahead`).
3. `git status --porcelain --untracked-files=all` para detectar cambios sin
   commitear (expande carpetas sin trackear a archivos individuales — con
   `-unormal`, que es el default de git, una carpeta entera se colapsa a
   una línea y el escaneo de secretos nunca ve lo de adentro).

Si algo quedó pendiente (atrás / sin subir / sin commitear): notificación +
ventana flotante con el detalle, con un botón de acción según lo más urgente
presente (Revisar y commitear > Pushear pendientes > Actualizar), más
"Posponer 1h" para silenciar el aviso sin perder de vista el estado real en
el menú. Un chequeo o revisión en curso usa un lock (`mkdir` atómico) para
que el Timer y un clic manual no corran a la vez, y los diálogos se rinden
solos tras 10–15 min si nadie responde, para no detener los chequeos para
siempre.

Si además hay cambios sin commitear, la ventana ofrece "Revisar y
commitear", que abre, uno por uno, un diálogo por repo con: rama, archivos
cambiados, `git diff --stat`, y un campo de mensaje de commit pre-llenado
con una sugerencia. Antes de tocar el repo, avisa (y exige confirmar
explícitamente) si algún archivo cambiado parece un secreto por nombre
(`.env`, `*.pem`, `id_rsa*`, `*credentials*.json`, etc.) o pesa más de
100MB; después de stagear pero antes de commitear, también busca patrones
de credenciales en el **contenido** de lo cambiado (no solo en el nombre
del archivo). Si el commit falla después de un `add` exitoso, el índice se
restaura a como estaba (nunca queda a medias). Al hacer push, prueba cada
remoto configurado y usa el primero que responda.

Cada commit hecho por RepoWatch queda registrado (`last_commits.txt`) para
poder deshacerlo desde el menú — solo mientras siga siendo el commit más
reciente del repo y no se haya pusheado.

## Estructura

```
RepoWatchApp/
  main.swift              # MenuBarExtra + Scheduler (Timer según Preferencias)
  Config.swift             # lectura/escritura de la config compartida con los scripts
  PreferencesView.swift    # ventana de Preferencias
  gen_icon.swift           # genera el ícono de la app (SF Symbol sobre fondo de color)
  Info.plist
  build.sh
  Resources/scripts/
    check_git_repos.sh     # revisión periódica → notificación + ventana; corre autosync
    review_and_commit.sh   # flujo interactivo add/commit firmado/push
    push_pending.sh        # pushea commits "ahead" en todos los repos
    pull_pending.sh        # git pull --ff-only en los repos "behind"
    undo_commit.sh         # deshace el último commit de RepoWatch en un repo
    list_undoable.sh       # qué repos tienen un commit deshacible ahora mismo
    lib_discover_repos.sh  # arma la lista de repos desde la config del usuario
    lib_settings.sh        # lee horario/firma desde settings.txt
    lib_repo_config.sh     # repo_get(): overrides por repo (repo_overrides.txt)
    lib_commit_safety.sh   # escaneo de sensibles/archivos grandes/secretos, autosync_commit()
```

Los `.sh` quedan empacados en `Contents/Resources/scripts/` dentro del
`.app` — la app es portable, no depende de nada fuera de sí misma más que
del directorio de config del usuario.


## Modo automático (Preferencias → Horario)

Con el interruptor activo, cada revisión hace sola, en todos los repos que no
estén en modo manual: commit (asunto = título del proyecto en el vault + lo
cambiado; cuerpo = última línea del Registro de su nota si es de los últimos
7 días, sin IA), pull (ff-only; merge si hay commits propios; si choca se
aborta) y push (al primer remoto que responda). Solo avisa de **problemas**
(conflicto, archivo sensible o >100MB, push rechazado, commit fallido) y solo
cuando el problema cambia o pasan 24 h. El panel de la barra superior lee
`repo_status.tsv` cada 2 s: una fila por repo (ok / actuó solo / en espera /
problema). Prueba: `RepoWatchApp/tests/test_autosync.sh`.

## Carpetas → repos → ajustes por repo

En Preferencias → Carpetas cada carpeta se despliega y lista sus repos con
su transporte (SSH/HTTPS). Entrar a un repo permite editar la URL de cada
remoto, «Pasar a SSH», probar que responde, vigilarlo o no, y elegir su modo
(global / automático / manual). «Pasar N repo(s) a SSH» convierte todos los
de la carpeta y deja en HTTPS los que no respondan por SSH.

## Excepción de archivos de más de 100MB (repos con remoto GitHub)

GitHub rechaza archivos >100MB, así que en modo automático, antes del push:
los archivos grandes **sin trackear** se añaden a `.gitignore` y no se
commitean; si ya están en commits **sin subir** (los que no están en ninguna
ref remota), se sacan de esos commits con `git filter-branch`, se ignoran y se
hace un commit «Ignora archivos de más de 100MB (RepoWatch)»; luego sigue el
push. El archivo nunca se borra del disco (filter-branch lo borraría; se
restaura desde la copia). Antes de reescribir se guarda
`refs/repowatch/backup/<fecha>` (recuperable con `git reset --hard <ref>`).
Siempre avisa con una notificación. Solo toca lo no subido, con árbol limpio,
y no aplica a repos sin remoto GitHub (ej. `nube`, discos locales). Los
commits reescritos pierden su firma SSH. Prueba: `tests/test_autosync.sh`.

## Una sola conexión SSH para todos los repos

Los scripts usan `RW_SSH` (en `lib_discover_repos.sh`): SSH sin preguntar y con
`ControlMaster`, o sea una conexión por host reutilizada por todos los repos.
Sin eso, cada fetch/ls-remote/push abría una conexión nueva y GitHub cortaba
con «Connection reset by peer», así que muchos repos salían como «remoto no
disponible». El motivo real del fallo ahora se muestra en el panel.

## Ficha de cada repo (Preferencias → Carpetas → repo)

Además de remotos y modo, muestra el estado actual (rama, cambios sin
commitear, atrás/adelante del remoto, commits sin subir), los últimos 12
commits (con marca de los que aún no están en ningún remoto) y lo que
RepoWatch hizo en ese repo según el log.
