<#
.SYNOPSIS
    Script de compresión H.266 VVC - Máxima eficiencia (PowerShell)
.DESCRIPTION
    Este script convierte un video de entrada a H.266/VVC utilizando FFmpeg con libvvenc.
    Segmenta el video, procesa cada segmento y los une al final.
.PARAMETER VideoInput
    Ruta del archivo de entrada. Por defecto: /home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD.mp4
.PARAMETER VideoOutput
    Ruta del archivo de salida. Por defecto: /home/carlos/Descargas/Conversion ffmpeg/Noturnity Sesions Special 2 Audio HD266.mp4
.PARAMETER Preset
    Preset de compresión (fastest, fast, medium, slow, slower, slowest). Por defecto: slower
.PARAMETER SegmentDuration
    Duración en segundos de cada segmento. Por defecto: 30
.EXAMPLE
    .\compress-vvc.ps1
    .\compress-vvc.ps1 -VideoInput "video.mp4" -VideoOutput "salida.mp4" -Preset fast -SegmentDuration 60
#>

param(
    [string]$VideoInput = "C:\Users\Carlos\Videos\Convertir\VID_20251114_190822.mp4",
    [string]$VideoOutput = "C:\Users\Carlos\Videos\Convertir\VID_20251114_190822_h266.mp4",
    [string]$Preset = "slower",
    [int]$SegmentDuration = 30
)

# ====================================================
# CONFIGURACIÓN VVC AVANZADA
# ====================================================
$VVC_PRESET = "slower"
$INTERNAL_BITDEPTH = "10"
$QP = "32"
$THREADS = "-1"
$INTRA_PERIOD = "2"
$QPA = "on"
$TILES = "2x2"
$IFP = "auto"
$MT_PROFILE = "auto"

# CONFIGURACIÓN MULTIHILO (en PowerShell se usará secuencial, pero se puede ajustar)
$PARALLEL_JOBS = 4
$WPP = "on"

# CONFIGURACIÓN DE RECUPERACIÓN
$MAX_RETRIES = 2
$BACKUP_EVERY = 5

# CONFIGURACIÓN AUDIO
$AUDIO_ENCODER = "libopus"
$AUDIO_BITRATE = "256k"
$AUDIO_CHANNELS = "2"

# =================================================================
# FUNCIONES PRINCIPALES
# =================================================================

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Log "INFO: $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Log "SUCCESS: $Message"
}

function Write-Warning {
    param([string]$Message)
    Microsoft.PowerShell.Utility\Write-Warning "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: $Message"
}

function Write-WarningLog {
    param([string]$Message)
    Write-Warning "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: $Message"
}

function Get-HardwareAcceleration {
    Write-Info "Detectando aceleración por hardware..."
    $hwAccels = @("cuda", "vaapi", "dxva2", "d3d11va")
    
    # Probar sin aceleración
    Write-Info "Probando sin aceleración..."
    $cmd = "ffmpeg -loglevel quiet -i `"$VideoInput`" -t 1 -f null -"
    $result = Invoke-Expression "timeout 5 $cmd 2>&1" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Software funcionando"
        return ""
    }
    
    # Probar cada acelerador
    foreach ($accel in $hwAccels) {
        Write-Info "Probando $accel..."
        $cmd = "timeout 5 ffmpeg -hwaccel $accel -loglevel quiet -i `"$VideoInput`" -t 1 -f null -"
        $result = Invoke-Expression "$cmd 2>&1" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Aceleración $accel disponible"
            return $accel
        }
    }
    
    Write-Warning "Usando software (fallback)"
    return ""
}

function Test-VvcSupport {
    Write-Info "Verificando compatibilidad VVC en FFmpeg..."
    $vvcEncoder = ffmpeg -encoders 2>$null | Select-String "libvvenc"
    if (-not $vvcEncoder) {
        Write-ErrorLog "FFmpeg no tiene soporte para libvvenc (VVC)."
        Write-ErrorLog "Debes compilar FFmpeg con --enable-libvvenc o usar una versión que lo incluya."
        return $false
    }
    Write-Success "Encoder libvvenc encontrado en FFmpeg"
    return $true
}

function Get-VideoInfo {
    param([string]$VideoPath)
    Write-Info "Analizando: $(Split-Path $VideoPath -Leaf)"
    
    Write-Host "========================================"
    Write-Host "INFORMACIÓN DEL VIDEO"
    Write-Host "========================================"
    
    ffprobe -v error `
        -show_entries stream=codec_name,codec_type,width,height,pix_fmt,bit_rate,r_frame_rate `
        -show_entries format=duration,size,bit_rate `
        -of default=noprint_wrappers=1 "$VideoPath" 2>$null
}

function New-Segments {
    param(
        [string]$InputFile,
        [int]$Duration
    )
    Write-Info "Creando segmentos de ${Duration}s..."
    
    # Verificar solo segmentos originales (patrón segment_XXX.mp4)
    $originalSegments = Get-ChildItem "segment_*.mp4" -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^segment_\d{3}\.mp4$'
    }
    if ($originalSegments.Count -gt 0) {
        Write-Info "Segmentos originales ya existen ($($originalSegments.Count) encontrados), saltando creación"
        return $true
    }
    
    # Método 1: Simple sin redirección de logs
    Write-Info "Intentando método simple..."
    
    ffmpeg -loglevel quiet -i "$InputFile" `
        -c copy `
        -f segment `
        -segment_time "$Duration" `
        -segment_format mp4 `
        -reset_timestamps 1 `
        -segment_start_number 0 `
        "segment_%03d.mp4" 2>$null
    
    $originalSegments = Get-ChildItem "segment_*.mp4" -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^segment_\d{3}\.mp4$'
    }
    if ($originalSegments.Count -gt 0) {
        Write-Success "Creados $($originalSegments.Count) segmentos"
        return $true
    }
    
    # Método 2: Con redirección de errores a archivo
    Write-Info "Intentando con redirección de errores..."
    
    $tempLog = "ffmpeg_segment.log"
    try {
        ffmpeg -i "$InputFile" `
            -c copy `
            -f segment `
            -segment_time "$Duration" `
            -segment_format mp4 `
            -reset_timestamps 1 `
            -segment_start_number 0 `
            "segment_%03d.mp4" 2>$tempLog
    } catch {}
    
    $originalSegments = Get-ChildItem "segment_*.mp4" -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^segment_\d{3}\.mp4$'
    }
    if ($originalSegments.Count -gt 0) {
        Write-Success "Creados $($originalSegments.Count) segmentos"
        Remove-Item $tempLog -ErrorAction SilentlyContinue
        return $true
    }
    
    # Método 3: Crear segmentos uno por uno
    Write-Info "Creando segmentos manualmente..."
    
    $durationStr = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>$null
    $totalDuration = [math]::Floor([double]$durationStr)
    if ($totalDuration -le 0) {
        $totalDuration = 2166
    }
    
    $segmentCount = [math]::Ceiling($totalDuration / $Duration)
    Write-Info "Duración total: ${totalDuration}s, creando $segmentCount segmentos..."
    
    $createdCount = 0
    for ($i = 0; $i -lt $segmentCount; $i++) {
        $start = $i * $Duration
        $segmentName = "segment_{0:D3}.mp4" -f $i
        
        if ($i % 10 -eq 0) {
            Write-Info "Creando segmento $($i+1)/$segmentCount..."
        }
        
        ffmpeg -loglevel quiet -i "$InputFile" `
            -ss "$start" `
            -t "$Duration" `
            -c copy `
            -avoid_negative_ts make_zero `
            -y "$segmentName" 2>$null
        
        if ((Test-Path $segmentName) -and ((Get-Item $segmentName).Length -gt 0)) {
            $createdCount++
        } else {
            Remove-Item $segmentName -ErrorAction SilentlyContinue
        }
    }
    
    if ($createdCount -gt 0) {
        Write-Success "Creados $createdCount/$segmentCount segmentos"
        return $true
    } else {
        Write-ErrorLog "No se pudieron crear segmentos"
        return $false
    }
}

function Build-VvcCommand {
    param(
        [string]$InputFile,
        [string]$OutputFile
    )
    # En el script original, esta función construye el comando vvencapp, aunque luego no se usa.
    # Se mantiene para posible uso futuro.
    $params = @(
        "--input `"$InputFile`"",
        "--output `"$OutputFile`"",
        "--preset $VVC_PRESET",
        "--qp $QP",
        "--threads $THREADS",
        "--intraperiod $INTRA_PERIOD",
        "--qpa $QPA",
        "--internal-bitdepth $INTERNAL_BITDEPTH",
        "--mtprofile $MT_PROFILE",
        "--ifp $IFP",
        "--tiles $TILES",
        "--profile main_10",
        "--level auto",
        "--decodedpicturehash 1"
    )
    $additional = @(
        "RateControl=0",
        "SAO=1",
        "ALF=1",
        "Affine=1",
        "MCTF=1",
        "DepQuant=1",
        "CIIP=1",
        "GPM=1",
        "MRL=1",
        "MIP=on",
        "ISP=on",
        "TransformSkip=on",
        "JointCbCr=1"
    )
    $addStr = $additional -join ":"
    return "vvencapp $($params -join ' ') --additional `"$addStr`""
}

function Convert-SegmentFfmpeg {
    param(
        [string]$InputSegment,
        [string]$OutputSegment,
        [int]$Attempt
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputSegment)
    $logFile = "log_${base}_ffmpeg_attempt${Attempt}.txt"
    
    Write-Info "Usando FFmpeg para: $(Split-Path $InputSegment -Leaf)"
    
    $threadCount = $env:NUMBER_OF_PROCESSORS
    if (-not $threadCount) { $threadCount = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors }
    if (-not $threadCount) { $threadCount = 4 } # fallback
    
    $argList = @(
        "-i", "`"$InputSegment`"",
        "-c:v", "libvvenc",
        "-preset", $VVC_PRESET,
        "-qp", $QP,
        "-threads", $threadCount,
        "-c:a", $AUDIO_ENCODER,
        "-b:a", $AUDIO_BITRATE,
        "-ac", $AUDIO_CHANNELS,
        "-y", "`"$OutputSegment`""
    )
    $cmd = "ffmpeg $($argList -join ' ')"
    
    # Ejecutar y capturar salida en archivo de log
    Invoke-Expression "$cmd > `"$logFile`" 2>&1"
    
    if ($LASTEXITCODE -eq 0 -and (Test-Path $OutputSegment) -and ((Get-Item $OutputSegment).Length -gt 0)) {
        Write-Success "Convertido con FFmpeg"
        Remove-Item $logFile -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Invoke-ProcessSegment {
    param(
        [string]$Segment,
        [int]$SegmentNum,
        [int]$TotalSegments
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Segment)
    $output = "${base}_vvc.mp4"
    $statusFile = "${base}_status.txt"
    
    if ((Test-Path $output) -and ((Get-Item $output).Length -gt 0)) {
        # Verificar que el archivo sea válido con ffprobe
        ffprobe -v error $output 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Segmento ya procesado: $base"
            "success" | Out-File -FilePath $statusFile -Encoding ASCII
            return $true
        } else {
            Remove-Item $output -ErrorAction SilentlyContinue
        }
    }
    
    Write-Host "[$SegmentNum/$TotalSegments] Procesando $base..."
    
    for ($attempt = 1; $attempt -le $MAX_RETRIES; $attempt++) {
        if (Convert-SegmentFfmpeg -InputSegment $Segment -OutputSegment $output -Attempt $attempt) {
            "success" | Out-File -FilePath $statusFile -Encoding ASCII
            return $true
        }
        Remove-Item $output -ErrorAction SilentlyContinue
    }
    
    Write-ErrorLog "No se pudo convertir segmento: $base"
    "failed" | Out-File -FilePath $statusFile -Encoding ASCII
    return $false
}

function Invoke-ProcessAllSegments {
    # Solo los segmentos originales (formato segment_000.mp4, no _vvc.mp4)
    $segments = Get-ChildItem "segment_*.mp4" | Where-Object {
        $_.Name -match '^segment_\d{3}\.mp4$'
    } | Sort-Object Name
    
    $total = $segments.Count
    if ($total -eq 0) {
        Write-ErrorLog "No se encontraron segmentos originales para procesar"
        return $false
    }
    
    Write-Info "Procesando $total segmentos..."
    $processed = 0
    $failed = 0
    
    for ($i = 0; $i -lt $total; $i++) {
        $segment = $segments[$i].FullName
        $segmentNum = $i + 1
        
        $progress = [math]::Floor($segmentNum * 100 / $total)
        Write-Host -NoNewline "`rProgreso: $segmentNum/$total segmentos ($progress%)"
        
        if (Invoke-ProcessSegment -Segment $segment -SegmentNum $segmentNum -TotalSegments $total) {
            $processed++
        } else {
            $failed++
        }
        
        if ($segmentNum % $BACKUP_EVERY -eq 0) {
            Write-Host ""
            Write-Info "Checkpoint: $segmentNum/$total procesados"
        }
    }
    
    Write-Host ""
    Write-Info "Procesamiento completado"
    Write-Info "Exitos: $processed/$total"
    Write-Info "Fallos: $failed/$total"
    
    if ($processed -eq 0) {
        Write-ErrorLog "Ningún segmento se procesó exitosamente"
        return $false
    }
    return $true
}

function Merge-Segments {
    param([string]$OutputFile)
    Write-Info "Uniendo segmentos convertidos..."

    $segmentList = "segment_list.txt"
    # Aseguramos que el archivo esté vacío (ASCII, sin BOM)
    [System.IO.File]::WriteAllText($segmentList, "", [System.Text.Encoding]::ASCII)

    # Buscar solo los segmentos convertidos con formato segment_NNN_vvc.mp4
    $convertedSegments = Get-ChildItem "*_vvc.mp4" | Where-Object {
        $_.Name -match '^segment_\d{3}_vvc\.mp4$'
    } | Sort-Object Name

    $convertedCount = $convertedSegments.Count
    if ($convertedCount -eq 0) {
        Write-ErrorLog "No hay segmentos convertidos para unir"
        return $false
    }

    # Escribir la lista con rutas absolutas y saltos de línea Unix
    foreach ($seg in $convertedSegments) {
        $line = "file '$($seg.FullName -replace '\\','/')'"
        [System.IO.File]::AppendAllText($segmentList, $line + "`n", [System.Text.Encoding]::ASCII)
    }

    Write-Info "Uniendo $convertedCount segmentos..."

    # Ejecutar ffmpeg y capturar toda la salida (stdout + stderr)
    $ffmpegOutput = & ffmpeg -f concat -safe 0 -i $segmentList -c copy -y $OutputFile 2>&1
    $exitCode = $LASTEXITCODE

    # Mostrar solo líneas de progreso, pero guardar todo en un log por si hay error
    $ffmpegOutput | Select-String "frame=|time=|bitrate=|error|Error" | ForEach-Object { Write-Host $_ }

    # Verificar éxito
    if ($exitCode -eq 0 -and (Test-Path $OutputFile) -and ((Get-Item $OutputFile).Length -gt 0)) {
        Write-Success "Video unido exitosamente"
        return $true
    } else {
        # Mostrar las últimas 20 líneas de ffmpeg para diagnosticar
        Write-Host "Últimas líneas de FFmpeg (error):" -ForegroundColor Yellow
        $ffmpegOutput | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
        Write-ErrorLog "Error al unir segmentos (código de salida: $exitCode)"
        return $false
    }
}

function Clear-TempFiles {
    Write-Info "Limpiando archivos temporales..."
    Remove-Item "segment_*.mp4" -ErrorAction SilentlyContinue
    Remove-Item "*_vvc.mp4" -ErrorAction SilentlyContinue
    Remove-Item "segment_list.txt" -ErrorAction SilentlyContinue
    Remove-Item "status_*.txt" -ErrorAction SilentlyContinue
    Remove-Item "log_*.txt" -ErrorAction SilentlyContinue
    Write-Success "Limpieza completada"
}

function Test-DiskSpace {
    $requiredGB = 30
    $availableGB = 100
    try {
        $drive = (Get-Location).Drive.Name
        $freeBytes = (Get-PSDrive -Name $drive).Free
        $availableGB = [math]::Floor($freeBytes / 1GB)
    } catch {
        $availableGB = 100
    }
    
    if ($availableGB -lt $requiredGB) {
        Write-Warning "Espacio en disco bajo: ${availableGB}GB disponibles"
        Write-Warning "Se recomienda al menos ${requiredGB}GB"
        Write-Warning "Continuando de todos modos..."
    }
    return $true
}

function Main {
    Clear-Host
    Write-Host "========================================"
    Write-Host "COMPRESIÓN VVC - MÁXIMA EFICIENCIA"
    Write-Host "========================================"
    Write-Host "Entrada: $(Split-Path $VideoInput -Leaf)"
    Write-Host "Salida: $(Split-Path $VideoOutput -Leaf)"
    Write-Host "Preset: $Preset"
    Write-Host "Segmentos: ${SegmentDuration}s"
    Write-Host "Threads: automático (todos los cores)"
    Write-Host "Audio: $AUDIO_ENCODER @ $AUDIO_BITRATE"
    Write-Host "========================================"
    
    if (-not (Test-Path $VideoInput)) {
        Write-ErrorLog "Archivo de entrada no encontrado: $VideoInput"
        exit 1
    }
    
    if (-not (Test-VvcSupport)) {
        Write-ErrorLog "VVC no disponible"
        exit 1
    }
    
    Test-DiskSpace
    
    # Configurar según preset
    switch ($Preset) {
        "fastest" { $VVC_PRESET = "fast"; $THREADS = $env:NUMBER_OF_PROCESSORS }
        "fast"    { $VVC_PRESET = "fast"; $THREADS = $env:NUMBER_OF_PROCESSORS }
        "medium"  { $VVC_PRESET = "medium" }
        { $_ -in @("slow","slower","slowest") } {
            $VVC_PRESET = "slower"; $INTRA_PERIOD = "4"
        }
        default { $VVC_PRESET = $Preset }
    }
    
    $HW_ACCEL = Get-HardwareAcceleration
    Get-VideoInfo $VideoInput
    
    $WORK_DIR = "vvc_encode_tmp"
    New-Item -ItemType Directory -Force -Path $WORK_DIR | Out-Null
    Push-Location $WORK_DIR
    Write-Info "Directorio de trabajo: $WORK_DIR"
    
    try {
        # Crear segmentos
        if (-not (New-Segments -InputFile $VideoInput -Duration $SegmentDuration)) {
            Write-ErrorLog "Fallo al crear segmentos"
            Pop-Location
            exit 1
        }
        
        # Procesar segmentos
        if (-not (Invoke-ProcessAllSegments)) {
            Write-Warning "Algunos segmentos fallaron, continuando..."
        }
        
        # Usar directamente la ruta absoluta de salida
        $outputPath = $VideoOutput
        # Crear la carpeta de salida si no existe
        New-Item -ItemType Directory -Force -Path (Split-Path $outputPath) | Out-Null
        if (Merge-Segments -OutputFile $outputPath) {
            Pop-Location
            Write-Host ""
            Write-Host "========================================"
            Write-Host "✅ COMPRESIÓN COMPLETADA"
            Write-Host "========================================"
            Get-VideoInfo $VideoOutput
            
            $originalSize = (Get-Item $VideoInput).Length
            $compressedSize = (Get-Item $VideoOutput).Length
            
            Write-Host ""
            Write-Host "ESTADÍSTICAS FINALES:"
            Write-Host "--------------------"
            Write-Host "Tamaño original: $([math]::Round($originalSize / 1MB, 2)) MB"
            Write-Host "Tamaño comprimido: $([math]::Round($compressedSize / 1MB, 2)) MB"
            
            if ($originalSize -gt 0 -and $compressedSize -gt 0) {
                $ratio = [math]::Round($originalSize / $compressedSize, 2)
                Write-Host "Ratio de compresión: ${ratio}x"
            }
            
            Write-Host ""
            $eliminar = Read-Host "Eliminar archivos temporales? (s/n)"
            if ($eliminar -match "^[Ss]$") {
                Clear-TempFiles
                Remove-Item $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Archivos temporales eliminados"
            } else {
                Write-Info "Archivos temporales conservados en: $WORK_DIR"
            }
        } else {
            Write-ErrorLog "Error en la unión de segmentos"
            Pop-Location
            exit 1
        }
    }
    finally {
        # Asegurar regresar al directorio original
        if ((Get-Location).Path -eq (Resolve-Path $WORK_DIR).Path) {
            Pop-Location
        }
    }
    
    Write-Host ""
    Write-Success "Proceso completado exitosamente"
}

# Manejar interrupción (Ctrl+C)
try {
    Main
} catch {
    Write-Warning "Interrupción recibida, guardando estado..."
    exit 1
}