# Git Repo Checker

Agente que revisa cada hora si alguno de los repos en `/Users/alex/Nube /repos/` está
desactualizado respecto a su remoto, y avisa con una notificación nativa de macOS.

## Qué hace

1. Recorre **todas** las subcarpetas de `/Users/alex/Nube /repos/` que contienen un
   `.git` (no hay una lista fija de repos: cualquier repo nuevo que se ponga ahí
   se incluye automáticamente).
2. Para cada repo, hace `git fetch` y compara `HEAD` contra su upstream
   (`@{u}`) con `git rev-list --count HEAD..@{u}`.
3. Si algún repo tiene commits pendientes de traer, arma la lista de repos
   desactualizados y dispara una notificación de macOS (con sonido) que
   muestra, en líneas separadas, cada repo con la cantidad de commits detrás
   y su rama upstream. Además deja un registro en el log.
4. Si todos los repos están al día, solo escribe una línea en el log (sin
   notificación).

## Archivos

- `check_git_repos.sh` — el script (instalado en `/Users/alex/scripts/check_git_repos.sh`).
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

## Notas

- `StartInterval` está en `3600` segundos (1 hora) y `RunAtLoad` hace que
  también corra apenas se carga el agente (por ejemplo, al iniciar sesión).
- Si se edita `check_git_repos.sh`, los cambios aplican de inmediato en la
  próxima corrida — no hace falta recargar el LaunchAgent (solo cambia si se
  edita el `.plist`).
