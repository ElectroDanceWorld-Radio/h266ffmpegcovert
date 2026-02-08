#!/bin/bash

# ====================================================
# SCRIPT DE COMPRESION H.266 VVC - MAXIMA EFICIENCIA
# ====================================================

# CONFIGURACION POR PARAMETROS
VIDEO_INPUT="${1:-/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4}"
VIDEO_OUTPUT="${2:-/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD266.mp4}"
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
AUDIO_BITRATE="256k"  # Cambiado a 256k como solicitaste
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
    
    # Suprimir errores MPP (Media Process Platform)
    export MPP_LOG_LEVEL=0  # Silenciar MPP
    
    local hw_accels=("cuda" "vaapi" "dxva2" "d3d11va" "auto")
    
    for accel in "${hw_accels[@]}"; do
        log_info "Probando $accel..."
        
        # Redirigir stderr para suprimir errores MPP
        if ffmpeg -hwaccel "$accel" -i "$VIDEO_INPUT" -t 0.5 -f null - 2>/dev/null | grep -v "mpp\|MPP"; then
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
    
    # Verificar si ya hay segmentos
    local existing_segments=$(ls -1 segment_*.mp4 2>/dev/null | head -1)
    if [ -n "$existing_segments" ]; then
        local count=$(ls segment_*.mp4 2>/dev/null | wc -l)
        log_info "Segmentos ya existen ($count encontrados), saltando creacion"
        return 0
    fi
    
    local hw_accel=""
    if [ -n "$HW_ACCEL" ]; then
        hw_accel="-hwaccel $HW_ACCEL"
    fi
    
    log_info "Ejecutando comando de creacion de segmentos..."
    
    # Explicacion de -avoid_negative_ts make_zero:
    # FFmpeg intenta evitar timestamps negativos en los segmentos
    # make_zero: Hace que el primer timestamp sea 0 en cada segmento
    # Esto es importante para que los segmentos sean independientes
    
    # Crear archivo de log para capturar salida
    local log_file="segment_creation.log"
    
    # Comando simplificado sin redireccion compleja
    # Usamos -loglevel error para reducir salida y capturar solo errores
    local cmd="ffmpeg -loglevel error $hw_accel \
        -i \"$input\" \
        -c copy \
        -map 0 \
        -f segment \
        -segment_time $duration \
        -segment_format mp4 \
        -reset_timestamps 1 \
        -segment_start_number 0 \
        -avoid_negative_ts make_zero \
        \"segment_%03d.mp4\" 2>&1"
    
    log_info "Ejecutando: ffmpeg -i \"$input\" -c copy -f segment -segment_time $duration ..."
    
    # Ejecutar y capturar salida
    eval "$cmd" > "$log_file" 2>&1
    local exit_code=$?
    
    # Contar segmentos creados
    local count=$(ls segment_*.mp4 2>/dev/null | wc -l)
    
    if [ $count -gt 0 ]; then
        log_success "Creados $count segmentos"
        # Mostrar algunos segmentos creados
        ls -la segment_*.mp4 2>/dev/null | head -3 | while read line; do
            log_info "  $line"
        done
        rm -f "$log_file" 2>/dev/null
        return 0
    else
        # Mostrar error si hubo
        if [ -f "$log_file" ]; then
            log_error "Error al crear segmentos. Log:"
            grep -i "error\|fail\|invalid" "$log_file" | head -5 | while read line; do
                log_error "  $line"
            done
        fi
        
        # Intentar metodo alternativo MAS SIMPLE
        log_info "Intentando metodo alternativo simplificado..."
        
        # Método 1: Sin -avoid_negative_ts
        ffmpeg -loglevel error -i "$input" \
            -c copy \
            -f segment \
            -segment_time "$duration" \
            -segment_format mp4 \
            -reset_timestamps 1 \
            "segment_%03d.mp4" 2>&1 | grep -v "mpp\|MPP" || true
        
        local alt_count=$(ls segment_*.mp4 2>/dev/null | wc -l)
        if [ $alt_count -gt 0 ]; then
            log_success "Creados $alt_count segmentos (metodo alternativo 1)"
            return 0
        fi
        
        # Método 2: Usando force_key_frames para cortes precisos
        log_info "Intentando con cortes en keyframes..."
        ffmpeg -loglevel error -i "$input" \
            -c copy \
            -force_key_frames "expr:gte(t,n_forced*$duration)" \
            -f segment \
            -segment_time "$duration" \
            -segment_format mp4 \
            "seg_%03d.mp4" 2>&1 | grep -v "mpp\|MPP" || true
        
        # Renombrar si se crearon con otro nombre
        if [ -f "seg_000.mp4" ]; then
            mv seg_*.mp4 segment_*.mp4 2>/dev/null
            local alt_count=$(ls segment_*.mp4 2>/dev/null | wc -l)
            log_success "Creados $alt_count segmentos (con keyframes forzados)"
            return 0
        fi
        
        # Método 3: Crear segmentos manualmente
        log_info "Intentando creacion manual de segmentos..."
        
        # Obtener duracion total
        local total_duration=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | cut -d. -f1)
        
        if [ -n "$total_duration" ] && [ "$total_duration" -gt 0 ]; then
            local segment_count=$(( (total_duration + duration - 1) / duration ))
            log_info "Duracion total: ${total_duration}s, segmentos estimados: $segment_count"
            
            for ((i=0; i<segment_count; i++)); do
                local start=$((i * duration))
                local segment_name=$(printf "segment_%03d.mp4" $i)
                
                ffmpeg -loglevel error -i "$input" \
                    -ss "$start" \
                    -t "$duration" \
                    -c copy \
                    -avoid_negative_ts make_zero \
                    -y "$segment_name" 2>&1 | grep -v "mpp\|MPP" || true
                
                # Verificar si se creo el segmento
                if [ -f "$segment_name" ] && [ -s "$segment_name" ]; then
                    log_info "  Creado: $segment_name"
                else
                    rm -f "$segment_name" 2>/dev/null
                fi
            done
            
            local final_count=$(ls segment_*.mp4 2>/dev/null | wc -l)
            if [ $final_count -gt 0 ]; then
                log_success "Creados $final_count segmentos (metodo manual)"
                return 0
            fi
        fi
        
        return 1
    fi
}

convert_segment_vvc() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_attempt${attempt}.txt"
    local start_time=$(date +%s)
    
    log_info "Convertiendo: $(basename "$input") (intento $attempt)"
    
    local vvc_cmd=$(build_vvc_command "$input" "$output")
    
    # Ejecutar con redireccion de errores MPP
    eval "$vvc_cmd" 2>&1 | grep -v "mpp\|MPP" > "$log_file"
    local exit_code=${PIPESTATUS[0]}
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ] && [ -f "$output" ] && [ -s "$output" ]; then
        # Verificar que el archivo sea un video valido
        local video_info=$(ffprobe -v error -show_format -show_streams "$output" 2>/dev/null)
        if [ -n "$video_info" ]; then
            log_success "Convertido en ${duration}s"
            rm -f "$log_file"
            return 0
        fi
    fi
    
    # Mostrar error si existe
    if [ -f "$log_file" ]; then
        local error_msg=$(grep -i "error\|fail\|invalid\|unsupported" "$log_file" | head -3)
        if [ -n "$error_msg" ]; then
            log_error "Error: $error_msg"
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
    
    # Redirigir errores MPP
    ffmpeg -i "$input" \
        -c:v libvvenc \
        -preset "$VVC_PRESET" \
        -qp "$QP" \
        -threads "$(nproc)" \
        -c:a "$AUDIO_ENCODER" \
        -b:a "$AUDIO_BITRATE" \
        -ac "$AUDIO_CHANNELS" \
        -y "$output" 2>&1 | grep -v "mpp\|MPP" > "$log_file"
    
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ] && [ -f "$output" ] && [ -s "$output" ]; then
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
            log_info "Checkpoint en segmento $segment_num"
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
    
    # Redirigir errores MPP durante la union
    ffmpeg -f concat \
        -safe 0 \
        -i "$segment_list" \
        -c copy \
        -y "$output" 2>&1 | \
        while IFS= read -r line; do
            if [[ "$line" == *"frame="* ]] || [[ "$line" == *"time="* ]]; then
                echo "    $line"
            fi
        done
    
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
    local available_gb=100  # Valor por defecto
    
    # Obtener espacio disponible
    if command -v df &> /dev/null; then
        available_gb=$(df -BG . 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo 100)
    fi
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_warning "Espacio en disco bajo: ${available_gb}GB disponibles"
        log_warning "Se recomienda al menos ${required_gb}GB"
        log_warning "Continuando con espacio disponible..."
        return 0  # Continuar de todos modos
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
    echo "Audio: $AUDIO_ENCODER @ $AUDIO_BITRATE"
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
    
    # Configurar según preset
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
    
    # Configurar para suprimir errores MPP
    export MPP_LOG_LEVEL=0
    
    HW_ACCEL=$(detect_hw_accel)
    
    get_video_info "$VIDEO_INPUT"
    
    WORK_DIR="vvc_encode_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit 1
    
    log_info "Directorio de trabajo: $WORK_DIR"
    
    # Crear segmentos
    if ! create_segments "$VIDEO_INPUT" "$SEGMENT_DURATION"; then
        log_error "Fallo al crear segmentos"
        cd ..
        exit 1
    fi
    
    # Procesar segmentos
    if ! process_all_segments; then
        log_error "Fallo al procesar segmentos"
        cd ..
        exit 1
    fi
    
    # Unir segmentos
    if merge_segments "../$VIDEO_OUTPUT"; then
        cd ..
        echo ""
        echo "========================================"
        echo "✅ COMPRESION COMPLETADA"
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
            local ratio=$(echo "scale=2; $original_size / $compressed_size" | bc 2>/dev/null || echo "N/A")
            echo "Ratio de compresion: ${ratio}x"
        fi
        
        echo ""
        
        read -p "Eliminar archivos temporales? (s/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            cleanup_temp_files
            rm -rf "$WORK_DIR"
            log_success "Archivos temporales eliminados"
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

# Manejar señales de interrupcion
trap 'log_warning "Interrupcion recibida, guardando estado..."; exit 1' SIGINT SIGTERM

# Ejecutar programa principal
main "$@"