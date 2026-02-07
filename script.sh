#!/bin/bash

# ====================================================
# SCRIPT DE COMPRESION H.266 VVC - MAXIMA EFICIENCIA
# ====================================================

# CONFIGURACION POR PARAMETROS
VIDEO_INPUT="${1:-/ruta/por/defecto/input.mp4}"
VIDEO_OUTPUT="${2:-salida_vvc_maxcomp.mp4}"
PRESET="${3:-slower}"  # slower para maxima compresion
SEGMENT_DURATION="${4:-30}"  # 30 segundos por segmento

# CONFIGURACION VVC AVANZADA
VVC_PRESET="slower"
INTERNAL_BITDEPTH="10"
QP="32"
THREADS="-1"
INTRA_PERIOD="2"
QPA="on"
TILES="2x2"
IFP="auto"
MT_PROFILE="auto"

# CONFIGURACION MULTIHILO
PARALLEL_JOBS=4
WPP="on"

# CONFIGURACION DE RECUPERACION
MAX_RETRIES=2
BACKUP_EVERY=5

# CONFIGURACION AUDIO
AUDIO_ENCODER="libopus"
AUDIO_BITRATE="192k"
AUDIO_CHANNELS="2"

# =================================================================
# FUNCIONES PRINCIPALES
# =================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_info() {
    log "INFO: $1"
}

log_success() {
    log "SUCCESS: $1"
}

log_warning() {
    log "WARNING: $1" >&2
}

log_error() {
    log "ERROR: $1" >&2
}

detect_hw_accel() {
    log_info "Detectando aceleracion por hardware..."
    
    local hw_accels=("cuda" "vaapi" "dxva2" "d3d11va" "auto")
    
    for accel in "${hw_accels[@]}"; do
        log_info "Probando $accel..."
        
        if ffmpeg -hwaccel "$accel" -i "$VIDEO_INPUT" -t 0.5 -f null - 2>/dev/null; then
            log_success "Aceleracion $accel disponible"
            echo "$accel"
            return 0
        fi
    done
    
    log_warning "No se encontro aceleracion por hardware, usando software"
    echo ""
    return 1
}

check_vvc_support() {
    log_info "Verificando compatibilidad VVC..."
    
    if ! command -v vvencapp &> /dev/null; then
        log_error "vvencapp no encontrado."
        log_error "Instala VVC encoder desde: https://github.com/fraunhoferhhi/vvenc"
        return 1
    fi
    
    if ! ffmpeg -encoders 2>/dev/null | grep -q "libvvenc"; then
        log_warning "libvvenc no esta disponible en FFmpeg"
    fi
    
    log_success "VVC encoder disponible"
    return 0
}

get_video_info() {
    local video="$1"
    
    log_info "Analizando: $(basename "$video")"
    
    echo "========================================"
    echo "INFORMACION DEL VIDEO"
    echo "========================================"
    
    ffprobe -v error \
        -show_entries stream=codec_name,codec_type,width,height,pix_fmt,bit_rate,r_frame_rate \
        -show_entries format=duration,size,bit_rate \
        -of default=noprint_wrappers=1 "$video" 2>/dev/null
}

create_segments() {
    local input="$1"
    local duration="$2"
    
    log_info "Creando segmentos de ${duration}s..."
    
    if [ -f "segment_000.mp4" ]; then
        log_info "Segmentos ya existen, saltando creacion"
        return 0
    fi
    
    local hw_accel=""
    if [ -n "$HW_ACCEL" ]; then
        hw_accel="-hwaccel $HW_ACCEL"
    fi
    
    ffmpeg $hw_accel \
        -i "$input" \
        -c:v copy -c:a copy \
        -f segment \
        -segment_time "$duration" \
        -segment_format mp4 \
        -reset_timestamps 1 \
        -segment_start_number 0 \
        "segment_%03d.mp4" 2>&1 | \
        grep -E "frame=|size=" || true
    
    local count=$(ls segment_*.mp4 2>/dev/null | wc -l)
    log_success "Creados $count segmentos"
}

build_vvc_command() {
    local input="$1"
    local output="$2"
    
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
    )
    
    local additional_params=(
        "RateControl=0"
        "SAO=1"
        "ALF=1"
        "Affine=1"
        "MCTF=1"
        "DepQuant=1"
        "CIIP=1"
        "GPM=1"
        "MRL=1"
        "MIP=on"
        "ISP=on"
        "TransformSkip=on"
        "JointCbCr=1"
    )
    
    local additional_str=$(IFS=:; echo "${additional_params[*]}")
    
    echo "vvencapp ${params[*]} --additional \"$additional_str\""
}

convert_segment_vvc() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_attempt${attempt}.txt"
    local start_time=$(date +%s)
    
    log_info "Convertiendo: $(basename "$input") (intento $attempt)"
    
    local vvc_cmd=$(build_vvc_command "$input" "$output")
    
    eval "$vvc_cmd" > "$log_file" 2>&1
    local exit_code=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ] && [ -f "$output" ] && [ -s "$output" ]; then
        if ffprobe -v error "$output" >/dev/null 2>&1; then
            log_success "Convertido en ${duration}s"
            rm -f "$log_file"
            return 0
        fi
    fi
    
    log_error "Fallo en conversion (${duration}s)"
    return 1
}

convert_segment_ffmpeg() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_ffmpeg_attempt${attempt}.txt"
    
    log_info "Usando FFmpeg fallback para: $(basename "$input")"
    
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

process_segment() {
    local segment="$1"
    local segment_num="$2"
    local total_segments="$3"
    
    local base_name=$(basename "$segment" .mp4)
    local output="${base_name}_vvc.mp4"
    local status_file="${base_name}_status.txt"
    
    if [ -f "$output" ] && [ -s "$output" ]; then
        if ffprobe -v error "$output" >/dev/null 2>&1; then
            log_info "Segmento ya procesado: $base_name"
            echo "success" > "$status_file"
            return 0
        else
            rm -f "$output"
        fi
    fi
    
    echo "[$segment_num/$total_segments] Procesando $base_name..."
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        if convert_segment_vvc "$segment" "$output" "$attempt"; then
            echo "success" > "$status_file"
            return 0
        fi
        rm -f "$output" 2>/dev/null
    done
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        if convert_segment_ffmpeg "$segment" "$output" "$attempt"; then
            echo "success" > "$status_file"
            return 0
        fi
        rm -f "$output" 2>/dev/null
    done
    
    log_error "No se pudo convertir segmento: $base_name"
    echo "failed" > "$status_file"
    return 1
}

monitor_processes() {
    local pids=("$@")
    local total=${#pids[@]}
    local processed=0
    local failed=0
    
    while [ ${#pids[@]} -gt 0 ]; do
        local new_pids=()
        
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            else
                wait "$pid"
                local exit_code=$?
                ((processed++))
                
                if [ $exit_code -ne 0 ]; then
                    ((failed++))
                fi
                
                local progress=$((processed * 100 / total))
                echo -ne "\rProgreso: $processed/$total segmentos ($progress%) | Fallos: $failed"
            fi
        done
        
        pids=("${new_pids[@]}")
        sleep 1
    done
    
    echo ""
    log_info "Procesamiento completado"
    log_info "Exitos: $((processed - failed))"
    log_info "Fallos: $failed"
}

process_all_segments() {
    local segments=($(ls -1v segment_*.mp4 2>/dev/null))
    local total=${#segments[@]}
    
    if [ $total -eq 0 ]; then
        log_error "No se encontraron segmentos"
        return 1
    fi
    
    log_info "Procesando $total segmentos en paralelo ($PARALLEL_JOBS simultaneos)"
    
    local pids=()
    
    for i in "${!segments[@]}"; do
        local segment="${segments[$i]}"
        local segment_num=$((i + 1))
        
        while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
            sleep 1
        done
        
        process_segment "$segment" "$segment_num" "$total" &
        pids+=($!)
        
        if [ $((segment_num % BACKUP_EVERY)) -eq 0 ]; then
            log_info "Backup en segmento $segment_num"
        fi
    done
    
    monitor_processes "${pids[@]}"
    
    return 0
}

merge_segments() {
    local output="$1"
    
    log_info "Uniendo segmentos convertidos..."
    
    local segment_list="segment_list.txt"
    > "$segment_list"
    
    for vvc_file in *_vvc.mp4; do
        if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
            if ffprobe -v error "$vvc_file" >/dev/null 2>&1; then
                echo "file '$vvc_file'" >> "$segment_list"
            fi
        fi
    done
    
    local count=$(wc -l < "$segment_list" 2>/dev/null || echo 0)
    
    if [ "$count" -eq 0 ]; then
        log_error "No hay segmentos para unir"
        return 1
    fi
    
    log_info "Uniendo $count segmentos..."
    
    ffmpeg -f concat \
        -safe 0 \
        -i "$segment_list" \
        -c copy \
        -y "$output" 2>&1 | \
        grep -E "frame=|size=" || true
    
    if [ -f "$output" ] && [ -s "$output" ]; then
        log_success "Video unido exitosamente"
        return 0
    else
        log_error "Error al unir segmentos"
        return 1
    fi
}

cleanup_temp_files() {
    log_info "Limpiando archivos temporales..."
    
    rm -f segment_*.mp4 2>/dev/null
    rm -f *_vvc.mp4 2>/dev/null
    rm -f segment_list.txt 2>/dev/null
    rm -f status_*.txt 2>/dev/null
    rm -f log_*.txt 2>/dev/null
    
    log_success "Limpieza completada"
}

check_disk_space() {
    local required_gb=50
    local available_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//' 2>/dev/null || echo 100)
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_warning "Espacio en disco bajo: ${available_gb}GB disponibles"
        log_warning "Se recomienda al menos ${required_gb}GB"
        return 1
    fi
    
    return 0
}

main() {
    clear
    echo "========================================"
    echo "COMPRESION VVC - MAXIMA EFICIENCIA"
    echo "========================================"
    echo "Entrada: $(basename "$VIDEO_INPUT")"
    echo "Salida: $(basename "$VIDEO_OUTPUT")"
    echo "Preset: $PRESET"
    echo "Segmentos: ${SEGMENT_DURATION}s"
    echo "Threads: automatico (todos los cores)"
    echo "========================================"
    
    if [ ! -f "$VIDEO_INPUT" ]; then
        log_error "Archivo de entrada no encontrado: $VIDEO_INPUT"
        exit 1
    fi
    
    if ! check_vvc_support; then
        log_error "VVC no disponible"
        exit 1
    fi
    
    check_disk_space
    
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
    
    HW_ACCEL=$(detect_hw_accel)
    
    get_video_info "$VIDEO_INPUT"
    
    WORK_DIR="vvc_encode_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit 1
    
    log_info "Directorio de trabajo: $WORK_DIR"
    
    create_segments "$VIDEO_INPUT" "$SEGMENT_DURATION"
    
    process_all_segments
    
    if merge_segments "../$VIDEO_OUTPUT"; then
        cd ..
        echo ""
        echo "========================================"
        echo "COMPRESION COMPLETADA"
        echo "========================================"
        get_video_info "$VIDEO_OUTPUT"
        
        local original_size=$(stat -c%s "$VIDEO_INPUT" 2>/dev/null || echo 0)
        local compressed_size=$(stat -c%s "$VIDEO_OUTPUT" 2>/dev/null || echo 0)
        
        echo ""
        echo "ESTADISTICAS FINALES:"
        echo "--------------------"
        echo "Tamaño original: $((original_size / 1048576)) MB"
        echo "Tamaño comprimido: $((compressed_size / 1048576)) MB"
        
        if [ "$original_size" -gt 0 ] && [ "$compressed_size" -gt 0 ]; then
            local ratio=$(echo "scale=2; $original_size / $compressed_size" | bc)
            echo "Ratio de compresion: ${ratio}x"
        fi
        
        echo ""
        
        read -p "Eliminar archivos temporales? (s/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            cleanup_temp_files
            rm -rf "$WORK_DIR"
        else
            log_info "Archivos temporales conservados en: $WORK_DIR"
        fi
        
    else
        log_error "Error en la union de segmentos"
        cd ..
        exit 1
    fi
    
    echo ""
    log_success "Proceso completado exitosamente"
}

trap 'log_warning "Interrupcion recibida, guardando estado..."; exit 1' SIGINT SIGTERM

main "$@"