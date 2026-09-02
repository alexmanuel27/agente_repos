# Git Repo Checker

Agente que revisa cada hora si alguno de los repos vigilados está desactualizado
respecto a su remoto y/o tiene cambios sin commitear, y avisa con una
notificación nativa de macOS.

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

Si algún repo quedó desactualizado y/o con cambios sin commitear, dispara una
notificación de macOS (con sonido) que lista, en líneas separadas, cada caso.
Además deja un registro en el log. Si todo está en orden, solo escribe una
línea en el log (sin notificación).

## Archivos

- `check_git_repos.sh` — el script (instalado en `/Users/alex/scripts/check_git_repos.sh`).
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

## Notas

- `StartInterval` está en `3600` segundos (1 hora) y `RunAtLoad` hace que
  también corra apenas se carga el agente (por ejemplo, al iniciar sesión).
- Si se edita `check_git_repos.sh`, los cambios aplican de inmediato en la
  próxima corrida — no hace falta recargar el LaunchAgent (solo cambia si se
  edita el `.plist`).
