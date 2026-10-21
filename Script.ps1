<#
.SYNOPSIS
    Script de compresión H.266 VVC - Máxima eficiencia (PowerShell)
.DESCRIPTION
    Convierte un video a H.266/VVC usando FFmpeg con libvvenc.
    Segmenta, procesa por segmentos y une al final.
.PARAMETER VideoInput
    Ruta del archivo de entrada.
.PARAMETER VideoOutput
    Ruta del archivo de salida.
.PARAMETER Preset
    Preset (fastest, fast, medium, slow, slower, slowest). Por defecto: slower
.PARAMETER SegmentDuration
    Duración en segundos de cada segmento. Por defecto: 30
.EXAMPLE
    .\Script.ps1
    .\Script.ps1 -VideoInput "video.mov" -VideoOutput "salida.mp4" -Preset fast -SegmentDuration 60
#>

param(
    [string]$VideoInput  = "D:\Users\Public\Videos\Convertir\VID_20260515_010739_00_006(360).mov",
    [string]$VideoOutput = "D:\Users\Carlos\Videos\Convertir\VID_20251114_190822_h266.mp4",
    [string]$Preset = "slower",
    [int]$SegmentDuration = 30
)

# ====================================================
# CONFIGURACIÓN VVC AVANZADA
# ====================================================
$VVC_PRESET       = "slower"
$INTERNAL_BITDEPTH = "10"
$QP               = "32"
$THREADS          = "-1"
$INTRA_PERIOD     = "2"
$QPA              = "on"
$TILES            = "2x2"
$IFP              = "auto"
$MT_PROFILE       = "auto"

# CONFIGURACIÓN MULTIHILO
$PARALLEL_JOBS = 4
$WPP           = "on"

# CONFIGURACIÓN DE RECUPERACIÓN
$MAX_RETRIES  = 2
$BACKUP_EVERY = 5

# CONFIGURACIÓN AUDIO
$AUDIO_ENCODER  = "libopus"
$AUDIO_BITRATE  = "256k"
$AUDIO_CHANNELS = "2"

# =================================================================
# FUNCIONES DE LOG
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

function Write-WarningLog {
    param([string]$Message)
    Microsoft.PowerShell.Utility\Write-Warning "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: $Message"
}

function Write-ErrorLog {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $Message" -ForegroundColor Red
}

# =================================================================
# DETECCIÓN Y VALIDACIÓN
# =================================================================

function Get-HardwareAcceleration {
    Write-Info "Detectando aceleración por hardware..."
    $hwAccels = @("cuda", "vaapi", "dxva2", "d3d11va")

    Write-Info "Probando sin aceleración..."
    ffmpeg -loglevel quiet -i "$VideoInput" -t 1 -f null - 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Software funcionando"
        return ""
    }

    foreach ($accel in $hwAccels) {
        Write-Info "Probando $accel..."
        ffmpeg -hwaccel $accel -loglevel quiet -i "$VideoInput" -t 1 -f null - 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Aceleración $accel disponible"
            return $accel
        }
    }

    Write-WarningLog "Usando software (fallback)"
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

function Test-DiskSpace {
    $requiredGB = 30
    $availableGB = 100
    try {
        $drive = (Get-Location).Drive.Name
        if ($drive) {
            $freeBytes = (Get-PSDrive -Name $drive).Free
            $availableGB = [math]::Floor($freeBytes / 1GB)
        }
    } catch { $availableGB = 100 }

    if ($availableGB -lt $requiredGB) {
        Write-WarningLog "Espacio en disco bajo: ${availableGB}GB disponibles (recomendado ${requiredGB}GB)"
    }
    return $true
}

# =================================================================
# SEGMENTACIÓN
# =================================================================

function New-Segments {
    param([string]$InputFile, [int]$Duration)
    Write-Info "Creando segmentos de ${Duration}s..."

    $srcCodec = (& ffprobe -v error -select_streams v:0 `
        -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 `
        "$InputFile" 2>$null) | Out-String
    $srcCodec = $srcCodec.Trim()

    $segExt = if ($srcCodec -in @("prores","dnxhd","dnxhr","ffv1","huffyuv","rawvideo")) { "mov" } else { "mp4" }
    Write-Info "Códec origen: $srcCodec → segmentos en .$segExt"

    if (Test-Path "segment_*.$segExt") {
        $count = (Get-ChildItem "segment_*.$segExt").Count
        Write-Info "Segmentos ya existen ($count), saltando creación"
        return $true
    }

    $durStr = & ffprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 "$InputFile" 2>$null
    $totalDuration = [math]::Floor([double]$durStr)
    if ($totalDuration -le 0) { $totalDuration = 0 }
    $expectedSegments = if ($totalDuration -gt 0) { [math]::Ceiling($totalDuration / $Duration) } else { 0 }

    ffmpeg -loglevel quiet -i "$InputFile" `
        -c copy -f segment `
        -segment_time "$Duration" `
        -segment_format $segExt `
        -reset_timestamps 1 `
        -segment_start_number 0 `
        "segment_%03d.$segExt" 2>$null

    $count = (Get-ChildItem "segment_*.$segExt" -ErrorAction SilentlyContinue).Count

    if ($count -gt 1 -or ($count -eq 1 -and $expectedSegments -le 1)) {
        Write-Success "Creados $count segmentos"
        return $true
    }

    Write-WarningLog "Segmentación con -c copy produjo $count segmento(s) para $expectedSegments esperados. Reintentando manualmente..."
    Remove-Item "segment_*.$segExt" -ErrorAction SilentlyContinue

    $segmentCount = $expectedSegments
    if ($segmentCount -le 0) {
        Write-ErrorLog "No se pudo obtener duración"
        return $false
    }

    Write-Info "Creando $segmentCount segmentos manualmente (esto puede tardar)..."
    $created = 0
    for ($i = 0; $i -lt $segmentCount; $i++) {
        $start = $i * $Duration
        $name = "segment_{0:D3}.$segExt" -f $i
        if ($i % 5 -eq 0) { Write-Info "Segmento $($i+1)/$segmentCount ..." }
        ffmpeg -loglevel quiet -ss $start -i "$InputFile" `
            -t $Duration -c copy -avoid_negative_ts make_zero `
            -y "$name" 2>$null
        if ((Test-Path $name) -and (Get-Item $name).Length -gt 0) { $created++ }
    }
    Write-Info "Creados $created/$segmentCount segmentos"
    return ($created -gt 0)
}

# =================================================================
# CONVERSIÓN DE SEGMENTOS
# =================================================================

function Convert-SegmentFfmpeg {
    param(
        [string]$InputSegment,
        [string]$OutputSegment,
        [int]$Attempt
    )
    $base    = [System.IO.Path]::GetFileNameWithoutExtension($InputSegment)
    $logFile = "log_${base}_ffmpeg_attempt${Attempt}.txt"

    Write-Info "Usando FFmpeg para: $(Split-Path $InputSegment -Leaf)"

    if ([System.IO.Path]::GetExtension($OutputSegment).ToLower() -ne ".mp4") {
        $OutputSegment = [System.IO.Path]::ChangeExtension($OutputSegment, ".mp4")
    }

    $threadCount = $env:NUMBER_OF_PROCESSORS
    if (-not $threadCount) { $threadCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
    if (-not $threadCount) { $threadCount = 4 }

    $ffmpegArgs = @(
        "-i", $InputSegment,
        "-c:v", "libvvenc",
        "-preset", $VVC_PRESET,
        "-qp", $QP,
        "-threads", $threadCount,
        "-c:a", $AUDIO_ENCODER,
        "-b:a", $AUDIO_BITRATE,
        "-ac", $AUDIO_CHANNELS,
        "-y", $OutputSegment
    )

    & ffmpeg @ffmpegArgs *> $logFile

    if ($LASTEXITCODE -eq 0 -and (Test-Path $OutputSegment) -and ((Get-Item $OutputSegment).Length -gt 0)) {
        Write-Success "Convertido con FFmpeg"
        Remove-Item $logFile -ErrorAction SilentlyContinue
        return $true
    }

    if (Test-Path $logFile) {
        Write-WarningLog "Falló FFmpeg en $base (intento $Attempt). Últimas líneas del log:"
        Get-Content $logFile -Tail 15 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    return $false
}

function Invoke-ProcessSegment {
    param(
        [string]$Segment,
        [int]$SegmentNum,
        [int]$TotalSegments
    )
    $base       = [System.IO.Path]::GetFileNameWithoutExtension($Segment)
    $output     = "${base}_vvc.mp4"
    $statusFile = "${base}_status.txt"

    if ((Test-Path $output) -and ((Get-Item $output).Length -gt 0)) {
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
    # Solo segmentos originales (segment_NNN.mp4 o segment_NNN.mov, excluye _vvc)
    $segments = Get-ChildItem "segment_*.mp4","segment_*.mov" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^segment_\d{3}\.(mp4|mov)$' } |
                Sort-Object Name

    $total = $segments.Count
    if ($total -eq 0) {
        Write-ErrorLog "No se encontraron segmentos originales para procesar"
        return $false
    }

    Write-Info "Procesando $total segmentos..."
    $processed = 0
    $failed = 0

    for ($i = 0; $i -lt $total; $i++) {
        $segment    = $segments[$i].FullName
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

# =================================================================
# UNIÓN DE SEGMENTOS
# =================================================================

function Merge-Segments {
    param([string]$OutputFile)

    Write-Info "Uniendo segmentos convertidos..."

    # Opus solo se admite en MP4
    $outExt = [System.IO.Path]::GetExtension($OutputFile).ToLower()
    if ($AUDIO_ENCODER -eq "libopus" -and $outExt -ne ".mp4") {
        $newOutput = [System.IO.Path]::ChangeExtension($OutputFile, ".mp4")
        Write-WarningLog "Contenedor '$outExt' incompatible con audio Opus. Cambiando a: $(Split-Path $newOutput -Leaf)"
        $OutputFile = $newOutput
    }

    $convertedSegments = Get-ChildItem "*_vvc.mp4" -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match '^segment_\d{3}_vvc\.mp4$' } |
                         Sort-Object Name

    $convertedCount = $convertedSegments.Count
    if ($convertedCount -eq 0) {
        Write-ErrorLog "No hay segmentos convertidos para unir"
        return $false
    }

    $segmentList = Join-Path -Path (Get-Location) -ChildPath "segment_list.txt"
    $lines = $convertedSegments | ForEach-Object {
        "file '$($_.FullName -replace '\\','/')'"
    }
    [System.IO.File]::WriteAllLines($segmentList, $lines, [System.Text.Encoding]::ASCII)

    Write-Info "Uniendo $convertedCount segmentos..."

    $ffmpegArgs = @(
        "-f", "concat",
        "-safe", "0",
        "-i", $segmentList,
        "-c", "copy",
        "-y", $OutputFile
    )
    $ffmpegOutput = & ffmpeg @ffmpegArgs 2>&1
    $exitCode = $LASTEXITCODE

    $ffmpegOutput | Select-String "frame=|time=|bitrate=|error|Error" | ForEach-Object { Write-Host $_ }

    if ($exitCode -eq 0 -and (Test-Path $OutputFile) -and ((Get-Item $OutputFile).Length -gt 0)) {
        Write-Success "Video unido exitosamente"
        return $true
    } else {
        Write-Host "`nÚltimas líneas de FFmpeg (error):" -ForegroundColor Yellow
        $ffmpegOutput | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
        Write-ErrorLog "Error al unir segmentos (código de salida: $exitCode)"
        return $false
    }
}

function Clear-TempFiles {
    Write-Info "Limpiando archivos temporales..."
    Remove-Item "segment_*.mp4"   -ErrorAction SilentlyContinue
    Remove-Item "segment_*.mov"   -ErrorAction SilentlyContinue
    Remove-Item "*_vvc.mp4"       -ErrorAction SilentlyContinue
    Remove-Item "segment_list.txt" -ErrorAction SilentlyContinue
    Remove-Item "status_*.txt"    -ErrorAction SilentlyContinue
    Remove-Item "log_*.txt"       -ErrorAction SilentlyContinue
    Remove-Item "merge_ffmpeg.log" -ErrorAction SilentlyContinue
    Write-Success "Limpieza completada"
}

# =================================================================
# FLUJO PRINCIPAL
# =================================================================

function Main {
    Clear-Host
    Write-Host "========================================"
    Write-Host "COMPRESIÓN VVC - MÁXIMA EFICIENCIA"
    Write-Host "========================================"
    Write-Host "Entrada: $(Split-Path $VideoInput -Leaf)"
    Write-Host "Salida:  $(Split-Path $VideoOutput -Leaf)"
    Write-Host "Preset: $Preset"
    Write-Host "Segmentos: ${SegmentDuration}s"
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
        "fastest" { $VVC_PRESET = "fast";   $THREADS = $env:NUMBER_OF_PROCESSORS }
        "fast"    { $VVC_PRESET = "fast";   $THREADS = $env:NUMBER_OF_PROCESSORS }
        "medium"  { $VVC_PRESET = "medium" }
        { $_ -in @("slow","slower","slowest") } { $VVC_PRESET = "slower"; $INTRA_PERIOD = "4" }
        default   { $VVC_PRESET = $Preset }
    }

    $null = Get-HardwareAcceleration
    Get-VideoInfo $VideoInput

    $WORK_DIR = "vvc_encode_tmp"
    New-Item -ItemType Directory -Force -Path $WORK_DIR | Out-Null
    Push-Location $WORK_DIR
    Write-Info "Directorio de trabajo: $(Get-Location)"

    try {
        if (-not (New-Segments -InputFile $VideoInput -Duration $SegmentDuration)) {
            Write-ErrorLog "Fallo al crear segmentos"
            return
        }

        if (-not (Invoke-ProcessAllSegments)) {
            Write-WarningLog "Algunos segmentos fallaron, continuando..."
        }

        # Resolver ruta absoluta de salida antes de cambiar de directorio
        $originalDir = (Get-Location).Path
        Pop-Location
        $outputPath = if ([System.IO.Path]::IsPathRooted($VideoOutput)) {
            $VideoOutput
        } else {
            Join-Path $originalDir $VideoOutput
        }
        Push-Location $originalDir

        if (Merge-Segments -OutputFile $outputPath) {
            Pop-Location
            Write-Host ""
            Write-Host "========================================"
            Write-Host "✅ COMPRESIÓN COMPLETADA"
            Write-Host "========================================"
            Get-VideoInfo $outputPath

            $originalSize   = (Get-Item $VideoInput).Length
            $compressedSize = (Get-Item $outputPath).Length

            Write-Host ""
            Write-Host "ESTADÍSTICAS FINALES:"
            Write-Host "--------------------"
            Write-Host "Tamaño original:   $([math]::Round($originalSize   / 1MB, 2)) MB"
            Write-Host "Tamaño comprimido: $([math]::Round($compressedSize / 1MB, 2)) MB"

            if ($originalSize -gt 0 -and $compressedSize -gt 0) {
                $ratio = [math]::Round($originalSize / $compressedSize, 2)
                Write-Host "Ratio de compresión: ${ratio}x"
            }

            Write-Host ""
            $eliminar = Read-Host "Eliminar archivos temporales? (s/n)"
            if ($eliminar -match "^[Ss]$") {
                Push-Location $WORK_DIR
                Clear-TempFiles
                Pop-Location
                Remove-Item $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Archivos temporales eliminados"
            } else {
                Write-Info "Archivos temporales conservados en: $WORK_DIR"
            }
        } else {
            Pop-Location
            Write-ErrorLog "Error en la unión de segmentos"
            return
        }
    }
    finally {
        # Asegurar regresar al directorio original si aún estamos dentro del workdir
        while ((Get-Location).Path -ne (Split-Path $PSCommandPath -Parent) -and
               (Get-Location).Path -match 'vvc_encode_tmp$') {
            Pop-Location
        }
    }

    Write-Host ""
    Write-Success "Proceso completado exitosamente"
}

# =================================================================
# EJECUCIÓN PRINCIPAL CON MANEJO DE ERRORES
# =================================================================
try {
    Main
}
catch [System.Management.Automation.PipelineStoppedException] {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] INTERRUMPIDO por el usuario (Ctrl+C)." -ForegroundColor Yellow
    exit 130
}
catch {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Línea: $($_.InvocationInfo.ScriptLineNumber) — $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    exit 1
}