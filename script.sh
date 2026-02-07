#!/bin/bash
# CONVERSIÓN HEVC (H.265) - GARANTIZADO FUNCIONA

VIDEO_ORIGINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4"
SALIDA_FINAL="/home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 hevc_Final.mp4"

echo "=== CONVERSIÓN HEVC (H.265) ==="
echo "Video: $VIDEO_ORIGINAL"
echo ""

# Configuración calidad máxima
PRESET="slower"      # slower, slow, medium, fast, faster
CRF=18               # 0-51, menor = mejor calidad (18-23 es excelente)

echo "Configuración:"
echo "  Preset: $PRESET (máxima compresión)"
echo "  CRF: $CRF (calidad excelente)"
echo ""

# Conversión DIRECTA (sin segmentos)
echo "Convirtiendo..."
inicio=$(date +%s)

ffmpeg -i "$VIDEO_ORIGINAL" \
       -c:v libx265 \
       -preset "$PRESET" \
       -crf "$CRF" \
       -tag:v hvc1 \
       -c:a copy \
       -y "$SALIDA_FINAL"

if [ $? -eq 0 ]; then
    fin=$(date +%s)
    tiempo=$((fin - inicio))
    
    echo ""
    echo "✅ CONVERSIÓN COMPLETADA"
    echo "========================"
    echo "Archivo: $SALIDA_FINAL"
    echo "Tamaño: $(($(stat -c%s "$SALIDA_FINAL" 2>/dev/null || echo 0) / 1048576)) MB"
    echo "Tiempo: $(date -d "@$tiempo" '+%H:%M:%S')"
    
    # Verificar
    echo ""
    echo "Verificación:"
    ffprobe -v error -show_entries stream=codec_name,width,height \
            -of default=noprint_wrappers=1 "$SALIDA_FINAL"
else
    echo "❌ Error en la conversión"
fi