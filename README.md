# amutorrent-scripts

Scripts de post-procesamiento para [aMuTorrent](https://github.com/got3nks/amutorrent), la webUI para aMule.

## Descripción

Cuando aMuTorrent detecta que una descarga finalizó, invoca `amutorrent.sh` con el evento como parámetro y los datos de la descarga por stdin. El script se encarga de escanear el archivo, transferirlo al destino correspondiente según su categoría, generar una ficha informativa y, si es video, buscar subtítulos automáticamente.

## Archivos

| Archivo | Descripción |
|---|---|
| `amutorrent.sh` | Script principal, invocado por aMuTorrent |
| `subs.sh` | Búsqueda y descarga de subtítulos |
| `amutorrent.env` | Configuración y credenciales |

## Requisitos

- aMuTorrent con aMule
- `jq`, `curl`, `python3`, `unzip` disponibles en el contenedor
- Los siguientes servicios corriendo y accesibles:
  - [Gotify](https://gotify.net/) — notificaciones push
  - [ClamAV REST](https://github.com/benzino77/clamav-rest-api) — antivirus
  - [Transferr](https://github.com/osdaeg/transferr) — transferencia de archivos
  - [Butler](https://github.com/osdaeg/butler) — generación de fichas con Gemini
  - [Paste.sh](https://github.com/osdaeg/paste.sh) — para subir logs ante errores
  - [OpenSubtitles API](https://opensubtitles.stoplight.io/) — subtítulos
  - [SubDL API](https://subdl.com/) — subtítulos (fallback)

## Instalación

1. Copiar `amutorrent.sh` y `subs.sh` a `/scripts/` dentro del contenedor (o al volumen montado correspondiente).
2. Copiar `amutorrent.env` a `/config/` y editar con los valores del entorno.
3. Dar permisos de ejecución:
   ```bash
   chmod +x /scripts/amutorrent.sh /scripts/subs.sh
   ```
4. En la configuración de aMuTorrent, apuntar el script de post-descarga a `/scripts/amutorrent.sh`.

## Configuración

Toda la configuración se centraliza en `amutorrent.env`:

```bash
# URLs de servicios
HOST="192.168.88.100"
BASEDIR=/scripts
GOTIFY_URL="${HOST}:8088/message"
# ...

# Comportamiento (yes/no)
NOTIFICATIONS="yes"
SCAN="yes"
TRANSFER="yes"
CARDS="yes"
SUBTITLES="yes"
PASTEBIN="yes"
```

### Flags de comportamiento

| Flag | Descripción |
|---|---|
| `NOTIFICATIONS` | Enviar notificaciones por Gotify |
| `SCAN` | Escanear archivos con ClamAV antes de procesarlos |
| `TRANSFER` | Transferir archivos al destino según categoría |
| `CARDS` | Generar fichas informativas con Butler-API |
| `SUBTITLES` | Buscar subtítulos (solo categorías de video) |
| `PASTEBIN` | Subir el log a Pastebin ante errores inesperados |

## Flujo de procesamiento

```
downloadFinished
      │
      ▼
 [SCAN] Escaneo antivirus
      │ infectado → eliminar + notificar + salir
      │ video     → omitir escaneo
      │ limpio    → continuar
      ▼
 [TRANSFER] Transferencia según categoría
      │ Libros      → calibre + booklore
      │ Historietas → comics
      │ Música      → slskd
      │ video/otros → sin transferencia
      ▼
 [CARDS] Generación de ficha con Butler-API
      │ según extensión y categoría
      ▼
 [SUBTITLES] Búsqueda de subtítulos
      └ solo amule-radarr y amule-sonarr
```

## Categorías soportadas

| Categoría en aMuTorrent | Transferencia | Fichas | Subtítulos |
|---|---|---|---|
| `Libros` | calibre, booklore | ✅ | ❌ |
| `Historietas` | comics | ✅ | ❌ |
| `Música` | slskd | ✅ | ❌ |
| `amule-radarr` | — | ✅ | ✅ |
| `amule-sonarr` | — | ✅ | ✅ |
| otros | — | ❌ | ❌ |

## Subtítulos (subs.sh)

El script puede usarse también de forma independiente:

```bash
./subs.sh "/ruta/al/video.mkv" [amule-radarr|amule-sonarr] [opensubtitles|subdl]
```

El flujo de búsqueda automática es:
1. OpenSubtitles → español latino (`es-la`)
2. OpenSubtitles → español (`es`)
3. SubDL → español
4. OpenSubtitles → inglés con traducción automática (`ai_translated`)

El subtítulo se guarda junto al archivo de video (`.srt` con el mismo nombre) y se copia además a `$BASEDIR/subs/` como pool de referencia.

## Logs

- `amutorrent.sh` → `/scripts/finished.log`
- `subs.sh` → `/scripts/subs.log`

Ante un error inesperado (si `PASTEBIN="yes"`), las últimas 100 líneas del log se suben automáticamente al Pastebin propio y se envía una notificación urgente por Gotify con la URL.
