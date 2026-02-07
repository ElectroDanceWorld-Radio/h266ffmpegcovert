#!/bin/bash

# ====================================================
# SCRIPT H.266 OPTIMIZADO - VERSIÓN 100% FUNCIONAL
# ====================================================

# CONFIGURACIÓN PRINCIPAL
VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 h266_Final.mp4"

# TU CONFIGURACIÓN
DURACION_SEGMENTO=30
PRESET_VVC="slower"
TIMEOUT_POR_SEGMENTO=$((2 * 60 * 60))

# CONFIGURACIÓN DE CODIFICACIÓN
ENCODER_VVC="libvvenc"
BITRATE_VIDEO="16M"
ENCODER_AUDIO="libopus"
BITRATE_AUDIO="256k"

# =================================================================
# FUNCIONES BÁSICAS (SIN COLORES PROBLEMÁTICOS)
# =================================================================

# Funciones de log SIMPLIFICADAS (sin colores por ahora)
log() {
    echo "[LOG] $1"
}

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1"
}

# FUNCIÓN: Detectar y optimizar CPU
detectar_y_optimizar_cpu() {
    local cores threads
    
    # Detectar núcleos e hilos de forma robusta
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "8")
    threads=$(nproc 2>/dev/null || echo "16")
    
    # Configuración basada en hilos
    local segmentos_paralelos hilos_por_proceso
    
    if [ "$threads" -ge 32 ]; then
        segmentos_paralelos=6
        hilos_por_proceso=5
    elif [ "$threads" -ge 24 ]; then
        segmentos_paralelos=4
        hilos_por_proceso=6
    elif [ "$threads" -ge 16 ]; then
        segmentos_paralelos=3
        hilos_por_proceso=5
    elif [ "$threads" -ge 8 ]; then
        segmentos_paralelos=2
        hilos_por_proceso=4
    else
        segmentos_paralelos=1
        hilos_por_proceso=$threads
    fi
    
    echo "${segmentos_paralelos}:${hilos_por_proceso}:${threads}:${cores}"
}

# FUNCIÓN: Formatear tiempo (CORREGIDA)
formatear_tiempo() {
    local segundos=$1
    # Asegurarse de que es un número entero
    segundos=${segundos%.*}
    
    local horas=$((segundos / 3600))
    local minutos=$(((segundos % 3600) / 60))
    local segs=$((segundos % 60))
    
    printf "%02d:%02d:%02d" "$horas" "$minutos" "$segs"
}

# FUNCIÓN: Verificar archivo
verificar_archivo() {
    if [ ! -f "$1" ]; then
        log_error "Archivo no encontrado: $1"
        log_info "Directorio actual: $(pwd)"
        return 1
    fi
    return 0
}

# FUNCIÓN: Obtener duración del video (CORREGIDA)
obtener_duracion() {
    # Usar un método más robusto
    local duracion
    duracion=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null)
    
    if [ -n "$duracion" ]; then
        # Convertir a entero
        printf "%.0f" "$duracion"
    else
        echo "0"
    fi
}

# FUNCIÓN: Crear segmentos (VERSIÓN SIMPLE Y FUNCIONAL)
crear_segmentos() {
    log_info "Creando segmentos de $DURACION_SEGMENTO segundos..."
    
    # Verificar si ya existen segmentos
    if ls parte_*.mp4 1>/dev/null 2>&1; then
        log_info "Segmentos ya existen, saltando creación"
        return 0
    fi
    
    # COMANDO SIMPLE Y FUNCIONAL
    # NOTA: No usar HWACCEL para la división, puede causar problemas
    
    log_info "Ejecutando ffmpeg para dividir el video..."
    
    # Comando básico que SIEMPRE funciona
    if ffmpeg -i "$VIDEO_ORIGINAL" \
              -c copy \
              -f segment \
              -segment_time "$DURACION_SEGMENTO" \
              -reset_timestamps 1 \
              -segment_start_number 1 \
              "parte_%03d.mp4" 2>/tmp/ffmpeg_split.log; then
        
        # Contar segmentos creados
        local count
        count=$(ls -1 parte_*.mp4 2>/dev/null | wc -l)
        
        if [ "$count" -gt 0 ]; then
            log_success "Creados $count segmentos correctamente"
            return 0
        else
            log_error "No se crearon archivos de segmentos"
            log_info "Log de ffmpeg:"
            cat /tmp/ffmpeg_split.log
            return 1
        fi
    else
        log_error "Error al ejecutar ffmpeg"
        log_info "Log de error:"
        cat /tmp/ffmpeg_split.log
        return 1
    fi
}

# FUNCIÓN: Detectar HWACCEL para conversión
detectar_hwaccel() {
    log_info "Probando aceleración por hardware..."
    
    # Primero probar CUDA
    if ffmpeg -hwaccel cuda -f lavfi -i "nullsrc=size=640x360" -frames:v 1 -f null - 2>/dev/null; then
        log_success "CUDA disponible"
        echo "cuda"
        return 0
    fi
    
    # Luego VAAPI
    if ffmpeg -hwaccel vaapi -f lavfi -i "nullsrc=size=640x360" -frames:v 1 -f null - 2>/dev/null; then
        log_success "VAAPI disponible"
        echo "vaapi"
        return 0
    fi
    
    log_info "Usando software (sin HWACCEL)"
    echo ""
    return 0
}

# FUNCIÓN: Convertir un segmento
convertir_segmento() {
    local entrada="$1"
    local salida="$2"
    local hilos="$3"
    
    local nombre_base
    nombre_base=$(basename "$entrada" .mp4)
    
    log_info "Convirtiendo: $nombre_base con $hilos hilos"
    
    # Construir comando
    local cmd="timeout $TIMEOUT_POR_SEGMENTO ffmpeg"
    
    # Añadir HWACCEL si está configurado
    if [ -n "$HWACCEL_METHOD" ] && [ "$HWACCEL_METHOD" != "" ]; then
        cmd="$cmd -hwaccel $HWACCEL_METHOD"
    fi
    
    cmd="$cmd -i \"$entrada\""
    cmd="$cmd -c:v $ENCODER_VVC"
    cmd="$cmd -preset $PRESET_VVC"
    cmd="$cmd -b:v $BITRATE_VIDEO"
    cmd="$cmd -c:a $ENCODER_AUDIO"
    cmd="$cmd -b:a $BITRATE_AUDIO"
    cmd="$cmd -threads $hilos"
    cmd="$cmd -y"
    cmd="$cmd \"$salida\""
    
    # Ejecutar y capturar salida
    local log_file="${nombre_base}_convert.log"
    
    if eval "$cmd" 2>"$log_file"; then
        # Verificar archivo de salida
        if [ -f "$salida" ] && [ -s "$salida" ]; then
            local tamano
            tamano=$(stat -c%s "$salida" 2>/dev/null || echo 0)
            log_success "✓ $nombre_base: $(($tamano/1024/1024)) MB"
            rm -f "$log_file" 2>/dev/null
            return 0
        else
            log_error "✗ $nombre_base: archivo vacío o no creado"
            return 1
        fi
    else
        log_error "✗ $nombre_base: error en conversión"
        # Mostrar error breve
        if [ -f "$log_file" ]; then
            log_info "Error (últimas líneas):"
            tail -3 "$log_file"
        fi
        return 1
    fi
}

# FUNCIÓN: Procesar en paralelo
procesar_paralelo() {
    local segmentos=("${!1}")
    local segmentos_paralelos=$2
    local hilos_por_proceso=$3
    
    local total=${#segmentos[@]}
    local index=0
    local -a pids
    local -a nombres
    
    log_info "Procesando $total segmentos en paralelo ($segmentos_paralelos a la vez)"
    
    # Iniciar primeros procesos
    while [ ${#pids[@]} -lt "$segmentos_paralelos" ] && [ "$index" -lt "$total" ]; do
        local segmento="${segmentos[$index]}"
        local nombre_base
        nombre_base=$(basename "$segmento" .mp4)
        local salida="${nombre_base}_vvc.mp4"
        
        # Saltar si ya existe
        if [ -f "$salida" ] && [ -s "$salida" ]; then
            log_info "⏭️ $nombre_base ya existe"
            ((index++))
            continue
        fi
        
        # Iniciar conversión
        convertir_segmento "$segmento" "$salida" "$hilos_por_proceso" &
        local pid=$!
        
        pids+=("$pid")
        nombres+=("$nombre_base")
        
        log_info "▶️ Iniciado $nombre_base (PID: $pid)"
        ((index++))
        
        # Pequeña pausa
        sleep 0.5
    done
    
    # Monitorear y gestionar procesos
    while [ ${#pids[@]} -gt 0 ]; do
        local nuevos_pids=()
        local nuevos_nombres=()
        
        for i in "${!pids[@]}"; do
            local pid=${pids[$i]}
            local nombre=${nombres[$i]}
            
            if kill -0 "$pid" 2>/dev/null; then
                # Proceso aún activo
                nuevos_pids+=("$pid")
                nuevos_nombres+=("$nombre")
            else
                # Proceso terminado
                wait "$pid" 2>/dev/null
                # No hacemos nada más, los logs ya mostraron el resultado
            fi
        done
        
        pids=("${nuevos_pids[@]}")
        nombres=("${nuevos_nombres[@]}")
        
        # Iniciar nuevos procesos si hay capacidad
        while [ ${#pids[@]} -lt "$segmentos_paralelos" ] && [ "$index" -lt "$total" ]; do
            local segmento="${segmentos[$index]}"
            local nombre_base
            nombre_base=$(basename "$segmento" .mp4)
            local salida="${nombre_base}_vvc.mp4"
            
            if [ -f "$salida" ] && [ -s "$salida" ]; then
                log_info "⏭️ $nombre_base ya existe"
                ((index++))
                continue
            fi
            
            convertir_segmento "$segmento" "$salida" "$hilos_por_proceso" &
            local pid=$!
            
            pids+=("$pid")
            nombres+=("$nombre_base")
            
            log_info "▶️ Iniciado $nombre_base (PID: $pid)"
            ((index++))
            
            sleep 0.5
        done
        
        # Mostrar progreso
        local procesados=$index
        local porcentaje=$((procesados * 100 / total))
        local activos=${#pids[@]}
        
        echo -ne "\r[PROGRESO] $procesados/$total ($porcentaje%) | Activos: $activos"
        
        # Pequeña pausa
        sleep 2
    done
    
    echo ""  # Nueva línea después de la barra de progreso
}

# =================================================================
# PROGRAMA PRINCIPAL
# =================================================================

clear
echo "========================================"
echo "H.266 OPTIMIZADO - VERSIÓN ESTABLE"
echo "========================================"

# 1. Verificar archivo
if ! verificar_archivo "$VIDEO_ORIGINAL"; then
    exit 1
fi

# 2. Detectar y optimizar CPU
log_info "Analizando sistema..."
cpu_config=$(detectar_y_optimizar_cpu)

SEGMENTOS_PARALELOS=$(echo "$cpu_config" | cut -d: -f1)
HILOS_POR_PROCESO=$(echo "$cpu_config" | cut -d: -f2)
TOTAL_HILOS=$(echo "$cpu_config" | cut -d: -f3)
TOTAL_NUCLEOS=$(echo "$cpu_config" | cut -d: -f4)

echo ""
echo "CONFIGURACIÓN DETECTADA:"
echo "  Núcleos/Hilos: $TOTAL_NUCLEOS/$TOTAL_HILOS"
echo "  Procesos paralelos: $SEGMENTOS_PARALELOS"
echo "  Hilos por proceso: $HILOS_POR_PROCESO"
echo "  Preset VVC: $PRESET_VVC"
echo "  Duración segmento: $DURACION_SEGMENTO segundos"
echo ""

# 3. Detectar HWACCEL
HWACCEL_METHOD=$(detectar_hwaccel)
echo "Método HWACCEL: ${HWACCEL_METHOD:-software}"
echo ""

# 4. Obtener información del video
log_info "Analizando video..."
DURACION_VIDEO=$(obtener_duracion "$VIDEO_ORIGINAL")
SEGMENTOS_ESTIMADOS=$(( (DURACION_VIDEO + DURACION_SEGMENTO - 1) / DURACION_SEGMENTO ))

echo "INFORMACIÓN DEL VIDEO:"
echo "  Duración: $(formatear_tiempo $DURACION_VIDEO)"
echo "  Segmentos estimados: $SEGMENTOS_ESTIMADOS"
echo ""

# 5. Estimación de tiempo
echo "ESTIMACIÓN DE TIEMPO:"
# Tiempo por segmento estimado (más realista para 'slower')
TIEMPO_POR_SEGMENTO=1800  # 30 minutos
TIEMPO_TOTAL=$((SEGMENTOS_ESTIMADOS * TIEMPO_POR_SEGMENTO / SEGMENTOS_PARALELOS))

echo "  Tiempo estimado: $(formatear_tiempo $TIEMPO_TOTAL)"
echo "  Esto es aproximadamente $((TIEMPO_TOTAL / 3600)) horas"
echo ""

# 6. Confirmación
read -p "¿Continuar con la conversión? (s/n): " respuesta
if [ "$respuesta" != "s" ]; then
    log_info "Proceso cancelado"
    exit 0
fi

# 7. Crear segmentos
if ! crear_segmentos; then
    log_error "No se pudieron crear segmentos"
    exit 1
fi

# 8. Listar segmentos (PRIMERO SOLO 3 PARA PRUEBA)
log_info "Modo prueba: procesando solo 3 segmentos primero"
segmentos_prueba=($(ls -1v parte_*.mp4 2>/dev/null | head -3))

if [ ${#segmentos_prueba[@]} -eq 0 ]; then
    log_error "No hay segmentos para procesar"
    exit 1
fi

echo ""
echo "PRUEBA INICIAL (3 segmentos):"
echo "============================="

# 9. Procesar prueba
inicio_prueba=$(date +%s)
procesar_paralelo segmentos_prueba "$SEGMENTOS_PARALELOS" "$HILOS_POR_PROCESO"
fin_prueba=$(date +%s)
tiempo_prueba=$((fin_prueba - inicio_prueba))

echo ""
echo "Resultado prueba:"
echo "  Tiempo: $(formatear_tiempo $tiempo_prueba)"
echo "  Segmentos procesados: ${#segmentos_prueba[@]}"

# 10. Preguntar por continuación
echo ""
read -p "¿La prueba fue exitosa? ¿Continuar con TODOS los segmentos? (s/n): " respuesta

if [ "$respuesta" = "s" ]; then
    # 11. Procesar TODOS los segmentos
    log_info "Procesando todos los segmentos..."
    
    todos_segmentos=($(ls -1v parte_*.mp4 2>/dev/null))
    
    if [ ${#todos_segmentos[@]} -eq 0 ]; then
        log_error "No hay segmentos para procesar"
        exit 1
    fi
    
    echo ""
    echo "CONVERSIÓN COMPLETA:"
    echo "==================="
    echo "Total segmentos: ${#todos_segmentos[@]}"
    
    inicio_completo=$(date +%s)
    procesar_paralelo todos_segmentos "$SEGMENTOS_PARALELOS" "$HILOS_POR_PROCESO"
    fin_completo=$(date +%s)
    tiempo_completo=$((fin_completo - inicio_completo))
    
    echo ""
    echo "RESULTADO FINAL:"
    echo "  Tiempo total: $(formatear_tiempo $tiempo_completo)"
    echo "  Segmentos procesados: ${#todos_segmentos[@]}"
    
    # 12. Contar segmentos convertidos exitosamente
    segmentos_exitosos=($(ls -1v *_vvc.mp4 2>/dev/null))
    
    if [ ${#segmentos_exitosos[@]} -gt 0 ]; then
        echo ""
        log_info "Uniendo segmentos..."
        
        # Crear lista
        for archivo in "${segmentos_exitosos[@]}"; do
            echo "file '$archivo'"
        done > lista_final.txt
        
        # Concatenar
        if ffmpeg -f concat -safe 0 -i lista_final.txt -c copy -y "$SALIDA_FINAL" 2>/dev/null; then
            local tamano_mb
            tamano_mb=$(( $(stat -c%s "$SALIDA_FINAL" 2>/dev/null || echo 0) / 1048576 ))
            log_success "✅ Video final creado: $SALIDA_FINAL"
            log_success "   Tamaño: $tamano_mb MB"
            
            # Preguntar por limpieza
            echo ""
            read -p "¿Eliminar archivos temporales? (s/n): " respuesta
            if [ "$respuesta" = "s" ]; then
                rm -f parte_*.mp4 *_vvc.mp4 *.log lista*.txt 2>/dev/null
                log_info "Archivos temporales eliminados"
            fi
        else
            log_error "Error al unir segmentos"
        fi
    else
        log_error "No hay segmentos convertidos exitosamente"
    fi
else
    log_info "Conversión completa cancelada por el usuario"
fi

echo ""
log_info "Proceso finalizado"