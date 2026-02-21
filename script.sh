#!/bin/bash

# ====================================================
# SCRIPT DE COMPRESION H.266 VVC - MAXIMA EFICIENCIA
# ====================================================

##con picos de 41% sin hacer restauracion de conversion 

# CONFIGURACION POR PARAMETROS
VIDEO_INPUT="${1:-/home/carlos/Descargas/Conversion ffmpeg/okey vertical dj carlos.mp4}"
VIDEO_OUTPUT="${2:-/home/carlos/Descargas/Conversion ffmpeg/okey vertical dj carlos HD266.mp4}"
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
AUDIO_BITRATE="256k"
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
    
    # Lista de aceleradores a probar
    local hw_accels=("cuda" "vaapi" "dxva2" "d3d11va")
    
    # Primero probar sin aceleracion
    log_info "Probando sin aceleracion..."
    if timeout 5 ffmpeg -loglevel quiet -i "$VIDEO_INPUT" -t 1 -f null - 2>/dev/null; then
        log_success "Software funcionando"
        echo ""
        return 0
    fi
    
    # Probar cada acelerador
    for accel in "${hw_accels[@]}"; do
        log_info "Probando $accel..."
        if timeout 5 ffmpeg -hwaccel "$accel" -loglevel quiet -i "$VIDEO_INPUT" -t 1 -f null - 2>/dev/null; then
            log_success "Aceleracion $accel disponible"
            echo "$accel"
            return 0
        fi
    done
    
    log_warning "Usando software (fallback)"
    echo ""
    return 0
}

check_vvc_support() {
    log_info "Verificando compatibilidad VVC..."
    
    if ! command -v vvencapp &> /dev/null; then
        log_error "vvencapp no encontrado."
        log_error "Instala VVC encoder desde: https://github.com/fraunhoferhhi/vvenc"
        return 1
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

# Función para crear segmentos - CORREGIDA
create_segments() {
    local input="$1"
    local duration="$2"
    
    log_info "Creando segmentos de ${duration}s..."
    
    if ls segment_*.mp4 1> /dev/null 2>&1; then
        local count=$(ls segment_*.mp4 2>/dev/null | wc -l)
        log_info "Segmentos ya existen ($count encontrados), saltando creacion"
        return 0
    fi
    
    # Obtener duración exacta del video
    local total_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    
    if [ -z "$total_duration" ] || [ "$total_duration" -le 0 ]; then
        total_duration=2166
    fi
    
    # Calcular número exacto de segmentos
    local segment_count=$(echo "scale=0; ($total_duration + $duration - 0.1) / $duration" | bc)
    segment_count=$(printf "%.0f" "$segment_count")
    
    log_info "Duracion total: ${total_duration}s, creando $segment_count segmentos..."
    
    local created_count=0
    
    for ((i=0; i<segment_count; i++)); do
        local start=$(echo "scale=3; $i * $duration" | bc)
        local segment_name=$(printf "segment_%03d.mp4" $i)
        
        # Calcular duración del último segmento
        local current_duration=$duration
        if [ $i -eq $((segment_count - 1)) ]; then
            current_duration=$(echo "scale=3; $total_duration - ($i * $duration)" | bc)
            # Asegurar duración mínima
            if (( $(echo "$current_duration < 0.5" | bc -l) )); then
                current_duration=0.5
            fi
        fi
        
        if [ $((i % 10)) -eq 0 ]; then
            log_info "Creando segmento $((i+1))/$segment_count..."
        fi
        
        # Usar -copyts para preservar timestamps y -avoid_negative_ts make_zero para normalizar
        ffmpeg -loglevel quiet -i "$input" \
            -ss "$start" \
            -t "$current_duration" \
            -c copy \
            -avoid_negative_ts make_zero \
            -copyts \
            -start_at_zero \
            -y "$segment_name" 2>/dev/null
        
        if [ -f "$segment_name" ] && [ -s "$segment_name" ]; then
            # Verificar duración del segmento
            local seg_duration=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$segment_name" 2>/dev/null)
            
            # Redondear para comparación
            local seg_duration_rounded=$(printf "%.1f" "$seg_duration")
            local expected_rounded=$(printf "%.1f" "$current_duration")
            
            if (( $(echo "$seg_duration > 0.5" | bc -l) )); then
                ((created_count++))
                if [ $((i % 10)) -eq 0 ]; then
                    log_info "  Segmento $i: ${seg_duration}s (esperado: ${current_duration}s)"
                fi
            else
                log_warning "  Segmento $i demasiado corto: ${seg_duration}s"
                rm -f "$segment_name" 2>/dev/null
            fi
        else
            log_warning "  Fallo al crear segmento $((i+1))"
        fi
    done
    
    if [ $created_count -gt 0 ]; then
        log_success "Creados $created_count/$segment_count segmentos"
        return 0
    else
        log_error "No se pudieron crear segmentos"
        return 1
    fi
}

build_vvc_command() {
    local input="$1"
    local output="$2"
    
    local vvenc_cmd="vvencapp"
    
    local params=(
        "--input \"$input\""
        "--output \"$output\""
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
        "--decodedpicturehash 1"
    )
    
    local additional_params=(
        "RateControl=0" #suprimir parametro no reconocido util en 2 pasadas
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
    
    echo "$vvenc_cmd ${params[*]} --additional \"$additional_str\""
}

convert_segment_ffmpeg() {
    local input="$1"
    local output="$2"
    local attempt="$3"
    
    local log_file="log_$(basename "$input" .mp4)_ffmpeg_attempt${attempt}.txt"
    
    log_info "Usando FFmpeg para: $(basename "$input")"
    
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
    
    # Fallback a FFmpeg
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

process_all_segments() {
    local segments=($(ls -1v segment_*.mp4 2>/dev/null))
    local total=${#segments[@]}
    
    if [ $total -eq 0 ]; then
        log_error "No se encontraron segmentos"
        return 1
    fi
    
    log_info "Procesando $total segmentos..."
    
    local processed=0
    local failed=0
    
    # Procesar secuencialmente para evitar problemas
    for i in "${!segments[@]}"; do
        local segment="${segments[$i]}"
        local segment_num=$((i + 1))
        
        # Mostrar progreso
        local progress=$((segment_num * 100 / total))
        echo -ne "\rProgreso: $segment_num/$total segmentos ($progress%)"
        
        # Procesar segmento
        if process_segment "$segment" "$segment_num" "$total"; then
            ((processed++))
        else
            ((failed++))
        fi
        
        # Checkpoint
        if [ $((segment_num % BACKUP_EVERY)) -eq 0 ]; then
            echo ""
            log_info "Checkpoint: $segment_num/$total procesados"
        fi
    done
    
    echo ""
    log_info "Procesamiento completado"
    log_info "Exitos: $processed/$total"
    log_info "Fallos: $failed/$total"
    
    if [ $processed -eq 0 ]; then
        log_error "Ningun segmento se proceso exitosamente"
        return 1
    fi
    
    return 0
}

# Función para unir segmentos - CORREGIDA
merge_segments() {
    local output="$1"
    
    log_info "Uniendo segmentos convertidos..."
    
    # Crear lista de archivos a unir en orden correcto
    local segment_list="segment_list.txt"
    > "$segment_list"
    
    local converted_count=0
    local total_expected_duration=0
    
    log_info "Buscando archivos *_vvc.mp4..."
    
    # Ordenar archivos numericamente
    for vvc_file in $(ls -1v segment_*_vvc.mp4 2>/dev/null | sort -V); do
        if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
            # Verificar que sea un video válido
            if ffprobe -v error "$vvc_file" >/dev/null 2>&1; then
                # Obtener duración del segmento
                local seg_duration=$(ffprobe -v error -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 "$vvc_file" 2>/dev/null)
                total_expected_duration=$(echo "$total_expected_duration + $seg_duration" | bc)
                
                # Usar ruta relativa (mejor para concat)
                echo "file '$vvc_file'" >> "$segment_list"
                ((converted_count++))
                log_info "  Agregado: $vvc_file (${seg_duration}s)"
            else
                log_warning "  Archivo inválido (saltando): $vvc_file"
            fi
        fi
    done
    
    if [ $converted_count -eq 0 ]; then
        log_error "No hay segmentos convertidos válidos para unir"
        return 1
    fi
    
    log_info "Uniendo $converted_count segmentos (duración total esperada: ${total_expected_duration}s)..."
    
    # Mostrar primeras lineas del archivo de lista
    log_info "Archivo de lista contiene:"
    head -5 "$segment_list" | while read line; do
        log_info "  $line"
    done
    
    if [ $converted_count -gt 5 ]; then
        log_info "  ... y $((converted_count - 5)) más"
    fi
    
    # Crear directorio para el output si no existe
    local output_dir=$(dirname "$output")
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir"
    fi
    
    log_info "Iniciando union con FFmpeg..."
    
    local merge_log="merge_log.txt"
    local start_time=$(date +%s)
    
    # MÉTODO 1: FFmpeg con concat (versión mejorada)
    log_info "Método 1: FFmpeg con concat..."
    
    if ffmpeg -f concat \
        -safe 0 \
        -i "$segment_list" \
        -c copy \
        -fflags +genpts \
        -movflags +faststart+empty_moov \
        -y "$output" 2> "$merge_log"; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [ -f "$output" ] && [ -s "$output" ]; then
            if ffprobe -v error "$output" >/dev/null 2>&1; then
                # Verificar duración final
                local final_duration=$(ffprobe -v error -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null)
                
                # Verificar número de pistas de audio
                local audio_tracks=$(ffprobe -v error -show_entries stream=codec_type \
                    -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | grep -c "audio" || echo 0)
                
                log_info "Método 1 - Duración: ${final_duration}s, Pistas de audio: $audio_tracks"
                
                # Calcular diferencia (permitir 2 segundos de diferencia y 1 pista de audio)
                local duration_diff=$(echo "$final_duration - $total_expected_duration" | bc)
                local abs_diff=$(echo "$duration_diff" | sed 's/-//')
                
                if (( $(echo "$abs_diff < 2.0" | bc -l) )) && [ $audio_tracks -eq 1 ]; then
                    local final_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
                    log_success "Video unido exitosamente en ${duration}s"
                    log_info "Tamaño: $((final_size / 1048576)) MB"
                    rm -f "$merge_log" "$segment_list"
                    return 0
                else
                    log_warning "Método 1 falló: diferencia=${duration_diff}s, pistas=$audio_tracks"
                fi
            fi
        fi
    fi
    
    # MÉTODO 2: Usar el filtro concat de FFmpeg (une pistas correctamente)
    log_info "Método 2: Filtro concat de FFmpeg..."
    
    # Construir cadena de entrada para el filtro concat
    local input_files=""
    local filter_inputs=""
    local stream_maps=""
    local file_index=0
    
    for vvc_file in $(ls -1v segment_*_vvc.mp4 2>/dev/null | sort -V); do
        if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
            input_files="$input_files -i \"$vvc_file\""
            if [ $file_index -eq 0 ]; then
                filter_inputs="[${file_index}:v][${file_index}:a]"
            else
                filter_inputs="${filter_inputs}[${file_index}:v][${file_index}:a]"
            fi
            ((file_index++))
        fi
    done
    
    if [ $file_index -gt 0 ]; then
        # Construir comando con filtro concat
        local filter_complex="${filter_inputs}concat=n=$file_index:v=1:a=1[outv][outa]"
        local cmd="ffmpeg $input_files -filter_complex \"$filter_complex\" -map \"[outv]\" -map \"[outa]\" -c:v copy -c:a copy -movflags +faststart -y \"$output\" 2>> $merge_log"
        
        if eval "$cmd"; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                local final_duration=$(ffprobe -v error -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null)
                
                local audio_tracks=$(ffprobe -v error -show_entries stream=codec_type \
                    -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | grep -c "audio" || echo 0)
                
                log_info "Método 2 - Duración: ${final_duration}s, Pistas de audio: $audio_tracks"
                
                local duration_diff=$(echo "$final_duration - $total_expected_duration" | bc)
                local abs_diff=$(echo "$duration_diff" | sed 's/-//')
                
                if (( $(echo "$abs_diff < 2.0" | bc -l) )) && [ $audio_tracks -eq 1 ]; then
                    log_success "Video unido exitosamente (método 2)"
                    rm -f "$merge_log" "$segment_list"
                    return 0
                fi
            fi
        fi
    fi
    
    # MÉTODO 3: Usar mkvmerge y luego combinar pistas de audio
    if command -v mkvmerge &> /dev/null; then
        log_info "Método 3: mkvmerge con combinación de pistas..."
        
        local temp_mkv="${output%.*}.temp.mkv"
        local temp_mp4="${output%.*}.temp.mp4"
        local mkv_files=()
        
        for vvc_file in $(ls -1v segment_*_vvc.mp4 2>/dev/null | sort -V); do
            if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
                mkv_files+=("$vvc_file")
            fi
        done
        
        if [ ${#mkv_files[@]} -gt 0 ]; then
            # Crear MKV con mkvmerge
            if mkvmerge -o "$temp_mkv" "${mkv_files[@]}" 2>/dev/null; then
                log_info "MKV creado, combinando pistas de audio..."
                
                # Verificar cuántas pistas de audio tiene el MKV
                local audio_tracks=$(mkvmerge -i "$temp_mkv" 2>/dev/null | grep -c "audio" || echo 0)
                log_info "Pistas de audio en MKV: $audio_tracks"
                
                if [ $audio_tracks -gt 1 ]; then
                    log_info "Múltiples pistas detectadas, combinando..."
                    
                    # Usar FFmpeg para combinar todas las pistas de audio en una sola
                    # Primero extraer todas las pistas y combinarlas
                    local audio_filter=""
                    for ((i=0; i<audio_tracks; i++)); do
                        audio_filter="${audio_filter}[0:a:$i]"
                    done
                    audio_filter="${audio_filter}amerge=inputs=$audio_tracks[aout]"
                    
                    ffmpeg -i "$temp_mkv" \
                        -filter_complex "$audio_filter" \
                        -map 0:v -map "[aout]" \
                        -c:v copy \
                        -c:a libopus \
                        -b:a 256k \
                        -ac 2 \
                        -movflags +faststart \
                        -y "$temp_mp4" 2>/dev/null
                    
                    if [ -f "$temp_mp4" ] && [ -s "$temp_mp4" ]; then
                        mv "$temp_mp4" "$output"
                    fi
                else
                    # Solo una pista, convertir directamente
                    ffmpeg -i "$temp_mkv" \
                        -map 0:v -map 0:a \
                        -c copy \
                        -movflags +faststart \
                        -y "$temp_mp4" 2>/dev/null
                    
                    if [ -f "$temp_mp4" ] && [ -s "$temp_mp4" ]; then
                        mv "$temp_mp4" "$output"
                    fi
                fi
                
                if [ -f "$output" ] && [ -s "$output" ]; then
                    if ffprobe -v error "$output" >/dev/null 2>&1; then
                        local final_duration=$(ffprobe -v error -show_entries format=duration \
                            -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null)
                        
                        local audio_tracks_final=$(ffprobe -v error -show_entries stream=codec_type \
                            -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | grep -c "audio" || echo 0)
                        
                        log_info "Método 3 - Duración: ${final_duration}s, Pistas finales: $audio_tracks_final"
                        
                        local duration_diff=$(echo "$final_duration - $total_expected_duration" | bc)
                        local abs_diff=$(echo "$duration_diff" | sed 's/-//')
                        
                        if (( $(echo "$abs_diff < 2.0" | bc -l) )) && [ $audio_tracks_final -eq 1 ]; then
                            log_success "Video unido exitosamente con mkvmerge + combinación"
                            rm -f "$temp_mkv" "$temp_mp4" "$merge_log" "$segment_list"
                            return 0
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    # MÉTODO 4: Último recurso - re-encode completo
    log_warning "Método 4: Re-encode completo de video y audio..."
    
    local temp_list="concat_list.txt"
    > "$temp_list"
    for vvc_file in $(ls -1v segment_*_vvc.mp4 2>/dev/null | sort -V); do
        if [ -f "$vvc_file" ] && [ -s "$vvc_file" ]; then
            echo "file '$vvc_file'" >> "$temp_list"
        fi
    done
    
    # Re-encode completo para asegurar sync
    if ffmpeg -f concat -safe 0 -i "$temp_list" \
        -c:v libx264 \
        -crf 18 \
        -preset veryfast \
        -c:a libopus \
        -b:a 256k \
        -ac 2 \
        -movflags +faststart \
        -y "$output" 2>> "$merge_log"; then
        
        if [ -f "$output" ] && [ -s "$output" ]; then
            local final_duration=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null)
            
            local audio_tracks=$(ffprobe -v error -show_entries stream=codec_type \
                -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | grep -c "audio" || echo 0)
            
            log_info "Método 4 - Duración: ${final_duration}s, Pistas: $audio_tracks"
            
            if [ $audio_tracks -eq 1 ]; then
                log_success "Video unido exitosamente (re-encode)"
                rm -f "$merge_log" "$segment_list" "$temp_list"
                return 0
            fi
        fi
    fi
    
    log_error "Todos los métodos de unión fallaron"
    rm -f "$temp_mkv" "$temp_mp4" "$merge_log" "$segment_list" "$temp_list" 2>/dev/null
    return 1
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
    local required_gb=30
    local available_gb=100
    
    if command -v df &> /dev/null; then
        available_gb=$(df -BG . 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print int($4)}' || echo 100)
    fi
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_warning "Espacio en disco bajo: ${available_gb}GB disponibles"
        log_warning "Se recomienda al menos ${required_gb}GB"
        log_warning "Continuando de todos modos..."
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
    
    # Configurar segun preset
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
    
    WORK_DIR="vvc_encode_tmp" # $(date +%Y%m%d_%H%M%S)" cambiado por tmp para recuperar trabajo desde una parada del comando
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit 1
    
    log_info "Directorio de trabajo: $WORK_DIR"
    
    # Crear segmentos - IMPORTANTE: sin usar HW_ACCEL que causa problemas
    if ! create_segments "$VIDEO_INPUT" "$SEGMENT_DURATION"; then
        log_error "Fallo al crear segmentos"
        cd ..
        exit 1
    fi
    
    # Procesar segmentos
    if ! process_all_segments; then
        log_warning "Algunos segmentos fallaron, continuando..."
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