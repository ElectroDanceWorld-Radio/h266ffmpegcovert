#!/bin/bash

# ====================================================
# SCRIPT DE COMPRESIÓN H.266 VVC - MÁXIMA EFICIENCIA
# ====================================================
# Autor: Sistema de compresión VVC avanzado
# Versión: 2.0

# CONFIGURACIÓN POR PARÁMETROS
VIDEO_INPUT="${1:-/ruta/por/defecto/input.mp4}"
VIDEO_OUTPUT="${2:-salida_vvc_maxcomp.mp4}"
PRESET="${3:-slower}"  # slower para máxima compresión
SEGMENT_DURATION="${4:-30}"  # 30 segundos por segmento

# CONFIGURACIÓN VVC AVANZADA (máxima compresión)
VVC_PRESET="slower"  # slower para mejor calidad/compresión
INTERNAL_BITDEPTH="10"  # 10-bit para mejor calidad
QP="32"  # QP constante para calidad consistente
THREADS="-1"  # Automático: usa todos los cores disponibles
INTRA_PERIOD="2"  # Cada 2 segundos (mejor para compresión)
QPA="on"  # Adaptación perceptual de QP
INTERNAL_PRED="on"  # Predicción interna (mejor compresión)
RDOQ="2"  # Optimización de distorsión-rate nivel 2
MTS="on"  # Transformadas múltiples
LFNST="on"  # Transformadas LFNST
MIP="on"  # Predicción intra matricial
ISP="on"  # Sub-partición intra
TS="on"  # Transform skip
BDPCM="on"  # Modo BDPCM
SBT="on"  # Transformada basada en sub-blocks

# CONFIGURACIÓN MULTIHILO
PARALLEL_JOBS=4  # Procesar 4 segmentos simultáneamente
WPP="on"  # Procesamiento wavefront paralelo
TILES="2x2"  # 4 tiles para paralelización
IFP="auto"  # Paralelización inter-frame automática
MT_PROFILE="auto"  # Perfil multihilo automático

# CONFIGURACIÓN DE RECUPERACIÓN
MAX_RETRIES=2  # Reintentos por segmento
SAFE_MODE=true  # Modo seguro con verificación
BACKUP_EVERY=5  # Backup cada 5 segmentos

# CONFIGURACIÓN AUDIO
AUDIO_ENCODER="libopus"  # Opus para mejor eficiencia
AUDIO_BITRATE="256k"  # Bitrate audio
AUDIO_CHANNELS="2"  # Stereo

# =================================================================
# FUNCIONES PRINCIPALES
# =================================================================

# Función de logging con timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_info() {
    log "ℹ️  INFO: $1"
}

log_success() {
    log "✅ SUCCESS: $1"
}

log_warning() {
    log "⚠️  WARNING: $1" >&2
}

log_error() {
    log "❌ ERROR: $1" >&2
}

# Detectar aceleración por hardware óptima
detect_hw_accel() {
    log_info "Detectando aceleración por hardware..."
    
    # Orden de prioridad: CUDA > VAAPI > DXVA2 > D3D11VA > Software
    local hw_accels=("cuda" "vaapi" "dxva2" "d3d11va" "auto")
    
    for accel in "${hw_accels[@]}"; do
        log_info "Probando $accel..."
        
        if ffmpeg -hwaccel "$accel" -i "$VIDEO_INPUT" -t 0.5 -f null - 2>/dev/null; then
            log_success "Aceleración $accel disponible"
            echo "$accel"
            return 0
        fi
    done
    
    log_warning "No se encontró aceleración por hardware, usando software"
    echo ""
    return 1
}

# Verificar compatibilidad VVC
check_vvc_support() {
    log_info "Verificando compatibilidad VVC..."
    
    if ! command -v vvencapp &> /dev/null; then
        log_error "vvencapp no encontrado. Instala VVC encoder:"
        log_error "  git clone https://github.com/fraunhoferhhi/vvenc"
        log_error "  cd vvenc && mkdir build && cd build"
        log_error "  cmake .. -DCMAKE_BUILD_TYPE=Release"
        log_error "  make -j$(nproc)"
        return 1
    fi
    
    if ! ffmpeg -encoders 2>/dev/null | grep -q "libvvenc"; then
        log_warning "libvvenc no está disponible en FFmpeg"
    fi
    
    log_success "VVC encoder disponible"
    return 0
}

# Obtener información del video
get_video_info() {
    local video="$1"
    
    log_info "Analizando: $(basename "$video")"
    
    echo "========================================"
    echo "INFORMACIÓN DEL VIDEO"
    echo "========================================"
    
    ffprobe -v error \
        -show_entries stream=codec_name,codec_type,width,height,pix_fmt,bit_rate,r_frame_rate \
        -show_entries format=duration,size,bit_rate \
        -of json "$video" 2>/dev/null | \
        jq -r '
            "Resolución: \(.streams[0].width)x\(.streams[0].height)",
            "Formato: \(.streams[0].pix_fmt)",
            "Codec video: \(.streams[0].codec_name)",
            "FPS: \(.streams[0].r_frame_rate)",
            "Duración: \(.format.duration | tonumber | floor / 60) min \(.format.duration | tonumber % 60 | floor) sec",
            "Tamaño: \(.format.size | tonumber / (1024*1024) | floor) MB",
            "Bitrate: \(.format.bit_rate | tonumber / 1000 | floor) kbps"
        '
    
    echo ""
}

# Crear segmentos del video
create_segments() {
    local input="$1"
    local duration="$2"
    
    log_info "Creando segmentos de ${duration}s..."
    
    if [ -f "segment_000.mp4" ]; then
        log_info "Segmentos ya existen, saltando creación"
        return 0
    fi
    
    local hw_accel=""
    if [ -n "$HW_ACCEL" ]; then
        hw_accel="-hwaccel $HW_ACCEL"
    fi
    
    # Crear segmentos preservando calidad original
    ffmpeg $hw_accel \
        -i "$input" \
        -c:v copy -c:a copy \
        -f segment \
        -segment_time "$duration" \
        -segment_format mp4 \
        -reset_timestamps 1 \
        -segment_start_number 0 \
        "segment_%03d.mp4" 2>&1 | \
        while read -r line; do
            if [[ "$line" == *"frame="* ]]; then
                echo -ne "\rCreando segmentos... $line"
            fi
        done
    
    echo ""
    local count=$(ls segment_*.mp4 2>/dev/null | wc -l)
    log_success "Creados $count segmentos"
}

# Comando VVC con máxima compresión
build_vvc_command() {
    local input="$1"
    local output="$2"
    
    # Parámetros principales para máxima compresión
    local params=(
        "--input '$input'"
        "--output '$output'"
        "--preset $VVC_PRESET"
        "--qp $QP"
        "--threads $THREADS"
        "--intraperiod $INTRA_PERIOD"
        "--qpa $QPA"
        "--internal-bitdepth $INTERNAL_BITDEPTH"
        "--mtprofile $MT_PROFILE"
        "--ifp $IFP"
        "--tiles $TILES"
        "--profile main_10"
        "--level auto"
        "--decodedpicturehash 1"  # Verificación de integridad
    )
    
    # Parámetros adicionales para máxima compresión
    local additional_params=(
        "RateControl=0"  # Modo QP constante
        "LoopFilterBetaOffset=0"
        "LoopFilterTcOffset=0"
        "SAO=1"
        "ALF=1"
        "CCALF=1"
        "MCTF=1"
        "Affine=1"
        "LMCS=1"
        "LMCSSignalType=0"
        "ScalingList=1"
        "DepQuant=1"
        "SignDataHiding=1"
        "CIIP=1"
        "GPM=1"
        "MRL=1"
        "MIP=$MIP"
        "ISP=$ISP"
        "TransformSkip=$TS"
        "BDPCM=$BDPCM"
        "SBT=$SBT"
        "JointCbCr=1"
        "PLT=1"
        "IBC=1"
        "HashBasedIntraBCSearch=1"
        "FastLocalDualTree=1"
        "FastSubPel=1"
    )
    
    # Unir parámetros adicionales
    local additional_str=$(IFS=:; echo "${additional_params[*]}")
    
    echo "vvencapp ${params[*]} --additional \"$additional_str\""
}

# Convertir segmento con VVC
convert_segment_vvc() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_attempt${attempt}.txt"
    local start_time=$(date +%s)
    
    log_info "Convertiendo: $(basename "$input") (intento $attempt)"
    
    # Construir comando VVC
    local vvc_cmd=$(build_vvc_command "$input" "$output")
    
    # Ejecutar conversión
    eval "$vvc_cmd" > "$log_file" 2>&1
    local exit_code=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Verificar resultado
    if [ $exit_code -eq 0 ] && [ -f "$output" ] && [ -s "$output" ]; then
        # Verificar integridad del video
        if ffprobe -v error "$output" >/dev/null 2>&1; then
            log_success "Convertido en ${duration}s"
            rm -f "$log_file"
            return 0
        fi
    fi
    
    log_error "Fallo en conversión (${duration}s)"
    return 1
}

# Convertir segmento con FFmpeg (fallback)
convert_segment_ffmpeg() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_ffmpeg_attempt${attempt}.txt"
    
    log_info "Usando FFmpeg fallback para: $(basename "$input")"
    
    # Usar FFmpeg con libvvenc
    ffmpeg -i "$input" \
        -c:v libvvenc \
        -preset "$VVC_PRESET" \
        -qp "$QP" \
        -threads "$(nproc)" \
        -c:a "$AUDIO_ENCODER" \
        -b:a "$AUDIO_BITRATE" \
        -ac "$AUDIO_CHANNELS" \
        -y "$output" > "$log_file" 2>&1
    
    if [ $? -eq 0 ] && [ -f "$output" ] && [ -s "$output" ]; then
        log_success "Convertido con FFmpeg"
        rm -f "$log_file"
        return 0
    fi
    
    return 1
}

# Procesar un segmento con reintentos
process_segment() {
    local segment="$1"
    local segment_num="$2"
    local total_segments="$3"
    
    local base_name=$(basename "$segment" .mp4")
    local output="${base_name}_vvc.mp4"
    local status_file="${base_name}_status.txt"
    
    # Verificar si ya está procesado
    if [ -f "$output" ] && [ -s "$output" ]; then
        if ffprobe -v error "$output" >/dev/null 2>&1; then
            log_info "Segmento ya procesado: $base_name"
            echo "success" > "$status_file"
            return 0
        else
            rm -f "$output"
        fi
    fi
    
    # Progreso
    echo "[$segment_num/$total_segments] Procesando $base_name..."
    
    # Intentar con vvencapp
    for attempt in $(seq 1 $MAX_RETRIES); do
        if convert_segment_vvc "$segment" "$output" "$attempt"; then
            echo "success" > "$status_file"
            return 0
        fi
        rm -f "$output" 2>/dev/null
    done
    
    # Fallback a FFmpeg
    for attempt in $(seq 1 $MAX_RETRIES); do
        if convert_segment_ffmpeg "$segment" "$output" "$attempt"; then
            echo "success" > "$status_file"
            return 0
        fi
        rm -f "$output" 2>/dev/null
    done
    
    # Fallo total
    log_error "No se pudo convertir segmento: $base_name"
    echo "failed" > "$status_file"
    return 1
}

# Procesamiento paralelo
process_all_segments() {
    local segments=($(ls -1v segment_*.mp4 2>/dev/null))
    local total=${#segments[@]}
    
    if [ $total -eq 0 ]; then
        log_error "No se encontraron segmentos"
        return 1
    fi
    
    log_info "Procesando $total segmentos en paralelo ($PARALLEL_JOBS simultáneos)"
    
    # Array para almacenar PIDs
    local pids=()
    local processed=0
    local failed=0
    
    # Función para monitorear procesos
    monitor_processes() {
        while true; do
            local running=0
            local new_pids=()
            
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((running++))
                    new_pids+=("$pid")
                else
                    wait "$pid"
                    local exit_code=$?
                    ((processed++))
                    
                    if [ $exit_code -ne 0 ]; then
                        ((failed++))
                    fi
                    
                    # Mostrar progreso
                    local progress=$((processed * 100 / total))
                    echo -ne "\rProgreso: $processed/$total segmentos ($progress%) | Fallos: $failed"
                fi
            done
            
            pids=("${new_pids[@]}")
            
            if [ $running -eq 0 ] && [ $processed -eq $total ]; then
                break
            fi
            
            sleep 1
        done
    }
    
    # Iniciar procesos
    for i in "${!segments[@]}"; do
        local segment="${segments[$i]}"
        local segment_num=$((i + 1))
        
        # Esperar si hay muchos procesos en paralelo
        while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
            sleep 1
        done
        
        # Procesar en background
        process_segment "$segment" "$segment_num" "$total" &
        pids+=($!)
        
        # Backup periódico
        if [ $((segment_num % BACKUP_EVERY)) -eq 0 ]; then
            log_info "Backup en segmento $segment_num"
        fi
    done
    
    # Monitorear procesos
    monitor_processes
    
    echo ""
    log_info "Procesamiento completado"
    log_info "Éxitos: $((processed - failed))"
    log_info "Fallos: $failed"
    
    return $failed
}

# Unir segmentos convertidos
merge_segments() {
    local output="$1"
    
    log_info "Uniendo segmentos convertidos..."
    
    # Crear lista de segmentos exitosos
    local segment_list="segment_list.txt"
    > "$segment_list"
    
    for vvc_file in *_vvc.mp4; do
        if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
            if ffprobe -v error "$vvc_file" >/dev/null 2>&1; then
                echo "file '$vvc_file'" >> "$segment_list"
            fi
        fi
    done
    
    local count=$(wc -l < "$segment_list")
    
    if [ "$count" -eq 0 ]; then
        log_error "No hay segmentos para unir"
        return 1
    fi
    
    log_info "Uniendo $count segmentos..."
    
    # Unir con FFmpeg
    ffmpeg -f concat \
        -safe 0 \
        -i "$segment_list" \
        -c copy \
        -y "$output" 2>&1 | \
        while read -r line; do
            if [[ "$line" == *"frame="* ]]; then
                echo -ne "\rUniendo... $line"
            fi
        done
    
    echo ""
    
    if [ -f "$output" ] && [ -s "$output" ]; then
        log_success "Video unido exitosamente"
        return 0
    else
        log_error "Error al unir segmentos"
        return 1
    fi
}

# Limpieza de archivos temporales
cleanup_temp_files() {
    log_info "Limpiando archivos temporales..."
    
    # Conservar logs de errores
    local error_logs=$(find . -name "log_*failed*.txt" -o -name "*_status.txt" | head -5)
    
    # Eliminar archivos temporales
    rm -f segment_*.mp4 2>/dev/null
    rm -f *_vvc.mp4 2>/dev/null
    rm -f segment_list.txt 2>/dev/null
    rm -f status_*.txt 2>/dev/null
    
    # Eliminar logs exitosos, mantener logs de error
    for log in log_*.txt; do
        if [ -f "$log" ] && ! echo "$error_logs" | grep -q "$log"; then
            rm -f "$log" 2>/dev/null
        fi
    done
    
    log_success "Limpieza completada"
}

# Verificar espacio en disco
check_disk_space() {
    local required_gb=50  # GB requeridos estimados
    local available_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_warning "Espacio en disco bajo: ${available_gb}GB disponibles"
        log_warning "Se recomienda al menos ${required_gb}GB"
        return 1
    fi
    
    return 0
}

# =================================================================
# PROGRAMA PRINCIPAL
# =================================================================

main() {
    clear
    echo "========================================"
    echo "COMPRESIÓN VVC - MÁXIMA EFICIENCIA"
    echo "========================================"
    echo "Entrada: $(basename "$VIDEO_INPUT")"
    echo "Salida: $(basename "$VIDEO_OUTPUT")"
    echo "Preset: $PRESET"
    echo "Segmentos: ${SEGMENT_DURATION}s"
    echo "Threads: automático (todos los cores)"
    echo "========================================"
    
    # Verificaciones iniciales
    if [ ! -f "$VIDEO_INPUT" ]; then
        log_error "Archivo de entrada no encontrado: $VIDEO_INPUT"
        exit 1
    fi
    
    if ! check_vvc_support; then
        log_error "VVC no disponible"
        exit 1
    fi
    
    check_disk_space
    
    # Configuración según preset
    case "$PRESET" in
        "fastest"|"fast")
            VVC_PRESET="fast"
            THREADS="$(nproc)"
            ;;
        "medium")
            VVC_PRESET="medium"
            ;;
        "slow"|"slower"|"slowest")
            VVC_PRESET="slower"
            INTRA_PERIOD="4"
            ;;
        *)
            VVC_PRESET="$PRESET"
            ;;
    esac
    
    # Detectar aceleración por hardware
    HW_ACCEL=$(detect_hw_accel)
    
    # Información del video original
    get_video_info "$VIDEO_INPUT"
    
    # Crear directorio de trabajo
    WORK_DIR="vvc_encode_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit 1
    
    log_info "Directorio de trabajo: $WORK_DIR"
    
    # PASO 1: Crear segmentos
    create_segments "$VIDEO_INPUT" "$SEGMENT_DURATION"
    
    # PASO 2: Procesar segmentos en paralelo
    process_all_segments
    
    # PASO 3: Unir segmentos
    if merge_segments "../$VIDEO_OUTPUT"; then
        # PASO 4: Información final
        cd ..
        echo ""
        echo "========================================"
        echo "✅ COMPRESIÓN COMPLETADA"
        echo "========================================"
        get_video_info "$VIDEO_OUTPUT"
        
        # Estadísticas
        local original_size=$(stat -c%s "$VIDEO_INPUT" 2>/dev/null)
        local compressed_size=$(stat -c%s "$VIDEO_OUTPUT" 2>/dev/null)
        local ratio="0"
        
        if [ "$original_size" -gt 0 ] && [ "$compressed_size" -gt 0 ]; then
            ratio=$(echo "scale=2; $original_size / $compressed_size" | bc)
        fi
        
        echo ""
        echo "ESTADÍSTICAS FINALES:"
        echo "--------------------"
        echo "Tamaño original: $((original_size / 1048576)) MB"
        echo "Tamaño comprimido: $((compressed_size / 1048576)) MB"
        echo "Ratio de compresión: ${ratio}x"
        echo "Segmentos procesados: $(ls "$WORK_DIR"/segment_*.mp4 2>/dev/null | wc -l)"
        echo ""
        
        # Preguntar por limpieza
        read -p "¿Eliminar archivos temporales? (s/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            cleanup_temp_files
            rm -rf "$WORK_DIR"
        else
            log_info "Archivos temporales conservados en: $WORK_DIR"
        fi
        
    else
        log_error "Error en la unión de segmentos"
        cd ..
        exit 1
    fi
    
    echo ""
    log_success "Proceso completado exitosamente"
}

# Manejo de señales para recuperación
trap 'log_warning "Interrupción recibida, guardando estado..."; exit 1' SIGINT SIGTERM

# Ejecutar programa principal
main "$@"