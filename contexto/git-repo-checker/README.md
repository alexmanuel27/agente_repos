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

## Instalar / compilar

```bash
RepoWatchApp/build.sh
```

Compila y firma (ad-hoc) `/Users/alex/Applications/RepoWatch.app` — para
usarlo en otra cuenta, cambiar esa ruta en `build.sh`. Para que arranque
solo al iniciar sesión:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {name:"RepoWatch", path:"/Users/alex/Applications/RepoWatch.app", hidden:false}'
```

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
`watch_folders.txt`, `repos.txt`, `settings.txt`, `last_check_state.txt` y
`logs/check_git_repos.log`.

## Qué hace, repo por repo

1. `git fetch`; si falla (ej. remoto en un disco externo desconectado), solo
   se registra en el log, sin alertar — no es un error real.
2. Compara `HEAD` contra su upstream para ver si está atrás.
3. `git status --porcelain` para detectar cambios sin commitear.

Si algo quedó pendiente: notificación con sonido + ventana flotante con el
detalle. Si además hay cambios sin commitear, la ventana ofrece un botón
"Revisar y commitear" que abre, uno por uno, un diálogo por repo con: rama,
archivos cambiados, y un campo de mensaje de commit pre-llenado con una
sugerencia. Antes de tocar el repo, avisa si algún archivo cambiado parece
un secreto (`.env`, `*.pem`, `id_rsa*`, `*credentials*.json`, etc.) y exige
confirmar explícitamente antes de seguir. Al hacer push, prueba cada remoto
configurado y usa el primero que responda (útil para repos con un remoto en
un disco externo que a veces no está conectado).

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
    check_git_repos.sh     # revisión periódica → notificación + ventana
    review_and_commit.sh   # flujo interactivo add/commit firmado/push
    lib_discover_repos.sh  # arma la lista de repos desde la config del usuario
    lib_settings.sh        # lee horario/firma desde settings.txt
```

Los `.sh` quedan empacados en `Contents/Resources/scripts/` dentro del
`.app` — la app es portable, no depende de nada fuera de sí misma más que
del directorio de config del usuario.
