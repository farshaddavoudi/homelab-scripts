Add-Type -AssemblyName System.Windows.Forms

function Pause-And-Exit {
    Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
    Read-Host
    exit
}

# ---- CHECK FFMPEG ----
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "❌ FFmpeg not found. Install with: winget install ffmpeg" -ForegroundColor Red
    Pause-And-Exit
}

# ---- FILE PICKER ----
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select video file(s)"
$dialog.Filter = "Video Files (*.mp4;*.mkv;*.mov;*.avi)|*.mp4;*.mkv;*.mov;*.avi|All Files (*.*)|*.*"
$dialog.Multiselect = $true

if ($dialog.ShowDialog() -ne "OK") {
    Write-Host "❌ No file selected." -ForegroundColor Yellow
    Pause-And-Exit
}

$InputFiles = $dialog.FileNames

# ---- SPEED INPUT ----
$speedInput = Read-Host "Enter speed (default 1.3)"
if ([string]::IsNullOrWhiteSpace($speedInput)) {
    $Speed = 1.3
} else {
    $Speed = [double]$speedInput
}

# ---- AUDIO FILTER BUILDER ----
function Get-AtempoChain($speed) {
    $chain = @()
    $remaining = $speed

    while ($remaining -gt 2.0) {
        $chain += "atempo=2.0"
        $remaining /= 2.0
    }

    while ($remaining -lt 0.5) {
        $chain += "atempo=0.5"
        $remaining *= 2.0
    }

    $chain += ("atempo={0}" -f $remaining)
    return ($chain -join ",")
}

$AudioFilter = Get-AtempoChain $Speed

# ---- QUALITY SELECTION ----
Write-Host "Select output quality:"
Write-Host "1) High quality (larger file)"
Write-Host "2) Balanced (recommended)"
Write-Host "3) Small size (lower quality)"

$choice = Read-Host "Enter 1 / 2 / 3"

switch ($choice) {
    "1" { $CRF = 23 }
    "2" { $CRF = 28 }
    "3" { $CRF = 32 }
    default {
        Write-Host "Invalid choice. Using Balanced." -ForegroundColor Yellow
        $CRF = 28
    }
}

$Preset = "fast"

# ---- PROCESS ----
foreach ($file in $InputFiles) {

    if (-not (Test-Path $file)) {
        Write-Host "❌ File not found: $file" -ForegroundColor Red
        continue
    }

    $dir = Split-Path $file
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $ext = [System.IO.Path]::GetExtension($file)
    $output = Join-Path $dir "$name-speed$Speed$ext"

    Write-Host "`n🎬 Processing: $file" -ForegroundColor Cyan
    Write-Host "➡️ Output: $output" -ForegroundColor Green
    Write-Host "⚙️ Speed: $Speed | CRF: $CRF" -ForegroundColor DarkGray

    # ---- START PROCESS ----
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ffmpeg"
    $psi.Arguments = "-i `"$file`" -filter:v `"setpts=$(1/$Speed)*PTS`" -filter:a `"$AudioFilter`" -crf $CRF -preset $Preset `"$output`""
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null

    # ---- LIVE FEEDBACK LOOP ----
    $lastMessageTime = Get-Date

    while (-not $process.HasExited) {

        if (-not $process.StandardError.EndOfStream) {
            $line = $process.StandardError.ReadLine()

            if ($line -match "time=(\d+:\d+:\d+\.\d+)") {
                Write-Host "⏱ $($matches[1]) processed..." -ForegroundColor DarkGray
                $lastMessageTime = Get-Date
            }
        }

        # Heartbeat every 5 seconds
        if ((Get-Date) - $lastMessageTime -gt [TimeSpan]::FromSeconds(5)) {
            Write-Host "⏳ Still processing..." -ForegroundColor DarkGray
            $lastMessageTime = Get-Date
        }

        Start-Sleep -Milliseconds 200
    }

    if ($process.ExitCode -eq 0) {
        Write-Host "✅ Done: $output" -ForegroundColor Green
    } else {
        Write-Host "❌ Error processing file." -ForegroundColor Red
    }
}

Pause-And-Exit