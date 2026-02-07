#!/bin/bash

# ====================================================
# SCRIPT DE CONVERSIÓN H.266 CON ORDEN DE PREFERENCIA
# CUDA → VAAPI → QSV/VDPAU → SOFTWARE
# ====================================================

# CONFIGURACIÓN PRINCIPAL
VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 h266_Optimizado.mp4"

# CONFIGURACIÓN DE SEGMENTOS (OPTIMIZADO PARA ¿?)
DURACION_SEGMENTO=30  # 5 minutos (óptimo para paralelización)
MAX_REINTENTOS=1

# TIMEOUT OPTIMIZADO
TIMEOUT_POR_SEGMENTO=$((2 * 60 * 60))  # 60 minutos (reducido por paralelización)

# CONFIGURACIÓN DE CODIFICACIÓN H.266
ENCODER_VVC="libvvenc"
PRESET_VVC="slower"           # Balance calidad/velocidad
BITRATE_VIDEO="16M"
ENCODER_AUDIO="libopus"
BITRATE_AUDIO="256k"

# CONFIGURACIÓN DE PARALELIZACIÓN PARA ¿?
MAX_SEGMENTOS_PARALELOS=8     # 8 segmentos simultáneos
THREADS_POR_SEGMENTO=4        # 4 hilos por segmento (8×4=32 hilos)

# ORDEN DE PREFERENCIA DE HWACCEL (¡EXACTAMENTE COMO QUIERES!)
HWACCEL_PREFERENCE=("cuda" "vaapi" "qsv" "vdpau" "")  # "" = software
HWACCEL_METHOD=""  # Se detectará automáticamente
HWACCEL_DEVICE=""  # Dispositivo específico si es necesario

# CONTROL DE BUCLES
MAX_FALLOS_CONSECUTIVOS=3
PAUSA_ENTRE_REINTENTOS=5

# OPTIMIZACIONES VVC
VVC_PARAMS="-tune zerolatency -rc 0 -qp 32"

# COLORES
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# =================================================================
# FUNCIONES COMPLETAS
# =================================================================

# FUNCIÓN: Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_progress() { echo -e "${CYAN}[PROGRESS]${NC} $1"; }
log_timeout() { echo -e "${RED}[TIMEOUT]${NC} $1"; }
log_hwaccel() { echo -e "${PURPLE}[HWACCEL]${NC} $1"; }

# FUNCIÓN: Formatear tiempo
formatear_tiempo() {
    local segundos=$1
    local horas=$((segundos / 3600))
    local minutos=$(((segundos % 3600) / 60))
    local segs=$((segundos % 60))
    printf "%02d:%02d:%02d" $horas $minutos $segs
}

# FUNCIÓN: Obtener información de CPU
get_cpu_info() {
    echo "cores:$(nproc --all) threads:$(nproc)"
}

# FUNCIÓN: Detectar HWACCEL según orden de preferencia
detectar_hwaccel_preferencia() {
    log_hwaccel "Detectando aceleración por hardware (orden: CUDA → VAAPI → QSV → VDPAU → Software)..."
    
    # Verificar si ffmpeg soporta hwaccel
    local hwaccels_disponibles=$(ffmpeg -hwaccels 2>/dev/null | tail -n +2)
    
    if [ -z "$hwaccels_disponibles" ]; then
        log_warning "No se pueden detectar métodos HWACCEL"
        echo ""
        return 1
    fi
    
    log_info "Métodos HWACCEL disponibles en ffmpeg:"
    echo "$hwaccels_disponibles" | while read line; do
        log_info "  - $line"
    done
    
    # Probar en orden de preferencia
    for metodo in "${HWACCEL_PREFERENCE[@]}"; do
        if [ -n "$metodo" ]; then
            log_hwaccel "Probando: $metodo"
            
            # Verificar si está en la lista de disponibles
            if ! echo "$hwaccels_disponibles" | grep -qi "$metodo"; then
                log_warning "  $metodo no está disponible en ffmpeg"
                continue
            fi
            
            # Prueba específica para cada método
            case $metodo in
                "cuda")
                    if verificar_cuda; then
                        log_success "✓ CUDA seleccionado"
                        HWACCEL_DEVICE="0"  # GPU 0 por defecto
                        echo "cuda"
                        return 0
                    fi
                    ;;
                "vaapi")
                    if verificar_vaapi; then
                        log_success "✓ VAAPI seleccionado"
                        HWACCEL_DEVICE="/dev/dri/renderD128"
                        echo "vaapi"
                        return 0
                    fi
                    ;;
                "qsv")
                    if verificar_qsv; then
                        log_success "✓ QSV seleccionado"
                        echo "qsv"
                        return 0
                    fi
                    ;;
                "vdpau")
                    if verificar_vdpau; then
                        log_success "✓ VDPAU seleccionado"
                        echo "vdpau"
                        return 0
                    fi
                    ;;
            esac
        else
            log_warning "Usando decodificación por software"
            echo ""
            return 0
        fi
    done
    
    log_warning "Ningún método HWACCEL funcionó, usando software"
    echo ""
    return 0
}

# FUNCIÓN: Verificar CUDA específicamente
verificar_cuda() {
    log_info "Verificando CUDA..."
    
    # 1. Verificar si hay GPU NVIDIA
    if ! command -v nvidia-smi &> /dev/null; then
        log_warning "  nvidia-smi no encontrado (sin drivers NVIDIA?)"
        return 1
    fi
    
    # 2. Verificar GPU activa
    local gpu_info=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)
    if [ -z "$gpu_info" ]; then
        log_warning "  No se pudo obtener información de GPU NVIDIA"
        return 1
    fi
    
    log_info "  GPU NVIDIA detectada: $gpu_info"
    
    # 3. Verificar si ffmpeg tiene soporte CUDA
    if ! ffmpeg -hwaccels 2>/dev/null | grep -q "cuda"; then
        log_warning "  FFmpeg no tiene soporte CUDA compilado"
        return 1
    fi
    
    # 4. Probar con video pequeño
    log_info "  Probando decodificación CUDA..."
    local test_cmd="ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i \"$VIDEO_ORIGINAL\" -t 2 -f null -"
    
    if eval "$test_cmd" 2>/tmp/cuda_test.log; then
        log_success "  CUDA funciona correctamente"
        return 0
    else
        log_warning "  CUDA falló en prueba"
        local error_line=$(tail -3 /tmp/cuda_test.log | head -1)
        log_warning "  Error: $error_line"
        return 1
    fi
}

# FUNCIÓN: Verificar VAAPI específicamente
verificar_vaapi() {
    log_info "Verificando VAAPI (AMD)..."
    
    # 1. Verificar dispositivos DRI
    if [ ! -d "/dev/dri" ]; then
        log_warning "  /dev/dri no existe"
        return 1
    fi
    
    # 2. Buscar dispositivos render
    local render_devices=$(find /dev/dri -name "renderD*" | sort)
    if [ -z "$render_devices" ]; then
        log_warning "  No hay dispositivos renderD* en /dev/dri"
        return 1
    fi
    
    log_info "  Dispositivos render encontrados:"
    echo "$render_devices" | while read device; do
        log_info "    - $device"
    done
    
    # 3. Probar con cada dispositivo
    for device in $render_devices; do
        log_info "  Probando dispositivo: $device"
        
        local test_cmd="ffmpeg -hwaccel vaapi -hwaccel_device $device"
        test_cmd+=" -hwaccel_output_format vaapi"
        test_cmd+=" -i \"$VIDEO_ORIGINAL\" -t 2 -f null -"
        
        if eval "$test_cmd" 2>/dev/null; then
            log_success "  VAAPI funciona con dispositivo: $device"
            HWACCEL_DEVICE="$device"
            return 0
        fi
    done
    
    log_warning "  Ningún dispositivo VAAPI funcionó"
    return 1
}

# FUNCIÓN: Verificar QSV
verificar_qsv() {
    log_info "Verificando QSV (Intel)..."
    
    # Buscar dispositivos Intel
    if ls /dev/dri/renderD* 2>/dev/null | grep -q "renderD"; then
        local test_cmd="ffmpeg -hwaccel qsv -hwaccel_device /dev/dri/renderD128"
        test_cmd+=" -i \"$VIDEO_ORIGINAL\" -t 2 -f null -"
        
        if eval "$test_cmd" 2>/dev/null; then
            log_success "  QSV funciona"
            return 0
        fi
    fi
    
    log_warning "  QSV no disponible"
    return 1
}

# FUNCIÓN: Verificar VDPAU
verificar_vdpau() {
    log_info "Verificando VDPAU..."
    
    local test_cmd="ffmpeg -hwaccel vdpau -i \"$VIDEO_ORIGINAL\" -t 2 -f null -"
    
    if eval "$test_cmd" 2>/dev/null; then
        log_success "  VDPAU funciona"
        return 0
    fi
    
    log_warning "  VDPAU no disponible"
    return 1
}

# FUNCIÓN: Configurar para ¿?
configurar_para_¿?() {
    local cpu_info=$(get_cpu_info)
    local cores=$(echo $cpu_info | cut -d: -f2 | cut -d' ' -f1)
    local threads=$(echo $cpu_info | cut -d: -f3)
    
    log_info "CPU detectado: $cores núcleos, $threads hilos"
    
    # Ajuste automático basado en hilos
    if [ $threads -ge 32 ]; then
        MAX_SEGMENTOS_PARALELOS=8
        THREADS_POR_SEGMENTO=4
        log_success "Configuración óptima para 32+hilos: 8×4"
    elif [ $threads -ge 16 ]; then
        MAX_SEGMENTOS_PARALELOS=4
        THREADS_POR_SEGMENTO=4
        log_success "Configuración para 16+hilos: 4×4"
    else
        MAX_SEGMENTOS_PARALELOS=2
        THREADS_POR_SEGMENTO=2
        log_warning "Configuración conservadora"
    fi
    
    echo "paralelos:$MAX_SEGMENTOS_PARALELOS threads_por_segmento:$THREADS_POR_SEGMENTO"
}

# FUNCIÓN: Verificar archivo
verificar_archivo() {
    local archivo="$1"
    if [ ! -f "$archivo" ]; then
        log_error "Archivo no encontrado: $archivo"
        return 1
    fi
    
    local tamano=$(stat -c%s "$archivo" 2>/dev/null || echo 0)
    if [ $tamano -lt 1024 ]; then
        log_error "Archivo demasiado pequeño: $archivo"
        return 1
    fi
    
    return 0
}

# FUNCIÓN: Verificar compatibilidad VVC
verificar_vvc() {
    log_info "Verificando soporte VVC (libvvenc)..."
    
    if ! ffmpeg -encoders 2>/dev/null | grep -q "libvvenc"; then
        log_error "libvvenc no está disponible en ffmpeg"
        log_info "Compila ffmpeg con: --enable-libvvenc"
        return 1
    fi
    
    log_success "libvvenc disponible"
    
    # Mostrar información del encoder
    local vvc_info=$(ffmpeg -h encoder=libvvenc 2>&1 | grep -E "Supported|Preset" | head -5)
    if [ -n "$vvc_info" ]; then
        log_info "Información libvvenc:"
        echo "$vvc_info" | while read line; do
            log_info "  $line"
        done
    fi
    
    return 0
}

# FUNCIÓN: Verificar si un video está completo
verificar_video_completo() {
    local ruta_video="$1"
    
    if [ ! -f "$ruta_video" ]; then
        return 1
    fi
    
    local tamano=$(stat -c%s "$ruta_video" 2>/dev/null || echo 0)
    if [ "$tamano" -lt 102400 ]; then
        return 1
    fi
    
    local duracion=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$ruta_video" 2>/dev/null)
    
    if [ -z "$duracion" ] || [ "$(echo "$duracion == 0" | bc -l 2>/dev/null)" = "1" ]; then
        return 1
    fi
    
    ffmpeg -v error -i "$ruta_video" -f null - 2>&1 >/dev/null
    return $?
}

# FUNCIÓN: Obtener duración del video
obtener_duracion() {
    local ruta_video="$1"
    local duracion=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$ruta_video" 2>/dev/null)
    
    if [ -n "$duracion" ]; then
        echo "${duracion%.*}"
    else
        echo "0"
    fi
}

# FUNCIÓN: Monitorear uso de CPU
monitorear_cpu() {
    local pid=$1
    local nombre=$2
    
    while kill -0 $pid 2>/dev/null; do
        local cpu_usage=$(ps -p $pid -o %cpu 2>/dev/null | tail -1 | tr -d ' ' | cut -d. -f1)
        
        if [ -n "$cpu_usage" ]; then
            if [ "$cpu_usage" -lt 10 ]; then
                log_warning "$nombre usando solo $cpu_usage% CPU (puede estar bloqueado)"
                # Esperar 30s y verificar si sigue bajo
                sleep 30
                local cpu_usage2=$(ps -p $pid -o %cpu 2>/dev/null | tail -1 | tr -d ' ' | cut -d. -f1)
                if [ "$cpu_usage2" -lt 10 ]; then
                    return 1  # Está bloqueado
                fi
            elif [ "$cpu_usage" -gt 90 ]; then
                log_info "$nombre usando $cpu_usage% CPU (óptimo)"
            fi
        fi
        
        sleep 10
    done
    
    return 0
}

# FUNCIÓN: Ejecutar comando con timeout
ejecutar_con_timeout() {
    local comando="$1"
    local log_file="$2"
    local timeout_segundos="$3"
    local nombre="$4"
    
    local inicio=$(date +%s)
    local tiempo_limite=$((inicio + timeout_segundos))
    
    # Ejecutar en background
    eval "$comando" > "$log_file" 2>&1 &
    local pid=$!
    
    # Iniciar monitoreo de CPU
    monitorear_cpu $pid "$nombre" &
    local monitor_pid=$!
    
    local exit_code=0
    while kill -0 $pid 2>/dev/null; do
        local ahora=$(date +%s)
        
        if [ $ahora -ge $tiempo_limite ]; then
            log_timeout "Timeout para $nombre"
            kill -9 $pid 2>/dev/null
            exit_code=124
            break
        fi
        
        # Verificar si monitor reportó bloqueo
        if ! kill -0 $monitor_pid 2>/dev/null 2>/dev/null; then
            log_error "$nombre bloqueado detectado"
            kill -9 $pid 2>/dev/null
            exit_code=125
            break
        fi
        
        sleep 5
    done
    
    # Limpiar
    if kill -0 $pid 2>/dev/null; then
        wait $pid
        exit_code=$?
    fi
    
    kill -9 $monitor_pid 2>/dev/null 2>/dev/null
    
    local fin=$(date +%s)
    local duracion=$((fin - inicio))
    
    log_info "$nombre completado en $(formatear_tiempo $duracion) - Exit: $exit_code"
    return $exit_code
}

# FUNCIÓN: Construir comando FFmpeg con HWACCEL
construir_comando_ffmpeg() {
    local entrada="$1"
    local salida="$2"
    
    local cmd="ffmpeg "
    
    # Añadir HWACCEL si está configurado
    if [ -n "$HWACCEL_METHOD" ]; then
        cmd+="-hwaccel $HWACCEL_METHOD "
        
        # Añadir dispositivo específico si es necesario
        if [ -n "$HWACCEL_DEVICE" ]; then
            case $HWACCEL_METHOD in
                "cuda")
                    cmd+="-hwaccel_device $HWACCEL_DEVICE "
                    cmd+="-hwaccel_output_format cuda "
                    ;;
                "vaapi")
                    cmd+="-hwaccel_device $HWACCEL_DEVICE "
                    cmd+="-hwaccel_output_format vaapi "
                    ;;
                "qsv")
                    cmd+="-hwaccel_device $HWACCEL_DEVICE "
                    ;;
            esac
        fi
    fi
    
    cmd+="-i \"$entrada\" "
    cmd+="-c:v $ENCODER_VVC "
    cmd+="-preset $PRESET_VVC "
    cmd+="-b:v $BITRATE_VIDEO "
    cmd+="-c:a $ENCODER_AUDIO "
    cmd+="-b:a $BITRATE_AUDIO "
    
    # Optimizaciones de rendimiento
    cmd+="-threads $THREADS_POR_SEGMENTO "
    cmd+="-row-mt 1 "
    cmd+="-frame-parallel 1 "
    
    # Parámetros VVC adicionales
    if [ -n "$VVC_PARAMS" ]; then
        cmd+="$VVC_PARAMS "
    fi
    
    cmd+="-y "
    cmd+="\"$salida\""
    
    echo "$cmd"
}

# FUNCIÓN: Convertir segmento
convertir_segmento() {
    local entrada="$1"
    local salida="$2"
    local reintento="$3"
    
    local nombre_base=$(basename "$entrada" .mp4")
    local log_file="${nombre_base}_reintento${reintento}_log.txt"
    
    # Construir comando
    local cmd=$(construir_comando_ffmpeg "$entrada" "$salida")
    
    # Ejecutar
    ejecutar_con_timeout "$cmd" "$log_file" "$TIMEOUT_POR_SEGMENTO" "$nombre_base"
    local exit_code=$?
    
    # Analizar resultado
    case $exit_code in
        0)
            if [ -f "$salida" ] && verificar_video_completo "$salida"; then
                local dur_orig=$(obtener_duracion "$entrada")
                local dur_conv=$(obtener_duracion "$salida")
                local diff=$((dur_orig - dur_conv))
                
                if [ ${diff#-} -lt 2 ]; then
                    echo "true"
                    rm -f "$log_file" 2>/dev/null
                    return 0
                fi
            fi
            echo "false"
            ;;
        124) echo "timeout" ;;
        125) echo "stuck" ;;
        *) echo "false" ;;
    esac
    
    return $exit_code
}

# FUNCIÓN: Procesar segmentos en paralelo
procesar_segmentos_paralelo() {
    local segmentos=("${!1}")
    local -n completados_ref=$2
    local -n fallados_ref=$3
    local -n estadisticas_ref=$4
    
    local total_segmentos=${#segmentos[@]}
    local inicio_global=$(date +%s)
    local procesos_activos=()
    local segmentos_procesados=0
    
    log_info "Iniciando conversión paralela"
    log_info "Método HWACCEL: ${HWACCEL_METHOD:-software}"
    if [ -n "$HWACCEL_DEVICE" ]; then
        log_info "Dispositivo: $HWACCEL_DEVICE"
    fi
    
    # Función para iniciar un segmento
    iniciar_segmento() {
        local idx=$1
        local segmento="${segmentos[$idx]}"
        local nombre_base=$(basename "$segmento" .mp4")
        local salida="${nombre_base}_vvc.mp4"
        
        # Saltar si ya existe
        if [ -f "$salida" ] && verificar_video_completo "$salida" ]; then
            completados_ref+=("$salida")
            estadisticas_ref[exitosos_sin_procesar]=$((estadisticas_ref[exitosos_sin_procesar] + 1))
            log_success "✓ $nombre_base ya convertido"
            return
        fi
        
        # Eliminar anterior
        rm -f "$salida" 2>/dev/null
        
        # Iniciar en background
        convertir_segmento "$segmento" "$salida" 1 >/dev/null 2>&1 &
        local pid=$!
        procesos_activos+=("$pid:$idx:$nombre_base")
        
        log_info "Iniciado $nombre_base (PID: $pid)"
    }
    
    # Procesar por lotes
    for ((i=0; i<total_segmentos; i+=MAX_SEGMENTOS_PARALELOS)); do
        # Iniciar lote actual
        procesos_activos=()
        
        for ((j=0; j<MAX_SEGMENTOS_PARALELOS && i+j<total_segmentos; j++)); do
            local idx=$((i + j))
            iniciar_segmento $idx
        done
        
        # Esperar y recolectar resultados
        for proceso in "${procesos_activos[@]}"; do
            local pid=$(echo $proceso | cut -d: -f1)
            local idx=$(echo $proceso | cut -d: -f2)
            local nombre_base=$(echo $proceso | cut -d: -f3)
            
            wait $pid 2>/dev/null
            local exit_code=$?
            
            local segmento="${segmentos[$idx]}"
            local salida="${nombre_base}_vvc.mp4"
            
            if [ $exit_code -eq 0 ] && [ -f "$salida" ] && verificar_video_completo "$salida" ]; then
                completados_ref+=("$salida")
                estadisticas_ref[exitosos]=$((estadisticas_ref[exitosos] + 1))
                log_success "✓ $nombre_base completado"
            else
                # Reintento
                log_warning "$nombre_base falló, reintentando..."
                sleep $PAUSA_ENTRE_REINTENTOS
                
                local resultado=$(convertir_segmento "$segmento" "$salida" 2)
                
                if [ "$resultado" = "true" ]; then
                    completados_ref+=("$salida")
                    estadisticas_ref[exitosos_reintento]=$((estadisticas_ref[exitosos_reintento] + 1))
                    log_success "✓ $nombre_base recuperado"
                else
                    fallados_ref+=("$nombre_base")
                    estadisticas_ref[fallados]=$((estadisticas_ref[fallados] + 1))
                    log_error "✗ $nombre_base falló definitivamente"
                fi
            fi
            
            segmentos_procesados=$((segmentos_procesados + 1))
        done
        
        # Mostrar progreso
        local tiempo_transcurrido=$(( $(date +%s) - inicio_global ))
        local porcentaje=$(( (segmentos_procesados * 100) / total_segmentos ))
        
        echo -ne "\r${CYAN}[PROGRESS]${NC} $segmentos_procesados/$total_segmentos ($porcentaje%) "
        echo -ne "⏱️ $(formatear_tiempo $tiempo_transcurrido) "
        
        # Estimación
        if [ $segmentos_procesados -gt 0 ]; then
            local tiempo_promedio=$((tiempo_transcurrido / segmentos_procesados))
            local segmentos_restantes=$((total_segmentos - segmentos_procesados))
            local tiempo_restante=$((segmentos_restantes * tiempo_promedio / MAX_SEGMENTOS_PARALELOS))
            
            echo -ne "⏳ Final: $(date -d "+$tiempo_restante seconds" '+%H:%M')"
        fi
    done
    
    echo ""
}

# ============================================
# PROGRAMA PRINCIPAL
# ============================================

clear
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   CONVERSIÓN H.266 CON ORDEN DE PREFERENCIA HWACCEL${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Orden de preferencia:${NC}"
echo -e "  1. ${GREEN}CUDA (NVIDIA)${NC}"
echo -e "  2. ${YELLOW}VAAPI (AMD)${NC}"
echo -e "  3. ${BLUE}QSV (Intel)${NC}"
echo -e "  4. ${PURPLE}VDPAU${NC}"
echo -e "  5. Software (fallback)"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"

# Verificar archivo
if ! verificar_archivo "$VIDEO_ORIGINAL"; then
    exit 1
fi

# Verificar VVC
if ! verificar_vvc; then
    exit 1
fi

# Configurar para ¿?
log_info "Configurando para AMD Ryzen 9 ¿?..."
cpu_config=$(configurar_para_¿?)
MAX_SEGMENTOS_PARALELOS=$(echo $cpu_config | cut -d: -f2 | cut -d' ' -f1)
THREADS_POR_SEGMENTO=$(echo $cpu_config | cut -d: -f3)

echo -e "\n${BOLD}CONFIGURACIÓN CPU:${NC}"
echo -e "  Segmentos paralelos: $MAX_SEGMENTOS_PARALELOS"
echo -e "  Hilos por segmento: $THREADS_POR_SEGMENTO"
echo -e "  Total hilos utilizados: $((MAX_SEGMENTOS_PARALELOS * THREADS_POR_SEGMENTO))"

# Detectar HWACCEL
log_info "Detectando aceleración por hardware..."
HWACCEL_METHOD=$(detectar_hwaccel_preferencia)

echo -e "\n${BOLD}CONFIGURACIÓN HWACCEL:${NC}"
if [ -n "$HWACCEL_METHOD" ]; then
    echo -e "  Método seleccionado: ${GREEN}$HWACCEL_METHOD${NC}"
    if [ -n "$HWACCEL_DEVICE" ]; then
        echo -e "  Dispositivo: $HWACCEL_DEVICE"
    fi
else
    echo -e "  Método seleccionado: ${YELLOW}Software (sin HWACCEL)${NC}"
fi

# Información del video
duracion_video=$(obtener_duracion "$VIDEO_ORIGINAL")
segmentos_estimados=$(( (duracion_video + DURACION_SEGMENTO - 1) / DURACION_SEGMENTO ))

echo -e "\n${BOLD}INFORMACIÓN DEL VIDEO:${NC}"
echo -e "  Duración: $(formatear_tiempo $duracion_video)"
echo -e "  Segmentos estimados: $segmentos_estimados"
echo -e "  Duración por segmento: $DURACION_SEGMENTO segundos"

# Estimación de tiempo
if [ $segmentos_estimados -gt 0 ]; then
    local tiempo_por_segmento_estimado=1800  # 30 minutos base
    local tiempo_total_estimado=$(( (segmentos_estimados * tiempo_por_segmento_estimado) / MAX_SEGMENTOS_PARALELOS ))
    
    echo -e "\n${BOLD}ESTIMACIÓN:${NC}"
    echo -e "  Tiempo total estimado: $(formatear_tiempo $tiempo_total_estimado)"
    echo -e "  Finalización estimada: $(date -d "+$tiempo_total_estimado seconds" '+%Y-%m-%d %H:%M:%S')"
fi

echo -e "\n${BOLD}¿Iniciar conversión? (s/n)${NC}"
read -r respuesta
if [ "$respuesta" != "s" ]; then
    log_info "Proceso cancelado"
    exit 0
fi

# PASO 1: Dividir video
log_progress "Dividiendo video en segmentos..."

segmentos=($(ls -1v parte_*.mp4 2>/dev/null | grep '^parte_[0-9][0-9][0-9]\.mp4$'))

if [ ${#segmentos[@]} -eq 0 ]; then
    # Construir comando de división con HWACCEL si está disponible
    cmd_split="ffmpeg"
    
    if [ -n "$HWACCEL_METHOD" ]; then
        cmd_split+=" -hwaccel $HWACCEL_METHOD"
        if [ -n "$HWACCEL_DEVICE" ]; then
            cmd_split+=" -hwaccel_device $HWACCEL_DEVICE"
        fi
    fi
    
    cmd_split+=" -i \"$VIDEO_ORIGINAL\""
    cmd_split+=" -c copy -map 0"
    cmd_split+=" -segment_time $DURACION_SEGMENTO"
    cmd_split+=" -f segment -reset_timestamps 1"
    cmd_split+=" -segment_start_number 1"
    cmd_split+=" \"parte_%03d.mp4\""
    
    log_info "Ejecutando división..."
    eval "$cmd_split"
    
    segmentos=($(ls -1v parte_*.mp4 2>/dev/null | grep '^parte_[0-9][0-9][0-9]\.mp4$'))
    
    if [ ${#segmentos[@]} -eq 0 ]; then
        log_error "Error al crear segmentos"
        exit 1
    fi
fi

log_success "Segmentos listos: ${#segmentos[@]}"

# Inicializar
completados=()
fallados=()
declare -A estadisticas=(
    [exitosos_sin_procesar]=0
    [exitosos]=0
    [exitosos_reintento]=0
    [fallados]=0
)

# PASO 2: Procesar en paralelo
inicio_global=$(date +%s)
procesar_segmentos_paralelo segmentos completados fallados estadisticas
fin_global=$(date +%s)
tiempo_total=$((fin_global - inicio_global))

# PASO 3: Unir
if [ ${#completados[@]} -eq 0 ]; then
    log_error "No hay segmentos para unir"
    exit 1
fi

log_progress "Uniendo ${#completados[@]} segmentos..."

lista="lista_vvc_final.txt"
for completado in "${completados[@]}"; do
    echo "file '$completado'" >> "$lista"
done

ffmpeg -f concat -safe 0 -i "$lista" -c copy -y "$SALIDA_FINAL" 2>/dev/null

# Resultado final
if [ -f "$SALIDA_FINAL" ] && verificar_video_completo "$SALIDA_FINAL"; then
    tamano_bytes=$(stat -c%s "$SALIDA_FINAL" 2>/dev/null || echo 0)
    tamano_mb=$(echo "scale=2; $tamano_bytes / (1024*1024)" | bc)
    duracion_final=$(obtener_duracion "$SALIDA_FINAL")
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e "                   ${BOLD}✅ CONVERSIÓN COMPLETADA${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}RESULTADO:${NC}"
    echo -e "  Video final: $SALIDA_FINAL"
    echo -e "  Duración: $(formatear_tiempo $duracion_final)"
    echo -e "  Tamaño: $tamano_mb MB"
    echo -e "  Método HWACCEL: ${HWACCEL_METHOD:-software}"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}ESTADÍSTICAS:${NC}"
    echo -e "  Segmentos totales: ${#segmentos[@]}"
    echo -e "  Convertidos exitosos: ${#completados[@]}"
    echo -e "  Fallados: ${#fallados[@]}"
    echo -e "  Tiempo total: $(formatear_tiempo $tiempo_total)"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    
    # Rendimiento
    if [ $tiempo_total -gt 0 ] && [ ${#segmentos[@]} -gt 0 ]; then
        local segundos_por_segmento=$((tiempo_total / ${#segmentos[@]}))
        echo -e "${BOLD}RENDIMIENTO:${NC}"
        echo -e "  Tiempo/segmento: $(formatear_tiempo $segundos_por_segmento)"
        echo -e "  Segmentos/hora: $((3600 / segundos_por_segmento))"
    fi
    
    # Limpieza
    log_info "Limpiando archivos temporales..."
    rm -f parte_*.mp4 *_vvc.mp4 *_log.txt lista_*.txt 2>/dev/null
    log_success "Limpieza completada"
    
else
    log_error "Error al crear video final"
    echo -e "  Segmentos exitosos: ${#completados[@]}"
    echo -e "  Verificar logs individuales"
fi

log_info "Proceso finalizado"