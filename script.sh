#!/bin/bash

# ====================================================
# SCRIPT H.266 OPTIMIZADO - USO MÁXIMO DE CPU
# Auto-detección de núcleos + Paralelización inteligente
# ====================================================

# CONFIGURACIÓN PRINCIPAL
VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 h266_Optimizado.mp4"

# TU CONFIGURACIÓN EXACTA
DURACION_SEGMENTO=30                    # 30 segundos (como quieres)
PRESET_VVC="slower"                     # Preset slower (como quieres)
TIMEOUT_POR_SEGMENTO=$((2 * 60 * 60))   # 2 horas por segmento

# CONFIGURACIÓN DE CODIFICACIÓN
ENCODER_VVC="libvvenc"
BITRATE_VIDEO="16M"
ENCODER_AUDIO="libopus"
BITRATE_AUDIO="256k"

# CONFIGURACIÓN HWACCEL
HWACCEL_PREFERENCE=("cuda" "vaapi" "qsv" "vdpau" "")

# PARÁMETROS VVC AVANZADOS PARA MÁXIMA CALIDAD
VVC_PARAMS="-rc 0 -qp 32 -tune zerolatency --passes 2 --stats \"stats.log\""

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
# FUNCIÓN: DETECCIÓN AVANZADA DE CPU Y OPTIMIZACIÓN
# =================================================================

detectar_y_optimizar_cpu() {
    log_info "🔍 Analizando sistema para optimización máxima..."
    
    # 1. DETECTAR CPU REAL
    local cpu_model=$(lscpu | grep "Model name" | cut -d: -f2 | sed 's/^ *//')
    local cores=$(nproc --all)           # Núcleos físicos
    local threads=$(nproc)               # Hilos lógicos
    local sockets=$(lscpu | grep "Socket(s)" | cut -d: -f2 | tr -d ' ')
    
    log_info "CPU detectado: $cpu_model"
    log_info "Sockets: $sockets, Núcleos físicos: $cores, Hilos lógicos: $threads"
    
    # 2. DETECTAR ARQUITECTURA REAL DE TU 9950X
    # El 9950X tiene: 16 núcleos / 32 hilos
    # Pero en realidad son 2 CCDs de 8 núcleos cada uno
    
    # 3. CALCULAR OPTIMIZACIÓN ÓPTIMA
    # Para H.266 VVC con preset "slower", queremos:
    # - Múltiples procesos en paralelo (para usar todos los núcleos)
    # - Cada proceso con suficientes hilos para ser eficiente
    # - Evitar sobrecarga por demasiados procesos
    
    local segmentos_paralelos=0
    local hilos_por_proceso=0
    
    # REGLAS DE OPTIMIZACIÓN BASADAS EN EXPERIENCIA REAL
    if [ "$threads" -ge 32 ]; then
        # PARA 9950X (32 hilos) - OPTIMIZACIÓN ESPECÍFICA
        segmentos_paralelos=6           # 6 procesos en paralelo
        hilos_por_proceso=5             # 5 hilos por proceso (6×5=30 hilos)
        log_success "⚡ Configuración 9950X: 6 procesos × 5 hilos = 30/32 hilos utilizados"
        
    elif [ "$threads" -ge 24 ]; then
        segmentos_paralelos=4
        hilos_por_proceso=6             # 4×6=24 hilos
        log_success "Configuración 24+hilos: 4 procesos × 6 hilos"
        
    elif [ "$threads" -ge 16 ]; then
        segmentos_paralelos=3
        hilos_por_proceso=5             # 3×5=15 hilos
        log_success "Configuración 16+hilos: 3 procesos × 5 hilos"
        
    elif [ "$threads" -ge 8 ]; then
        segmentos_paralelos=2
        hilos_por_proceso=4             # 2×4=8 hilos
        log_success "Configuración 8+hilos: 2 procesos × 4 hilos"
        
    else
        segmentos_paralelos=1
        hilos_por_proceso=$threads
        log_warning "Configuración conservadora: 1 proceso × $hilos_por_proceso hilos"
    fi
    
    # 4. AJUSTAR PRIORIDADES Y AFFINITY PARA MÁXIMO RENDIMIENTO
    local cpu_affinity=""
    
    # Para CPUs con múltiples CCDs (como 9950X), distribuir procesos inteligentemente
    if [ "$sockets" -gt 1 ] || [ "$cores" -ge 16 ]; then
        # Distribuir entre CCDs/NUMA nodes
        cpu_affinity="0-15,16-31"  # Ejemplo para 9950X
        log_info "Affinity configurado para múltiples CCDs"
    fi
    
    # 5. CALCULAR THREADING ÓPTIMO PARA VVC
    # libvvenc funciona mejor con: threads = número de filas en el video / 2
    # Pero ajustamos dinámicamente
    
    echo "$segmentos_paralelos:$hilos_por_proceso:$cpu_affinity:$threads"
}

# =================================================================
# FUNCIÓN: MONITOREO EN TIEMPO REAL DE CPU
# =================================================================

iniciar_monitor_cpu() {
    local monitor_file="/tmp/cpu_monitor_$$.log"
    
    # Función de monitoreo en background
    monitor_cpu_background() {
        while true; do
            # Obtener uso de CPU total
            local cpu_total=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
            
            # Obtener uso por procesos ffmpeg
            local cpu_ffmpeg=$(ps -C ffmpeg -o %cpu --no-headers | awk '{sum+=$1} END {print sum}')
            
            # Contar procesos ffmpeg
            local count_ffmpeg=$(ps -C ffmpeg --no-headers | wc -l)
            
            echo "$(date '+%H:%M:%S') Total:${cpu_total}% FFmpeg:${cpu_ffmpeg}% Procesos:${count_ffmpeg}" >> "$monitor_file"
            
            # Mostrar en pantalla si es bajo
            if [ $(echo "$cpu_total < 50" | bc -l 2>/dev/null || echo "1") = "1" ] && [ "$count_ffmpeg" -gt 0 ]; then
                log_warning "⚠️  CPU baja: ${cpu_total}% (ffmpeg: ${cpu_ffmpeg}%)"
            fi
            
            sleep 5
        done
    }
    
    # Iniciar monitoreo
    monitor_cpu_background &
    MONITOR_PID=$!
    
    log_info "📊 Monitor CPU iniciado (PID: $MONITOR_PID)"
    echo "$MONITOR_PID:$monitor_file"
}

# =================================================================
# FUNCIÓN: CONVERSIÓN PARALELA INTELIGENTE
# =================================================================

convertir_paralelo_inteligente() {
    local entrada="$1"
    local salida="$2"
    local hwaccel="$3"
    local hilos="$4"
    local affinity="$5"
    
    local nombre_base=$(basename "$entrada" .mp4)
    local log_file="${nombre_base}_log.txt"
    
    # CONSTRUIR COMANDO OPTIMIZADO PARA MÁXIMA CPU
    local cmd=""
    
    # 1. ESTABLECER PRIORIDAD Y AFFINITY
    if [ -n "$affinity" ]; then
        cmd="taskset -c $affinity "
    fi
    
    # 2. AÑADIR TIMEOUT Y PRIORIDAD NICE
    cmd="${cmd}timeout $TIMEOUT_POR_SEGMENTO nice -n -5 "
    
    # 3. COMANDO FFMPEG OPTIMIZADO
    cmd="${cmd}ffmpeg "
    
    # HWACCEL si está disponible
    if [ -n "$hwaccel" ] && [ "$hwaccel" != "" ]; then
        cmd="${cmd}-hwaccel $hwaccel "
        if [ "$hwaccel" = "cuda" ]; then
            cmd="${cmd}-hwaccel_output_format cuda "
        elif [ "$hwaccel" = "vaapi" ]; then
            cmd="${cmd}-hwaccel_device /dev/dri/renderD128 "
        fi
    fi
    
    # PARÁMETROS OPTIMIZADOS PARA MÁXIMA CALIDAD/VELOCIDAD
    cmd="${cmd}-i \"$entrada\" "
    cmd="${cmd}-c:v $ENCODER_VVC "
    cmd="${cmd}-preset $PRESET_VVC "
    cmd="${cmd}-b:v $BITRATE_VIDEO "
    cmd="${cmd}-c:a $ENCODER_AUDIO "
    cmd="${cmd}-b:a $BITRATE_AUDIO "
    
    # OPTIMIZACIONES CRÍTICAS PARA USAR MÁS CPU:
    cmd="${cmd}-threads $hilos "                 # Número exacto de hilos
    cmd="${cmd}-row-mt 1 "                       # Multi-threading por filas
    cmd="${cmd}-frame-parallel 1 "               # Paralelismo a nivel de frame
    cmd="${cmd}-tile-columns 2 "                 # Columnas de tiles
    cmd="${cmd}-tile-rows 2 "                    # Filas de tiles
    cmd="${cmd}-aq-mode 3 "                      # Modo adaptativo agresivo
    cmd="${cmd}-bf 16 "                          # Más B-frames
    cmd="${cmd}-ref 6 "                          # Más frames de referencia
    
    # Añadir parámetros VVC adicionales
    if [ -n "$VVC_PARAMS" ]; then
        cmd="${cmd}$VVC_PARAMS "
    fi
    
    cmd="${cmd}-y "
    cmd="${cmd}\"$salida\" "
    
    # 4. REDIRECCIONAR OUTPUT PARA MONITOREO
    cmd="${cmd}2> \"$log_file\""
    
    # 5. EJECUTAR EN BACKGROUND
    log_info "🚀 Iniciando $nombre_base con $hilos hilos..."
    
    # Ejecutar y capturar PID
    eval "$cmd" &
    local pid=$!
    
    # Establecer prioridad máxima para el proceso
    renice -n -10 -p $pid 2>/dev/null
    
    echo "$pid:$nombre_base:$log_file"
}

# =================================================================
# FUNCIÓN: GESTIÓN DE PROCESOS PARALELOS
# =================================================================

gestionar_procesos_paralelos() {
    local segmentos=("${!1}")
    local segmentos_paralelos=$2
    local hilos_por_proceso=$3
    local affinity=$4
    
    local -n completados_ref=$5
    local -n fallados_ref=$6
    local -n estadisticas_ref=$7
    
    local total_segmentos=${#segmentos[@]}
    local procesos_activos=()
    local index=0
    local batch_size=$segmentos_paralelos
    
    log_info "🔄 Iniciando procesamiento paralelo ($segmentos_paralelos procesos × $hilos_por_proceso hilos)"
    
    # Iniciar monitor de CPU
    local monitor_info=$(iniciar_monitor_cpu)
    local monitor_pid=$(echo "$monitor_info" | cut -d: -f1)
    local monitor_file=$(echo "$monitor_info" | cut -d: -f2)
    
    while [ $index -lt $total_segmentos ] || [ ${#procesos_activos[@]} -gt 0 ]; do
        
        # 1. INICIAR NUEVOS PROCESOS SI HAY ESPACIO
        while [ ${#procesos_activos[@]} -lt $segmentos_paralelos ] && [ $index -lt $total_segmentos ]; do
            local segmento="${segmentos[$index]}"
            local nombre_base=$(basename "$segmento" .mp4)
            local salida="${nombre_base}_vvc.mp4"
            
            # Saltar si ya existe
            if [ -f "$salida" ] && [ -s "$salida" ]; then
                log_info "⏭️  Saltando $nombre_base (ya existe)"
                completados_ref+=("$salida")
                estadisticas_ref[exitosos_sin_procesar]=$((estadisticas_ref[exitosos_sin_procesar] + 1))
                ((index++))
                continue
            fi
            
            # Iniciar conversión
            local proceso_info=$(convertir_paralelo_inteligente "$segmento" "$salida" "$HWACCEL_METHOD" "$hilos_por_proceso" "$affinity")
            local pid=$(echo "$proceso_info" | cut -d: -f1)
            local nombre=$(echo "$proceso_info" | cut -d: -f2)
            
            procesos_activos+=("$pid:$nombre:$index")
            log_info "▶️  Iniciado $nombre (PID: $pid)"
            
            ((index++))
            
            # Pequeña pausa para evitar sobrecarga inicial
            sleep 0.5
        done
        
        # 2. VERIFICAR PROCESOS COMPLETADOS
        local nuevos_activos=()
        for proceso in "${procesos_activos[@]}"; do
            local pid=$(echo "$proceso" | cut -d: -f1)
            local nombre=$(echo "$proceso" | cut -d: -f2)
            local idx=$(echo "$proceso" | cut -d: -f3)
            
            if kill -0 "$pid" 2>/dev/null; then
                # Proceso aún activo
                nuevos_activos+=("$proceso")
            else
                # Proceso terminado, verificar resultado
                wait "$pid" 2>/dev/null
                local exit_code=$?
                
                local salida="${nombre}_vvc.mp4"
                
                if [ $exit_code -eq 0 ] && [ -f "$salida" ] && [ -s "$salida" ]; then
                    log_success "✅ $nombre completado"
                    completados_ref+=("$salida")
                    estadisticas_ref[exitosos]=$((estadisticas_ref[exitosos] + 1))
                else
                    log_error "❌ $nombre falló (exit: $exit_code)"
                    fallados_ref+=("$nombre")
                    estadisticas_ref[fallados]=$((estadisticas_ref[fallados] + 1))
                fi
            fi
        done
        
        procesos_activos=("${nuevos_activos[@]}")
        
        # 3. MOSTRAR PROGRESO
        local procesados=$((index - ${#procesos_activos[@]}))
        local porcentaje=$((procesados * 100 / total_segmentos))
        
        # Mostrar uso de CPU actual
        if [ -f "$monitor_file" ]; then
            local last_stats=$(tail -1 "$monitor_file" 2>/dev/null || echo "N/A")
            local cpu_total=$(echo "$last_stats" | grep -o "Total:[0-9.]*" | cut -d: -f2 || echo "0")
            local cpu_ffmpeg=$(echo "$last_stats" | grep -o "FFmpeg:[0-9.]*" | cut -d: -f2 || echo "0")
            
            printf "\r${CYAN}📊 Progreso: %d/%d (%d%%) | CPU Total: %s%% | CPU FFmpeg: %s%% | Activos: %d${NC}" \
                   "$procesados" "$total_segmentos" "$porcentaje" \
                   "${cpu_total:-0}" "${cpu_ffmpeg:-0}" "${#procesos_activos[@]}"
        else
            printf "\r${CYAN}📊 Progreso: %d/%d (%d%%) | Activos: %d${NC}" \
                   "$procesados" "$total_segmentos" "$porcentaje" "${#procesos_activos[@]}"
        fi
        
        # 4. PAUSA CORTA
        sleep 2
    done
    
    printf "\n"
    
    # Detener monitor
    kill "$monitor_pid" 2>/dev/null
    
    # Mostrar resumen de CPU
    if [ -f "$monitor_file" ]; then
        log_info "📈 Estadísticas de CPU durante la conversión:"
        tail -20 "$monitor_file" | while read line; do
            log_info "   $line"
        done
        rm -f "$monitor_file"
    fi
}

# =================================================================
# FUNCIONES BÁSICAS (igual que antes pero corregidas)
# =================================================================

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
log_warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }

verificar_archivo() {
    if [ ! -f "$1" ]; then
        log_error "Archivo no encontrado: $1"
        return 1
    fi
    return 0
}

formatear_tiempo() {
    local segundos=$1
    printf "%02d:%02d:%02d" $((segundos/3600)) $(((segundos%3600)/60)) $((segundos%60))
}

detectar_hwaccel() {
    for metodo in "${HWACCEL_PREFERENCE[@]}"; do
        [ -z "$metodo" ] && { echo ""; return 0; }
        
        if ffmpeg -hwaccel "$metodo" -f lavfi -i "nullsrc" -t 1 -f null - 2>/dev/null; then
            log_success "HWACCEL seleccionado: $metodo"
            echo "$metodo"
            return 0
        fi
    done
    echo ""
}

obtener_duracion() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | cut -d. -f1
}

# =================================================================
# PROGRAMA PRINCIPAL
# =================================================================

clear
printf "${BLUE}╔══════════════════════════════════════════════════╗${NC}\n"
printf "${BLUE}║    H.266 OPTIMIZADO - USO MÁXIMO DE CPU         ║${NC}\n"
printf "${BLUE}╚══════════════════════════════════════════════════╝${NC}\n"

# Verificar archivo
verificar_archivo "$VIDEO_ORIGINAL" || exit 1

# Detectar y optimizar CPU
log_info "🔧 Optimizando para tu procesador..."
cpu_config=$(detectar_y_optimizar_cpu)
SEGMENTOS_PARALELOS=$(echo "$cpu_config" | cut -d: -f1)
HILOS_POR_PROCESO=$(echo "$cpu_config" | cut -d: -f2)
AFFINITY=$(echo "$cpu_config" | cut -d: -f3)
TOTAL_HILOS=$(echo "$cpu_config" | cut -d: -f4)

printf "${CYAN}┌────────────────────────────────────────────────────┐${NC}\n"
printf "${CYAN}│ CONFIGURACIÓN OPTIMIZADA DETECTADA                │${NC}\n"
printf "${CYAN}├────────────────────────────────────────────────────┤${NC}\n"
printf "${CYAN}│ Procesos paralelos: %-29d │${NC}\n" "$SEGMENTOS_PARALELOS"
printf "${CYAN}│ Hilos por proceso:  %-29d │${NC}\n" "$HILOS_POR_PROCESO"
printf "${CYAN}│ Hilos totales:      %-29d │${NC}\n" "$TOTAL_HILOS"
printf "${CYAN}│ Preset VVC:         %-29s │${NC}\n" "$PRESET_VVC"
printf "${CYAN}│ Duración segmento:  %-29d │${NC}\n" "$DURACION_SEGMENTO"
printf "${CYAN}└────────────────────────────────────────────────────┘${NC}\n"

# Detectar HWACCEL
HWACCEL_METHOD=$(detectar_hwaccel)

# Calcular información del video
DURACION_VIDEO=$(obtener_duracion "$VIDEO_ORIGINAL")
SEGMENTOS_ESTIMADOS=$(( (DURACION_VIDEO + DURACION_SEGMENTO - 1) / DURACION_SEGMENTO ))

printf "\n${PURPLE}📊 INFORMACIÓN DEL VIDEO:${NC}\n"
printf "   Duración: %s\n" "$(formatear_tiempo $DURACION_VIDEO)"
printf "   Segmentos estimados: %d\n" "$SEGMENTOS_ESTIMADOS"

# ADVERTENCIA Y CONFIRMACIÓN
printf "\n${YELLOW}⚠️  ADVERTENCIA - ANÁLISIS DE TIEMPO:${NC}\n"

# Estimación PESIMISTA (basada en tu experiencia)
local tiempo_pesimista_segundo=$((TIMEOUT_POR_SEGMENTO * 60 / 100))  # Asume 60% del timeout
local tiempo_total_pesimista=$((SEGMENTOS_ESTIMADOS * tiempo_pesimista_segundo / SEGMENTOS_PARALELOS))

# Estimación OPTIMISTA (con optimización)
local tiempo_optimista_segundo=$((TIMEOUT_POR_SEGMENTO * 20 / 100))  # Asume 20% del timeout
local tiempo_total_optimista=$((SEGMENTOS_ESTIMADOS * tiempo_optimista_segundo / SEGMENTOS_PARALELOS))

printf "   ${YELLOW}Estimación pesimista: %s (%d días)${NC}\n" \
       "$(formatear_tiempo $tiempo_total_pesimista)" \
       $((tiempo_total_pesimista / 86400))
       
printf "   ${GREEN}Estimación optimista: %s (%d días)${NC}\n" \
       "$(formatear_tiempo $tiempo_total_optimista)" \
       $((tiempo_total_optimista / 86400))

printf "\n${BOLD}¿Continuar con la conversión optimizada? (s/n):${NC} "
read -r respuesta
[ "$respuesta" != "s" ] && { log_info "Proceso cancelado"; exit 0; }

# Crear segmentos si no existen
if [ ! -f "parte_001.mp4" ]; then
    log_info "🎬 Creando segmentos..."
    cmd="ffmpeg"
    [ -n "$HWACCEL_METHOD" ] && cmd="$cmd -hwaccel $HWACCEL_METHOD"
    cmd="$cmd -i \"$VIDEO_ORIGINAL\" -c copy -f segment -segment_time $DURACION_SEGMENTO -reset_timestamps 1 \"parte_%03d.mp4\""
    eval "$cmd" || { log_error "Error creando segmentos"; exit 1; }
fi

# Listar segmentos
segmentos=($(ls -1v parte_*.mp4 2>/dev/null))
[ ${#segmentos[@]} -eq 0 ] && { log_error "No hay segmentos"; exit 1; }

log_success "📁 Segmentos listos: ${#segmentos[@]}"

# Inicializar arrays
completados=()
fallados=()
declare -A estadisticas=(
    [exitosos_sin_procesar]=0
    [exitosos]=0
    [fallados]=0
)

# CONVERSIÓN PARALELA OPTIMIZADA
log_info "⚡ Iniciando conversión optimizada..."
inicio_global=$(date +%s)

gestionar_procesos_paralelos segmentos $SEGMENTOS_PARALELOS $HILOS_POR_PROCESO "$AFFINITY" completados fallados estadisticas

fin_global=$(date +%s)
tiempo_total=$((fin_global - inicio_global))

# RESULTADOS
printf "\n${GREEN}╔══════════════════════════════════════════════════╗${NC}\n"
printf "${GREEN}║            RESULTADOS FINALES                   ║${NC}\n"
printf "${GREEN}╠══════════════════════════════════════════════════╣${NC}\n"
printf "${GREEN}║ Segmentos totales:    %-26d ║${NC}\n" "${#segmentos[@]}"
printf "${GREEN}║ Convertidos exitosos: %-26d ║${NC}\n" "${#completados[@]}"
printf "${GREEN}║ Fallados:             %-26d ║${NC}\n" "${#fallados[@]}"
printf "${GREEN}║ Tiempo total:         %-26s ║${NC}\n" "$(formatear_tiempo $tiempo_total)"
printf "${GREEN}╚══════════════════════════════════════════════════╝${NC}\n"

# Rendimiento
if [ $tiempo_total -gt 0 ]; then
    local seg_por_hora=$(echo "scale=2; ${#segmentos[@]} * 3600 / $tiempo_total" | bc)
    printf "\n${CYAN}📈 RENDIMIENTO: %.2f segmentos/hora${NC}\n" "$seg_por_hora"
fi

# Unir si hay resultados
if [ ${#completados[@]} -gt 0 ]; then
    log_info "🔗 Uniendo segmentos..."
    
    # Crear lista ordenada
    printf "%s\n" "${completados[@]}" | sort -V | while read -r archivo; do
        printf "file '%s'\n" "$archivo"
    done > lista_final.txt
    
    # Concatenar
    if ffmpeg -f concat -safe 0 -i lista_final.txt -c copy -y "$SALIDA_FINAL" 2>/dev/null; then
        local tamano_mb=$(( $(stat -c%s "$SALIDA_FINAL" 2>/dev/null || echo 0) / 1048576 ))
        
        printf "\n${GREEN}🎉 CONVERSIÓN COMPLETADA EXITOSAMENTE${NC}\n"
        printf "${GREEN}   Archivo: %s${NC}\n" "$SALIDA_FINAL"
        printf "${GREEN}   Tamaño: %d MB${NC}\n" "$tamano_mb"
        
        # Limpieza
        printf "\n¿Limpiar archivos temporales? (s/n): "
        read -r respuesta
        [ "$respuesta" = "s" ] && rm -f parte_*.mp4 *_vvc.mp4 *_log.txt lista*.txt 2>/dev/null
    else
        log_error "Error al unir segmentos"
    fi
fi

log_info "✅ Proceso finalizado"