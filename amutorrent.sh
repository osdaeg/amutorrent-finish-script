#!/bin/bash
# =============================================================
# amutorrent.sh - Script post-descarga de aMuTorrent
# Ubicación: /scripts/amutorrent.sh
# =============================================================

# --- Configuración ---
source /config/amutorrent.env

# --- Logging ---
log() {
    echo "$($DATE '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# --- Helpers ---
get_extension() {
    local filename="$1"
    echo "${filename##*.}" | tr '[:upper:]' '[:lower:]'
}

extension_in_list() {
    local ext="$1"
    local list="$2"
    for e in $list; do
        [ "$ext" = "$e" ] && return 0
    done
    return 1
}

gotify_notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-5}"
    if [ "$NOTIFICATIONS" == "yes" ]; then
        $CURL -s -X POST "$GOTIFY_URL" \
            -H "X-Gotify-Key: $GOTIFY_TOKEN" \
            -F "title=${title}" \
            -F "message=${message}" \
            -F "priority=${priority}" >> "$LOG_FILE" 2>&1
    fi        
}

# Sube el log a pastebin y notifica por Gotify con la URL
# $1 = contexto del error
paste_error() {
    local context="${1:-error desconocido}"
    local log_content
    log_content=$(tail -100 "$LOG_FILE" 2>/dev/null)
    [ -z "$log_content" ] && log_content="(sin log disponible)"

    local payload
    payload=$(printf '{"title":"amutorrent: %s — %s","content":%s,"language":"plaintext","ttl_seconds":604800}' \
        "$FILENAME" \
        "$context" \
        "$(echo "$log_content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

    local resp paste_id paste_url
    resp=$($CURL -s -X POST "${PASTEBIN_URL}/api/pastes" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    paste_id=$(echo "$resp" | $JQ -r '.id // empty' 2>/dev/null)

    if [ -n "$paste_id" ]; then
        paste_url="${PASTEBIN_URL}/p/${paste_id}"
        log "Log subido a pastebin: ${paste_url}"
        gotify_notify \
            "❌ Error en amutorrent" \
            "📁 ${FILENAME}
⚠️ ${context}
📋 Log: ${paste_url}" \
            10
    else
        log "No se pudo subir el log a pastebin."
        gotify_notify \
            "❌ Error en amutorrent" \
            "📁 ${FILENAME:-desconocido}
⚠️ ${context}
(pastebin no disponible)" \
            10
    fi
}

# =============================================================
# MAIN
# =============================================================

# Trap global: ante cualquier error inesperado sube el log y notifica
if [ "$PASTEBIN" == "yes" ]; then
    trap 'paste_error "error inesperado en línea $LINENO (exit $?)"' ERR
fi    

EVENT="$1"

log "============================================================"
log "Evento recibido: $EVENT"

# Leer JSON desde stdin
EVENT_JSON=$(cat)

# Solo procesar downloadFinished
if [ "$EVENT" != "downloadFinished" ]; then
    log "Evento ignorado: $EVENT"
    exit 0
fi

# Parsear JSON
FILENAME=$($JQ -r '.filename' <<< "$EVENT_JSON")
FILEPATH=$($JQ -r '.path'     <<< "$EVENT_JSON")
CATEGORY=$($JQ -r '.category' <<< "$EVENT_JSON")
SIZE=$($JQ    -r '.size'      <<< "$EVENT_JSON")

SIZE_MB=$(echo "scale=2; $SIZE / 1048576" | /usr/bin/bc)

log "Archivo   : $FILENAME"
log "Ruta      : $FILEPATH"
log "Categoría : $CATEGORY"
log "Tamaño    : ${SIZE_MB} MB"

# =============================================================
# PASO 2 - Escaneo antivirus
# =============================================================

EXT=$(get_extension "$FILENAME")

SCAN_CLEAN=0
SCAN_INFECTED=0
SCAN_SKIPPED_VIDEO=0
CLEAN_FILE=""

if [ "$SCAN" == "yes" ]; then
    if extension_in_list "$EXT" "$VIDEO_EXTENSIONS"; then
        log "Antivirus: omitiendo archivo de video ($FILENAME)"
        SCAN_SKIPPED_VIDEO=1
        CLEAN_FILE="$FILEPATH"
    else
        log "Antivirus: escaneando $FILENAME"
        SCAN_RESULT=$($CURL -s -X POST "$CLAMAV_URL" -F "FILES=@\"${FILEPATH}\"")
        log "ClamAV respuesta: $SCAN_RESULT"

        IS_INFECTED=$($JQ -r '.data.result[0].is_infected' <<< "$SCAN_RESULT")

        if [ "$IS_INFECTED" = "true" ]; then
            VIRUSES=$($JQ -r '.data.result[0].viruses | join(", ")' <<< "$SCAN_RESULT")
            log "INFECTADO: $FILENAME - $VIRUSES"
            rm -f "$FILEPATH"
            log "Archivo eliminado: $FILEPATH"
            SCAN_INFECTED=1
        else
            log "Limpio: $FILENAME"
            SCAN_CLEAN=1
            CLEAN_FILE="$FILEPATH"
        fi
    fi
else    
    CLEAN_FILE="$FILEPATH"
fi

# Notificación Gotify - resultado escaneo
if [ $SCAN_SKIPPED_VIDEO -eq 1 ]; then
    AV_MSG="🎬 Video omitido del escaneo: $FILENAME"
    AV_PRIORITY=3
elif [ $SCAN_INFECTED -eq 1 ]; then
    AV_MSG="🦠 INFECTADO y eliminado: $FILENAME"$'\n'"Virus: $VIRUSES"
    AV_PRIORITY=10
else
    AV_MSG="✅ Limpio: $FILENAME"
    AV_PRIORITY=3
fi

gotify_notify "Antivirus - $CATEGORY" "$AV_MSG" "$AV_PRIORITY"
log "Notificación antivirus enviada"

# Si fue eliminado por virus, no continuar
if [ $SCAN_INFECTED -eq 1 ]; then
    log "Archivo infectado eliminado. Finalizando."
    exit 0
fi

# =============================================================
# PASO 3 - Transferencia según categoría
# =============================================================

transfer_file() {
    local filepath="$1"
    local destination="$2"
    local subfolder="$3"

    if [ "$TRANSFER" == "yes" ]; then
    
        log "Transferring $filepath → $destination ${subfolder:+(subfolder: $subfolder)}"

        if [ -n "$subfolder" ]; then
            $CURL -s -X POST "$TRANSFERR_URL" \
                -F "file=@\"${filepath}\"" \
                -F "destination=${destination}" \
                -F "subfolder=${subfolder}" >> "$LOG_FILE" 2>&1
        else
            $CURL -s -X POST "$TRANSFERR_URL" \
                -F "file=@\"${filepath}\"" \
                -F "destination=${destination}" >> "$LOG_FILE" 2>&1
        fi
    fi    
}

case "$CATEGORY" in
    Libros)
        transfer_file "$CLEAN_FILE" "calibre"
        transfer_file "$CLEAN_FILE" "booklore"
        ;;
    Historietas)
        transfer_file "$CLEAN_FILE" "comics"
        ;;
    Música)
        transfer_file "$CLEAN_FILE" "slskd"
        ;;
    amule-radarr|amule-sonarr|otros|*)
        log "Categoría '$CATEGORY': no se transfieren archivos"
        ;;
esac

# =============================================================
# PASO 4 - Butler-API: generación de fichas
# =============================================================

call_butler() {
    local fname="$1"
    
    if [ "$CARDS" == "yes" ]; then
        log "Butler-API: procesando $fname"
        BUTLER_RESULT=$($CURL -s -X POST "$BUTLER_URL" \
            -F "filename=${fname}")
        log "Butler respuesta: $BUTLER_RESULT"
    fi    
}

if [ -z "$CLEAN_FILE" ]; then
    log "Butler: no hay archivo limpio disponible, omitiendo"
else
    CLEAN_FILENAME=$(basename "$CLEAN_FILE")
    case "$CATEGORY" in
        amule-radarr)
            if extension_in_list "$EXT" "$VIDEO_EXTENSIONS"; then
                call_butler "$CLEAN_FILENAME"
            else
                log "Butler: archivo de radarr sin extensión de video, omitido"
            fi
            ;;
        amule-sonarr)
            if extension_in_list "$EXT" "$VIDEO_EXTENSIONS"; then
                call_butler "$CLEAN_FILENAME"
            else
                log "Butler: archivo de sonarr sin extensión de video, omitido"
            fi
            ;;
        Libros)
            if extension_in_list "$EXT" "$BOOK_EXTENSIONS"; then
                call_butler "$CLEAN_FILENAME"
            else
                log "Butler: extensión no relevante para Libros, omitido"
            fi
            ;;
        Historietas)
            if extension_in_list "$EXT" "$COMIC_EXTENSIONS"; then
                call_butler "$CLEAN_FILENAME"
            else
                log "Butler: extensión no relevante para Historietas, omitido"
            fi
            ;;
        Música)
            if extension_in_list "$EXT" "$MUSIC_EXTENSIONS"; then
                call_butler "$CLEAN_FILENAME"
            else
                log "Butler: extensión no relevante para Música, omitido"
            fi
            ;;
        *)
            log "Butler: categoría '$CATEGORY' no genera fichas"
            ;;
    esac
fi

if [ "$SUBTITLES" == "yes" ]; then
    if [ "$CATEGORY" == "amule-sonarr" ] ||  [ "$CATEGORY" == "amule-radarr" ]; then
        $BASEDIR/subs.sh "$FILEPATH" "$CATEGORY"
    fi    
fi

log "Script finalizado para: $FILENAME"
log "============================================================"

exit 0
