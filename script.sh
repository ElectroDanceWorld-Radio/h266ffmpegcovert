#!/bin/bash

# ====================================================
# SCRIPT H.266 - DIAGNÓSTICO FINAL
# ====================================================

# CONFIGURACIÓN
VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 h266_Final.mp4"

# =================================================================
# FUNCIONES
# =================================================================

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

log_info() {
    log "INFO: $1"
}

log_success() {
    log "SUCCESS: $1"
}

log_error() {
    log "ERROR: $1" >&2
}

# FUNCIÓN: Analizar video original
analizar_video() {
    log_info "Analizando video original..."
    
    echo "=== INFORMACIÓN DEL VIDEO ==="
    ffprobe -v error \
        -show_entries stream=codec_name,codec_type,width,height,pix_fmt,sample_rate,channels \
        -show_entries format=format_name,duration,size \
        -of default=noprint_wrappers=1 "$VIDEO_ORIGINAL" 2>/dev/null
    
    echo ""
    echo "=== ESTADÍSTICAS ==="
    ffprobe -v error \
        -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1 "$VIDEO_ORIGINAL" 2>/dev/null
}

# FUNCIÓN: Probar conversión con parámetros específicos
probar_conversion() {
    local entrada="$1"
    local salida="$2"
    local params="$3"
    
    echo "--- Probando: $params ---"
    
    local cmd="ffmpeg -i \"$entrada\" -c:v libvvenc $params -c:a copy -y \"$salida\" 2>&1"
    local output
    output=$(eval "$cmd")
    
    if echo "$output" | grep -q "frame="; then
        echo "✅ ÉXITO"
        if [ -f "$salida" ]; then
            local size
            size=$(stat -c%s "$salida" 2>/dev/null || echo 0)
            echo "   Tamaño: $((size/1024)) KB"
            
            # Verificar codec
            local codec
            codec=$(ffprobe -v error -show_entries stream=codec_name \
                -of default=noprint_wrappers=1 "$salida" 2>/dev/null)
            echo "   Codec: $codec"
            
            return 0
        fi
    else
        echo "❌ FALLO"
        # Mostrar error específico
        echo "$output" | grep -i "error\|invalid\|unsupported\|unknown" | head -3
        return 1
    fi
}

# =================================================================
# PROGRAMA PRINCIPAL
# =================================================================

clear
echo "========================================"
echo "DIAGNÓSTICO FINAL H.266"
echo "========================================"

# 1. ANALIZAR VIDEO ORIGINAL
analizar_video

# 2. CREAR UN SEGMENTO DE PRUEBA
echo ""
echo "=== CREANDO SEGMENTO DE PRUEBA ==="

if [ ! -f "parte_000.mp4" ]; then
    log_info "Creando segmento de prueba..."
    ffmpeg -i "$VIDEO_ORIGINAL" -t 10 -c copy prueba_segmento.mp4 2>/dev/null
    SEGMENTO_PRUEBA="prueba_segmento.mp4"
else
    SEGMENTO_PRUEBA="parte_000.mp4"
    log_info "Usando segmento existente: $SEGMENTO_PRUEBA"
fi

# 3. PROBAR DIFERENTES PARÁMETROS
echo ""
echo "=== PROBANDO PARÁMETROS VVC ==="

# Lista de parámetros a probar (CORREGIDA - sin 'local' en bucle)
pruebas_params=(
    "-preset 2 -qp 32"
    "-preset 1 -qp 28" 
    "-preset 0 -qp 32"
    "-qp 32"
    "-vvenc-params \"preset=2:qp=32\""
    ""  # Sin parámetros
)

params_exitosos=""
prueba_num=1

for params in "${pruebas_params[@]}"; do
    echo ""
    echo "PRUEBA $prueba_num: $params"
    
    if probar_conversion "$SEGMENTO_PRUEBA" "prueba_${prueba_num}.mp4" "$params"; then
        params_exitosos="$params"
        break
    fi
    
    prueba_num=$((prueba_num + 1))
    rm -f "prueba_${prueba_num}.mp4" 2>/dev/null
done

# 4. RESULTADO
echo ""
echo "=== RESULTADO ==="

if [ -n "$params_exitosos" ]; then
    echo "🎉 PARÁMETROS FUNCIONALES ENCONTRADOS: $params_exitosos"
    
    # 5. PREGUNTAR POR CONVERSIÓN COMPLETA
    echo ""
    read -p "¿Continuar con conversión COMPLETA? (s/n): " respuesta
    
    if [ "$respuesta" = "s" ]; then
        # 6. CONVERSIÓN COMPLETA
        echo ""
        echo "=== CONVERSIÓN COMPLETA ==="
        
        # Crear todos los segmentos si no existen
        if [ ! -f "parte_001.mp4" ]; then
            log_info "Creando todos los segmentos..."
            ffmpeg -i "$VIDEO_ORIGINAL" -c copy -f segment -segment_time 30 -reset_timestamps 1 "parte_%03d.mp4" 2>/dev/null
        fi
        
        segmentos=($(ls -1v parte_*.mp4 2>/dev/null))
        total=${#segmentos[@]}
        
        echo "Segmentos a procesar: $total"
        echo "Parámetros: $params_exitosos"
        echo ""
        
        inicio=$(date +%s)
        exitos=0
        
        # Procesar segmentos (2 en paralelo para prueba)
        for i in "${!segmentos[@]}"; do
            segmento="${segmentos[$i]}"
            nombre=$(basename "$segmento" .mp4)
            salida="${nombre}_vvc.mp4"
            
            echo -n "  $nombre: "
            
            # Saltar si ya existe
            if [ -f "$salida" ]; then
                echo "⏭️ ya existe"
                ((exitos++))
                continue
            fi
            
            # Convertir
            if ffmpeg -i "$segmento" -c:v libvvenc $params_exitosos -c:a copy -y "$salida" 2>/dev/null; then
                if [ -f "$salida" ] && [ -s "$salida" ]; then
                    echo "✅"
                    ((exitos++))
                else
                    echo "❌ (vacío)"
                fi
            else
                echo "❌"
            fi
            
            # Mostrar progreso cada 5 segmentos
            if [ $((i % 5)) -eq 0 ]; then
                procesados=$((i + 1))
                porcentaje=$((procesados * 100 / total))
                echo -ne "\r[PROGRESO] $procesados/$total ($porcentaje%)"
            fi
        done
        
        echo ""
        
        # 7. UNIR SEGMENTOS
        if [ $exitos -gt 0 ]; then
            echo ""
            echo "Uniendo $exitos segmentos..."
            
            # Crear lista
            ls -1v *_vvc.mp4 2>/dev/null | while read archivo; do
                echo "file '$archivo'"
            done > lista_final.txt
            
            if ffmpeg -f concat -safe 0 -i lista_final.txt -c copy -y "$SALIDA_FINAL" 2>/dev/null; then
                echo ""
                echo "✅ VIDEO FINAL CREADO"
                echo "===================="
                
                # Información final
                local size_mb
                size_mb=$(( $(stat -c%s "$SALIDA_FINAL" 2>/dev/null || echo 0) / 1048576 ))
                echo "Archivo: $SALIDA_FINAL"
                echo "Tamaño: $size_mb MB"
                echo "Éxitos: $exitos/$total"
                
                # Verificar codec
                local final_codec
                final_codec=$(ffprobe -v error -show_entries stream=codec_name \
                    -of default=noprint_wrappers=1 "$SALIDA_FINAL" 2>/dev/null)
                echo "Codec final: $final_codec"
                
                # Limpieza
                echo ""
                read -p "¿Eliminar archivos temporales? (s/n): " limpiar
                if [ "$limpiar" = "s" ]; then
                    rm -f parte_*.mp4 *_vvc.mp4 lista*.txt prueba*.mp4 2>/dev/null
                    echo "Archivos temporales eliminados"
                fi
            else
                echo "❌ Error al unir segmentos"
            fi
        else
            echo "❌ No hay segmentos exitosos para unir"
        fi
        
        tiempo_total=$(( $(date +%s) - inicio ))
        echo "Tiempo total: $(date -d "@$tiempo_total" '+%H:%M:%S')"
    else
        echo "Conversión cancelada"
    fi
else
    echo "❌ NINGÚN PARÁMETRO FUNCIONÓ CON TU VIDEO"
    echo ""
    echo "=== SOLUCIÓN ALTERNATIVA ==="
    echo ""
    echo "1. CONVERTIR A FORMATO INTERMEDIO:"
    echo "   ffmpeg -i \"$SEGMENTO_PRUEBA\" -c:v libx264 -c:a aac video_intermedio.mp4"
    echo "   ffmpeg -i video_intermedio.mp4 -c:v libvvenc -c:a copy prueba_vvc.mp4"
    echo ""
    echo "2. USAR HEVC (H.265) - MÁS ESTABLE:"
    echo "   ffmpeg -i \"$VIDEO_ORIGINAL\" -c:v libx265 -crf 23 -preset slower -c:a copy \"${SALIDA_FINAL%.mp4}_hevc.mp4\""
    echo ""
    echo "3. PROBAR CON RE-ENCODING DE AUDIO:"
    echo "   ffmpeg -i \"$SEGMENTO_PRUEBA\" -c:v libvvenc -preset 2 -c:a aac -b:a 256k prueba_audio.mp4"
    
    # Probar conversión intermedia
    echo ""
    read -p "¿Probar con formato intermedio? (s/n): " respuesta
    if [ "$respuesta" = "s" ]; then
        echo ""
        echo "Probando con formato intermedio..."
        ffmpeg -i "$SEGMENTO_PRUEBA" -c:v libx264 -c:a aac intermedio.mp4 2>/dev/null
        if probar_conversion "intermedio.mp4" "prueba_intermedio_vvc.mp4" "-preset 2"; then
            echo "✅ FUNCIONA con formato intermedio"
            echo "Solución: Convertir primero a H.264, luego a VVC"
        else
            echo "❌ Tampoco funciona con intermedio"
        fi
        rm -f intermedio.mp4 prueba_intermedio_vvc.mp4 2>/dev/null
    fi
fi

# Limpiar
rm -f prueba*.mp4 2>/dev/null
echo ""
echo "Diagnóstico completado"