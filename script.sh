#!/bin/bash

# ====================================================
# SCRIPT DE CONVERSIÓN H.266 - VERSIÓN CORREGIDA
# ====================================================

# CONFIGURACIÓN PRINCIPAL
VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 h266_AutoRetry.mp4"

# TU CONFIGURACIÓN ACTUAL
DURACION_SEGMENTO=30  # 30 segundos
MAX_REINTENTOS=1
TIMEOUT_POR_SEGMENTO=$((2 * 60 * 60))  # 2 horas = 7200 segundos

# CONFIGURACIÓN DE CODIFICACIÓN
ENCODER_VVC="libvvenc"
PRESET_VVC="slower"           # Como lo configuraste
BITRATE_VIDEO="16M"
ENCODER_AUDIO="libopus"
BITRATE_AUDIO="256k"

# CONFIGURACIÓN HWACCEL
HWACCEL_PREFERENCE=("cuda" "vaapi" "qsv" "vdpau" "")
MAX_SEGMENTOS_PARALELOS=4
THREADS_POR_SEGMENTO=4

# COLORES
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# FUNCIONES BÁSICAS CORREGIDAS
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# FUNCIÓN: Verificar archivo
verificar_archivo() {
    if [ ! -f "$1" ]; then
        log_error "Archivo no encontrado: $1"
        return 1
    fi
    return 0
}

# FUNCIÓN: Formatear tiempo
formatear_tiempo() {
    local segundos=$1
    local horas=$((segundos / 3600))
    local minutos=$(((segundos % 3600) / 60))
    local segs=$((segundos % 60))
    printf "%02d:%02d:%02d" $horas $minutos $segs
}

# DETECTAR HWACCEL SIMPLIFICADO
detectar_hwaccel() {
    log_info "Detectando aceleración por hardware..."
    
    for metodo in "${HWACCEL_PREFERENCE[@]}"; do
        if [ -n "$metodo" ]; then
            if ffmpeg -hwaccel "$metodo" -i "$VIDEO_ORIGINAL" -t 1 -f null - 2>/dev/null; then
                log_success "Usando: $metodo"
                echo "$metodo"
                return 0
            fi
        else
            log_info "Usando software"
            echo ""
            return 0
        fi
    done
}

# FUNCIÓN PRINCIPAL CORREGIDA
procesar_segmento() {
    local entrada="$1"
    local salida="$2"
    local hwaccel="$3"
    
    local nombre_base=$(basename "$entrada" .mp4)
    
    # CORRECCIÓN: Escapar paréntesis en el mensaje
    log_info "Iniciado $nombre_base (PID: $$)"
    
    # Comando básico
    local cmd="ffmpeg"
    [ -n "$hwaccel" ] && cmd="$cmd -hwaccel $hwaccel"
    
    cmd="$cmd -i \"$entrada\""
    cmd="$cmd -c:v $ENCODER_VVC"
    cmd="$cmd -preset $PRESET_VVC"
    cmd="$cmd -b:v $BITRATE_VIDEO"
    cmd="$cmd -c:a $ENCODER_AUDIO"
    cmd="$cmd -b:a $BITRATE_AUDIO"
    cmd="$cmd -threads $THREADS_POR_SEGMENTO"
    cmd="$cmd -y"
    cmd="$cmd \"$salida\""
    
    # Ejecutar con timeout
    timeout $TIMEOUT_POR_SEGMENTO bash -c "$cmd"
    
    if [ $? -eq 0 ] && [ -f "$salida" ]; then
        log_success "Completado: $nombre_base"
        return 0
    else
        log_error "Falló: $nombre_base"
        return 1
    fi
}

# PROGRAMA PRINCIPAL
clear
echo "========================================"
echo "CONVERSIÓN H.266 CON TU CONFIGURACIÓN"
echo "========================================"
echo "Segmentos: $DURACION_SEGMENTO segundos"
echo "Timeout: $(formatear_tiempo $TIMEOUT_POR_SEGMENTO)"
echo "Preset: $PRESET_VVC"
echo "========================================"

# Verificar archivo
if ! verificar_archivo "$VIDEO_ORIGINAL"; then
    exit 1
fi

# Detectar HWACCEL
HWACCEL_METHOD=$(detectar_hwaccel)

# Calcular información
duracion=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_ORIGINAL" 2>/dev/null)
duracion_int=${duracion%.*}
segmentos_estimados=$(( (duracion_int + DURACION_SEGMENTO - 1) / DURACION_SEGMENTO ))

echo "Duración video: $(formatear_tiempo $duracion_int)"
echo "Segmentos estimados: $segmentos_estimados"

# ADVERTENCIA por segmentos de 30s
if [ "$DURACION_SEGMENTO" -eq 30 ]; then
    echo ""
    echo "⚠️  ADVERTENCIA: Segmentos de 30 segundos"
    echo "Con 2 horas por segmento y preset 'slower':"
    echo "Tiempo estimado: $(formatear_tiempo $((segmentos_estimados * TIMEOUT_POR_SEGMENTO / MAX_SEGMENTOS_PARALELOS)))"
    echo ""
    read -p "¿Continuar? (s/n): " respuesta
    [ "$respuesta" != "s" ] && exit 0
fi

# Crear segmentos si no existen
if [ ! -f "parte_001.mp4" ]; then
    log_info "Creando segmentos..."
    cmd="ffmpeg"
    [ -n "$HWACCEL_METHOD" ] && cmd="$cmd -hwaccel $HWACCEL_METHOD"
    cmd="$cmd -i \"$VIDEO_ORIGINAL\" -c copy -segment_time $DURACION_SEGMENTO -f segment -reset_timestamps 1 \"parte_%03d.mp4\""
    eval "$cmd"
fi

# Procesar segmentos
log_info "Iniciando conversión..."
contador=0
exitosos=0
fallidos=0

for segmento in parte_*.mp4; do
    [ ! -f "$segmento" ] && continue
    
    contador=$((contador + 1))
    nombre_base=$(basename "$segmento" .mp4)
    salida="${nombre_base}_vvc.mp4"
    
    echo -ne "\rProcesando: $contador/$segmentos_estimados "
    
    if [ -f "$salida" ]; then
        log_info "Saltando: $nombre_base (ya existe)"
        exitosos=$((exitosos + 1))
        continue
    fi
    
    if procesar_segmento "$segmento" "$salida" "$HWACCEL_METHOD"; then
        exitosos=$((exitosos + 1))
    else
        fallidos=$((fallidos + 1))
    fi
done

echo ""
echo "========================================"
echo "RESULTADO:"
echo "  Exitosa: $exitosos"
echo "  Fallidas: $fallidos"
echo "========================================"

# Unir si hay resultados
if [ $exitosos -gt 0 ]; then
    log_info "Uniendo segmentos..."
    ls -1v *_vvc.mp4 2>/dev/null | while read file; do
        echo "file '$file'"
    done > lista.txt
    
    ffmpeg -f concat -safe 0 -i lista.txt -c copy "$SALIDA_FINAL" 2>/dev/null
    
    if [ -f "$SALIDA_FINAL" ]; then
        log_success "Video final creado: $SALIDA_FINAL"
        # Limpiar
        rm -f parte_*.mp4 *_vvc.mp4 lista.txt 2>/dev/null
    else
        log_error "Error al unir segmentos"
    fi
fi

log_info "Proceso completado"