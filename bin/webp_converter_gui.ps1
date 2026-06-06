param(
    [switch]$SelfTest,
    [switch]$UiSelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function K {
    param([string]$Hex)

    $chars = foreach ($part in ($Hex -split '\s+')) {
        if ($part) {
            [char][Convert]::ToInt32($part, 16)
        }
    }

    -join $chars
}

$Text = @{
    Title            = 'WebP ' + (K 'BCC0 D658 AE30')
    FileSelect       = K 'D30C C77C 0020 C120 D0DD'
    Quality          = K 'D488 C9C8'
    Convert          = K 'BCC0 D658'
    OutputFolder     = K 'CD9C B825 0020 D3F4 B354'
    SelectedFiles    = K 'C120 D0DD B41C 0020 D30C C77C'
    NoSelectedFiles  = K 'C120 D0DD B41C 0020 D30C C77C 0020 C5C6 C74C'
    Ready            = K 'C900 BE44 B428'
    Status           = K 'C0C1 D0DC'
    Converting       = K 'BCC0 D658 0020 C911'
    Done             = K 'C644 B8CC'
    Failed           = K 'C2E4 D328'
    Success          = K 'C131 ACF5'
    Error            = K 'C624 B958'
    SelectFileFirst  = K 'D30C C77C C744 0020 BA3C C800 0020 C120 D0DD D558 C138 C694 002E'
    PickMedia        = K 'BCC0 D658 D560 0020 BBF8 B514 C5B4 0020 D30C C77C C744 0020 C120 D0DD D558 C138 C694 002E'
    PickOutputFolder = K 'BCC0 D658 B41C 0020 0057 0065 0062 0050 B97C 0020 C800 C7A5 D560 0020 D3F4 B354 B97C 0020 C120 D0DD D558 C138 C694 002E'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

$FfmpegPath  = Join-Path $ScriptDir 'ffmpeg.exe'
$FfprobePath = Join-Path $ScriptDir 'ffprobe.exe'
$FfplayPath  = Join-Path $ScriptDir 'ffplay.exe'
$DefaultOutputDir = Join-Path $ScriptDir 'converted'

# ---------------------------------------------------------------------------
#  Shared helpers
# ---------------------------------------------------------------------------

function Get-WebPEncoderArgs {
    param(
        [ValidateSet('q80', 'q90', 'lossless')]
        [string]$Quality
    )

    switch ($Quality) {
        'q80' {
            return @(
                '-c:v', 'libwebp',
                '-lossless', '0',
                '-q:v', '80',
                '-preset', 'default',
                '-loop', '0',
                '-an',
                '-fps_mode', 'passthrough'
            )
        }
        'q90' {
            return @(
                '-c:v', 'libwebp',
                '-lossless', '0',
                '-q:v', '90',
                '-preset', 'default',
                '-loop', '0',
                '-an',
                '-fps_mode', 'passthrough'
            )
        }
        'lossless' {
            return @(
                '-c:v', 'libwebp',
                '-lossless', '1',
                '-q:v', '100',
                '-preset', 'default',
                '-loop', '0',
                '-an',
                '-fps_mode', 'passthrough'
            )
        }
    }
}

function Get-UniqueOutputPath {
    param(
        [string]$InputPath,
        [string]$OutputDir
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($InputPath)
    $candidate = Join-Path $OutputDir ($baseName + '.webp')

    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    for ($i = 1; $i -lt 10000; $i++) {
        $candidate = Join-Path $OutputDir ('{0}_{1:D3}.webp' -f $baseName, $i)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Could not create a unique output file name.'
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    ($Arguments | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    }) -join ' '
}

function Wait-ProcessPumping {
    <#
    .SYNOPSIS
        Waits for a started process to exit while pumping the WinForms
        message loop so the UI stays responsive.  Falls back to a plain
        sleep loop when the GUI assemblies are not loaded (e.g. -SelfTest).
    #>
    param([Diagnostics.Process]$Process)

    # Kick off non-blocking reads so we never deadlock on buffer-full pipes
    $stdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $stderrTask = $Process.StandardError.ReadToEndAsync()

    # Detect whether WinForms is available (not loaded during -SelfTest)
    $canPump = $false
    try {
        [void][Windows.Forms.Application]
        $canPump = $true
    } catch {}

    while (-not $Process.HasExited) {
        if ($canPump) {
            [Windows.Forms.Application]::DoEvents()
        }
        Start-Sleep -Milliseconds 30
    }

    # Final WaitForExit ensures async event buffers are flushed
    $Process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $Process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
    }
}

function Invoke-WebPConversion {
    param(
        [string]$InputPath,
        [string]$OutputDir,
        [ValidateSet('q80', 'q90', 'lossless')]
        [string]$Quality
    )

    if (-not (Test-Path -LiteralPath $FfmpegPath)) {
        throw "ffmpeg.exe not found: $FfmpegPath"
    }

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Input file not found: $InputPath"
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }

    $outputPath = Get-UniqueOutputPath -InputPath $InputPath -OutputDir $OutputDir
    $arguments = @('-hide_banner', '-y', '-i', $InputPath) + (Get-WebPEncoderArgs -Quality $Quality) + @($outputPath)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FfmpegPath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $pResult = Wait-ProcessPumping -Process $process
    $stderr = $pResult.StdErr
    $stdout = $pResult.StdOut

    if ($process.ExitCode -ne 0) {
        $message = ($stderr + [Environment]::NewLine + $stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "ffmpeg exited with code $($process.ExitCode)."
        }
        throw $message
    }

    [pscustomobject]@{
        Input  = $InputPath
        Output = $outputPath
        Log    = ($stderr + [Environment]::NewLine + $stdout).Trim()
    }
}

# ---------------------------------------------------------------------------
#  Video Segment helpers
# ---------------------------------------------------------------------------

function Test-VideoSource {
    <#
    .SYNOPSIS
        Returns 'local' for existing file paths, 'url' for http(s) URLs, or $null.
    #>
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) { return $null }

    $trimmed = $Source.Trim()

    if ($trimmed -match '^https?://') {
        return 'url'
    }

    if (Test-Path -LiteralPath $trimmed) {
        return 'local'
    }

    return $null
}

function Invoke-FfprobeMediaInfo {
    <#
    .SYNOPSIS
        Runs ffprobe and returns duration (seconds), width, height, and format name.
    #>
    param([string]$Source)

    if (-not (Test-Path -LiteralPath $FfprobePath)) {
        throw "ffprobe.exe not found: $FfprobePath"
    }

    $arguments = @(
        '-v', 'error',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        '-select_streams', 'v:0',
        $Source
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FfprobePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $pResult = Wait-ProcessPumping -Process $process
    $stderr = $pResult.StdErr
    $stdout = $pResult.StdOut

    if ($process.ExitCode -ne 0) {
        $detail = $stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "ffprobe exited with code $($process.ExitCode)."
        }
        $isUrl = ($Source -match '^https?://')
        if ($isUrl) {
            throw "Failed to probe URL source. V1 supports direct video URLs only (site pages like YouTube are unsupported).`n$detail"
        }
        throw "Failed to probe video file.`n$detail"
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw 'ffprobe returned no output. The source may not be a valid media file or direct video URL.'
    }

    $json = $stdout | ConvertFrom-Json

    $duration = 0.0
    $width = 0
    $height = 0
    $formatName = ''

    if ($json.format -and $json.format.duration) {
        $duration = [double]$json.format.duration
    }

    if ($json.streams -and $json.streams.Count -gt 0) {
        $vs = $json.streams[0]
        if ($vs.width)  { $width  = [int]$vs.width }
        if ($vs.height) { $height = [int]$vs.height }
        if ($vs.duration -and $duration -eq 0.0) {
            $duration = [double]$vs.duration
        }
    }

    if ($json.format -and $json.format.format_name) {
        $formatName = $json.format.format_name
    }

    [pscustomobject]@{
        Duration   = $duration
        Width      = $width
        Height     = $height
        FormatName = $formatName
    }
}

function Find-YtDlp {
    <#
    .SYNOPSIS
        Locates yt-dlp.exe — checks PATH.
        Returns the full path or $null.
    #>
    $cmd = Get-Command 'yt-dlp' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Resolve-YtDlpStreamUrl {
    <#
    .SYNOPSIS
        Uses yt-dlp to extract the best direct video stream URL for a page URL.
        Returns a hashtable with Url, Title, and Duration.
    #>
    param([string]$PageUrl)

    $ytdlp = Find-YtDlp
    if (-not $ytdlp) {
        throw "yt-dlp is not installed. Install it with: winget install yt-dlp.yt-dlp"
    }

    # Get the best mp4 stream URL (no download, just extract)
    $arguments = @(
        '--no-download',
        '--print', 'urls',
        '-f', 'bv*[ext=mp4]+ba[ext=m4a]/bv*[ext=mp4]/b[ext=mp4]/bv*+ba/b',
        '--no-playlist',
        $PageUrl
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ytdlp
    $startInfo.Arguments = Join-ProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $pResult = Wait-ProcessPumping -Process $process
    $stderr = $pResult.StdErr
    $stdout = $pResult.StdOut

    if ($process.ExitCode -ne 0) {
        $detail = $stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "yt-dlp exited with code $($process.ExitCode)."
        }
        throw "yt-dlp failed to extract video URL.`n$detail"
    }

    # stdout contains the direct stream URL(s), one per line; take the first video URL
    $urls = $stdout.Trim() -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    if ($urls.Count -eq 0) {
        throw 'yt-dlp did not return a stream URL.'
    }

    # Return the first URL (video stream)
    return $urls[0].Trim()
}

function Convert-TimeSpanText {
    <#
    .SYNOPSIS
        Parses user-entered time strings into total seconds (double).
        Accepted formats: seconds (5, 5.25), MM:SS, HH:MM:SS, HH:MM:SS.mmm
    #>
    param([string]$Text)

    $t = $Text.Trim()

    if ([string]::IsNullOrWhiteSpace($t)) {
        throw 'Time value is empty.'
    }

    # Pure numeric (seconds with optional decimals)
    if ($t -match '^\d+(\.\d+)?$') {
        return [double]$t
    }

    # MM:SS or MM:SS.mmm
    if ($t -match '^(\d{1,2}):(\d{1,2})(\.\d+)?$') {
        $mins = [int]$Matches[1]
        $secs = [int]$Matches[2]
        $frac = if ($Matches[3]) { [double]$Matches[3] } else { 0.0 }
        return $mins * 60 + $secs + $frac
    }

    # HH:MM:SS or HH:MM:SS.mmm
    if ($t -match '^(\d{1,2}):(\d{2}):(\d{2})(\.\d+)?$') {
        $hrs  = [int]$Matches[1]
        $mins = [int]$Matches[2]
        $secs = [int]$Matches[3]
        $frac = if ($Matches[4]) { [double]$Matches[4] } else { 0.0 }
        return $hrs * 3600 + $mins * 60 + $secs + $frac
    }

    throw "Invalid time format: '$t'. Use seconds, MM:SS, or HH:MM:SS[.mmm]."
}

function Format-SegmentTime {
    <#
    .SYNOPSIS
        Converts total seconds to HH:MM:SS.mmm display string.
    #>
    param([double]$Seconds)

    $ts = [TimeSpan]::FromSeconds($Seconds)
    return '{0:D2}:{1:D2}:{2:D2}.{3:D3}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, $ts.Milliseconds
}

function Get-SegmentOutputPath {
    <#
    .SYNOPSIS
        Produces a unique output filename for a segment.
        Local files use <basename>_segment_NNN.webp.
        URL sources use video_segment_NNN.webp or derive a name from the URL.
    #>
    param(
        [string]$Source,
        [string]$SourceType,
        [int]$SegmentIndex,
        [string]$OutputDir
    )

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }

    $baseName = 'video'

    if ($SourceType -eq 'local') {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($Source)
    }
    elseif ($SourceType -eq 'url') {
        try {
            $uri = [Uri]$Source
            $urlFile = [IO.Path]::GetFileNameWithoutExtension($uri.AbsolutePath)
            if (-not [string]::IsNullOrWhiteSpace($urlFile) -and $urlFile -ne '/' -and $urlFile.Length -gt 0) {
                # Sanitize: keep only safe chars
                $urlFile = $urlFile -replace '[^a-zA-Z0-9_\-]', '_'
                if ($urlFile.Length -gt 0 -and $urlFile -ne '_') {
                    $baseName = $urlFile
                }
            }
        }
        catch { }
    }

    $segName = '{0}_segment_{1:D3}' -f $baseName, $SegmentIndex

    $candidate = Join-Path $OutputDir ($segName + '.webp')
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    for ($i = 1; $i -lt 10000; $i++) {
        $candidate = Join-Path $OutputDir ('{0}_{1:D3}.webp' -f $segName, $i)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Could not create a unique segment output file name.'
}

function Invoke-WebPSegmentConversion {
    <#
    .SYNOPSIS
        Converts a single video segment to animated WebP using FFmpeg.
    #>
    param(
        [string]$Source,
        [string]$SourceType,
        [string]$OutputDir,
        [ValidateSet('q80', 'q90', 'lossless')]
        [string]$Quality,
        [double]$StartSeconds,
        [double]$EndSeconds,
        [int]$SegmentIndex
    )

    if (-not (Test-Path -LiteralPath $FfmpegPath)) {
        throw "ffmpeg.exe not found: $FfmpegPath"
    }

    $segDuration = $EndSeconds - $StartSeconds
    if ($segDuration -le 0) {
        throw 'Segment duration must be positive.'
    }

    $outputPath = Get-SegmentOutputPath -Source $Source -SourceType $SourceType -SegmentIndex $SegmentIndex -OutputDir $OutputDir

    $startStr    = $StartSeconds.ToString('F3')
    $durationStr = $segDuration.ToString('F3')

    $arguments = @('-hide_banner', '-y', '-ss', $startStr, '-t', $durationStr, '-i', $Source) +
                 (Get-WebPEncoderArgs -Quality $Quality) +
                 @($outputPath)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FfmpegPath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $pResult = Wait-ProcessPumping -Process $process
    $stderr = $pResult.StdErr
    $stdout = $pResult.StdOut

    if ($process.ExitCode -ne 0) {
        $message = ($stderr + [Environment]::NewLine + $stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "ffmpeg exited with code $($process.ExitCode)."
        }
        throw $message
    }

    [pscustomobject]@{
        SegmentIndex = $SegmentIndex
        Start        = $StartSeconds
        End          = $EndSeconds
        Output       = $outputPath
        Log          = ($stderr + [Environment]::NewLine + $stdout).Trim()
    }
}

function Invoke-SegmentPreview {
    <#
    .SYNOPSIS
        Launches ffplay.exe to preview a segment. Non-blocking.
    #>
    param(
        [string]$Source,
        [double]$StartSeconds,
        [double]$Duration
    )

    if (-not (Test-Path -LiteralPath $FfplayPath)) {
        throw "ffplay.exe not found: $FfplayPath"
    }

    if ($Duration -le 0) {
        throw 'Preview duration must be positive.'
    }

    $startStr = $StartSeconds.ToString('F3')
    $durStr   = $Duration.ToString('F3')

    $arguments = @(
        '-hide_banner',
        '-autoexit',
        '-ss', $startStr,
        '-t', $durStr,
        $Source
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FfplayPath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    # Non-blocking: the preview window runs independently
}

# ---------------------------------------------------------------------------
#  Self-Test
# ---------------------------------------------------------------------------

if ($SelfTest) {
    if (-not (Test-Path -LiteralPath $FfmpegPath)) {
        throw "ffmpeg.exe not found: $FfmpegPath"
    }

    # -- Existing quality arg checks --
    foreach ($quality in @('q80', 'q90', 'lossless')) {
        $args = Get-WebPEncoderArgs -Quality $quality
        if ($args -contains '-vsync') {
            throw "Deprecated -vsync option found for $quality."
        }
        if (-not ($args -contains '-fps_mode')) {
            throw "Missing -fps_mode option for $quality."
        }
    }

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('webp-converter-selftest-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    try {
        # -- Existing conversion test --
        $samplePath = Join-Path $testRoot 'sample.gif'
        $generateArgs = @(
            '-hide_banner',
            '-v', 'error',
            '-y',
            '-f', 'lavfi',
            '-i', 'testsrc2=size=64x64:rate=2:duration=1',
            $samplePath
        )

        & $FfmpegPath @generateArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create a self-test media file. ffmpeg exited with code $LASTEXITCODE."
        }

        $result = Invoke-WebPConversion -InputPath $samplePath -OutputDir $testRoot -Quality 'q80'
        if (-not (Test-Path -LiteralPath $result.Output)) {
            throw "Self-test conversion did not create an output file."
        }
        if ((Get-Item -LiteralPath $result.Output).Length -le 0) {
            throw "Self-test conversion created an empty output file."
        }

        # -- NEW: ffprobe media info test --
        $sampleVideoPath = Join-Path $testRoot 'sample_video.mp4'
        $videoGenArgs = @(
            '-hide_banner',
            '-v', 'error',
            '-y',
            '-f', 'lavfi',
            '-i', 'testsrc2=size=128x96:rate=10:duration=3',
            '-c:v', 'libx264',
            '-pix_fmt', 'yuv420p',
            $sampleVideoPath
        )
        & $FfmpegPath @videoGenArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create a self-test video file. ffmpeg exited with code $LASTEXITCODE."
        }

        $probeResult = Invoke-FfprobeMediaInfo -Source $sampleVideoPath
        if ($probeResult.Duration -lt 2.0) {
            throw "Probed duration ($($probeResult.Duration)) is too short for a 3-second test video."
        }
        if ($probeResult.Width -ne 128 -or $probeResult.Height -ne 96) {
            throw "Probed resolution ($($probeResult.Width)x$($probeResult.Height)) doesn't match expected 128x96."
        }

        # -- NEW: Time parsing tests --
        $timeTests = @(
            @{ Input = '5';             Expected = 5.0 },
            @{ Input = '00:05';         Expected = 5.0 },
            @{ Input = '00:00:05';      Expected = 5.0 },
            @{ Input = '00:00:05.250';  Expected = 5.25 },
            @{ Input = '1:30';          Expected = 90.0 },
            @{ Input = '1:05:30';       Expected = 3930.0 },
            @{ Input = '0:00:00.500';   Expected = 0.5 }
        )

        foreach ($tt in $timeTests) {
            $parsed = Convert-TimeSpanText -Text $tt.Input
            if ([Math]::Abs($parsed - $tt.Expected) -gt 0.01) {
                throw "Time parse '$($tt.Input)': expected $($tt.Expected), got $parsed."
            }
        }

        # -- NEW: Invalid time parsing should throw --
        $invalidTimes = @('', 'abc', ':::', '1:2:3:4')
        foreach ($inv in $invalidTimes) {
            $threw = $false
            try { Convert-TimeSpanText -Text $inv } catch { $threw = $true }
            if (-not $threw) {
                throw "Time parse should have rejected '$inv' but did not."
            }
        }

        # -- NEW: Invalid range check --
        # end <= start should be caught by Invoke-WebPSegmentConversion
        $threw = $false
        try {
            Invoke-WebPSegmentConversion -Source $sampleVideoPath -SourceType 'local' `
                -OutputDir $testRoot -Quality 'q80' -StartSeconds 5.0 -EndSeconds 3.0 -SegmentIndex 1
        } catch { $threw = $true }
        if (-not $threw) {
            throw 'Segment conversion should reject end <= start but did not.'
        }

        # -- NEW: Two segments from test video produce two non-empty .webp outputs --
        $seg1 = Invoke-WebPSegmentConversion -Source $sampleVideoPath -SourceType 'local' `
            -OutputDir $testRoot -Quality 'q80' -StartSeconds 0.0 -EndSeconds 1.0 -SegmentIndex 1
        $seg2 = Invoke-WebPSegmentConversion -Source $sampleVideoPath -SourceType 'local' `
            -OutputDir $testRoot -Quality 'q90' -StartSeconds 1.0 -EndSeconds 2.5 -SegmentIndex 2

        if (-not (Test-Path -LiteralPath $seg1.Output)) {
            throw "Segment 1 output not created."
        }
        if ((Get-Item -LiteralPath $seg1.Output).Length -le 0) {
            throw "Segment 1 output is empty."
        }
        if (-not (Test-Path -LiteralPath $seg2.Output)) {
            throw "Segment 2 output not created."
        }
        if ((Get-Item -LiteralPath $seg2.Output).Length -le 0) {
            throw "Segment 2 output is empty."
        }

        # -- NEW: Test-VideoSource basic checks --
        $svLocal = Test-VideoSource -Source $sampleVideoPath
        if ($svLocal -ne 'local') { throw "Test-VideoSource did not return 'local' for existing file." }
        $svUrl = Test-VideoSource -Source 'https://example.com/video.mp4'
        if ($svUrl -ne 'url') { throw "Test-VideoSource did not return 'url' for https URL." }
        $svNull = Test-VideoSource -Source ''
        if ($svNull -ne $null) { throw "Test-VideoSource did not return null for empty string." }

        # -- NEW: Format-SegmentTime test --
        $fmt = Format-SegmentTime -Seconds 3661.5
        if ($fmt -ne '01:01:01.500') {
            throw "Format-SegmentTime: expected '01:01:01.500', got '$fmt'."
        }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }

    Write-Output 'SelfTest OK'
    exit 0
}

# ---------------------------------------------------------------------------
#  GUI
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:dpiScale = 1.0
try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public static class Win32 {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
        
        [DllImport("user32.dll")]
        public static extern int GetDpiForSystem();
    }
"@
    [Win32]::SetProcessDPIAware() | Out-Null
    $script:dpiScale = [Win32]::GetDpiForSystem() / 96.0
} catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:selectedFiles = @()
$script:selectedQuality = 'q80'
$script:currentMode = 'basic'     # 'basic' or 'segment'
$script:videoSource = ''
$script:videoSourceType = $null    # 'local', 'url', or $null
$script:resolvedSource = ''        # actual stream URL/path for ffmpeg (may differ from videoSource for yt-dlp URLs)
$script:videoMediaInfo = $null     # result from Invoke-FfprobeMediaInfo
$script:segments = @()             # array of @{ Start; End } hashtables

$Colors = @{
    Bg        = [Drawing.ColorTranslator]::FromHtml('#0b0d17')
    Panel     = [Drawing.ColorTranslator]::FromHtml('#121626')
    PanelSoft = [Drawing.ColorTranslator]::FromHtml('#0f172a')
    Border    = [Drawing.ColorTranslator]::FromHtml('#2a3146')
    Text      = [Drawing.ColorTranslator]::FromHtml('#f8fafc')
    Muted     = [Drawing.ColorTranslator]::FromHtml('#94a3b8')
    Accent1   = [Drawing.ColorTranslator]::FromHtml('#ff512f')
    Accent2   = [Drawing.ColorTranslator]::FromHtml('#dd2476')
    Success   = [Drawing.ColorTranslator]::FromHtml('#10b981')
    Danger    = [Drawing.ColorTranslator]::FromHtml('#ef4444')
    Teal      = [Drawing.ColorTranslator]::FromHtml('#14b8a6')
    Purple    = [Drawing.ColorTranslator]::FromHtml('#a855f7')
}

function New-UiFont {
    param(
        [single]$Size,
        [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular
    )

    New-Object Drawing.Font('Malgun Gothic', $Size, $Style)
}

function New-Label {
    param(
        [string]$TextValue,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [Drawing.Color]$ForeColor,
        [single]$Size = 9,
        [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular
    )

    $label = New-Object Windows.Forms.Label
    $label.Text = $TextValue
    $label.Location = New-Object Drawing.Point([int]($X * $script:dpiScale), [int]($Y * $script:dpiScale))
    $label.Size = New-Object Drawing.Size([int]($Width * $script:dpiScale), [int]($Height * $script:dpiScale))
    $label.ForeColor = $ForeColor
    $label.BackColor = [Drawing.Color]::Transparent
    $label.Font = New-UiFont -Size $Size -Style $Style
    $label
}

function Set-FlatButtonStyle {
    param(
        [Windows.Forms.Button]$Button,
        [Drawing.Color]$BackColor,
        [Drawing.Color]$ForeColor,
        [Drawing.Color]$BorderColor
    )

    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.BackColor = $BackColor
    $Button.ForeColor = $ForeColor
    $Button.Font = New-UiFont -Size 9 -Style ([Drawing.FontStyle]::Bold)
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
    $Button.FlatAppearance.BorderColor = $BorderColor
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#1f2937')
    $Button.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
}

function Add-PanelBorder {
    param(
        [Windows.Forms.Control]$Control,
        [switch]$Dashed
    )

    $isDashed = [bool]$Dashed
    $paintHandler = {
        param($sender, $eventArgs)

        $rect = $sender.ClientRectangle
        $rect.Width = $rect.Width - 1
        $rect.Height = $rect.Height - 1
        $pen = New-Object Drawing.Pen($Colors.Border, 1)
        if ($isDashed) {
            $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
            $pen.Color = [Drawing.ColorTranslator]::FromHtml('#5b6478')
        }
        $eventArgs.Graphics.DrawRectangle($pen, $rect)
        $pen.Dispose()
    }.GetNewClosure()

    $Control.Add_Paint($paintHandler)
}

$script:dropZoneHover = $false

# ---------------------------------------------------------------------------
#  Basic mode helpers (existing)
# ---------------------------------------------------------------------------

function Open-FilePicker {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = $Text.PickMedia
    $dialog.Multiselect = $true
    $dialog.Filter = 'Media files|*.gif;*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff;*.mp4;*.mov;*.avi;*.mkv;*.webm|All files|*.*'

    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        Add-SelectedFiles -Files @($dialog.FileNames)
    }
}

function Add-SelectedFiles {
    param([string[]]$Files)

    foreach ($file in $Files) {
        if (($script:selectedFiles -notcontains $file) -and (Test-Path -LiteralPath $file)) {
            $script:selectedFiles += $file
        }
    }
    Update-FileUi
}

function Update-FileUi {
    $fileCountLabel.Text = 'Selected Files ({0})' -f $script:selectedFiles.Count
    $fileList.Items.Clear()

    if ($script:selectedFiles.Count -eq 0) {
        [void]$fileList.Items.Add('No files selected')
        $clearButton.Visible = $false
        $convertButton.Enabled = $false
    }
    else {
        foreach ($file in $script:selectedFiles) {
            [void]$fileList.Items.Add($file)
        }
        $clearButton.Visible = $true
        $convertButton.Enabled = $true
    }
}

# ---------------------------------------------------------------------------
#  Segment mode helpers
# ---------------------------------------------------------------------------

function Update-SegmentListView {
    $segmentListView.Items.Clear()
    for ($i = 0; $i -lt $script:segments.Count; $i++) {
        $seg = $script:segments[$i]
        $dur = $seg.End - $seg.Start
        $idx = $i + 1
        $item = New-Object Windows.Forms.ListViewItem(([string]$idx))
        [void]$item.SubItems.Add((Format-SegmentTime -Seconds $seg.Start))
        [void]$item.SubItems.Add((Format-SegmentTime -Seconds $seg.End))
        [void]$item.SubItems.Add(('{0:F1}s' -f $dur))

        # Expected output name
        $baseName = 'video'
        if ($script:videoSourceType -eq 'local' -and -not [string]::IsNullOrWhiteSpace($script:videoSource)) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($script:videoSource)
        }
        [void]$item.SubItems.Add(('{0}_segment_{1:D3}.webp' -f $baseName, $idx))

        $item.ForeColor = $Colors.Text
        $item.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
        [void]$segmentListView.Items.Add($item)
    }

    $segConvertButton.Enabled = ($script:segments.Count -gt 0)
}

function Update-VideoInfoDisplay {
    if ($script:videoMediaInfo -ne $null) {
        $info = $script:videoMediaInfo
        $durText = Format-SegmentTime -Seconds $info.Duration
        $resText = '{0}x{1}' -f $info.Width, $info.Height
        $sourceDisplay = if ($script:videoSourceType -eq 'local') {
            [IO.Path]::GetFileName($script:videoSource)
        } else {
            $script:videoSource
        }
        $videoInfoLabel.Text = "Source: $sourceDisplay  |  Duration: $durText  |  Resolution: $resText"
        $videoInfoLabel.ForeColor = $Colors.Success

        # Configure trackbar
        $segTrackbar.Minimum = 0
        $segTrackbar.Maximum = [Math]::Max(1, [int]($info.Duration * 10))  # tenths of second
        $segTrackbar.Value = 0
        $segTrackbar.Enabled = $true
    }
    else {
        $videoInfoLabel.Text = 'No video loaded'
        $videoInfoLabel.ForeColor = $Colors.Muted
        $segTrackbar.Enabled = $false
    }
}

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------

function Add-Log {
    param(
        [string]$Message,
        [ValidateSet('normal', 'success', 'error')]
        [string]$Type = 'normal'
    )

    $prefix = '[{0}] ' -f (Get-Date -Format 'HH:mm:ss')
    $resultBox.SelectionStart = $resultBox.TextLength
    $resultBox.SelectionLength = 0

    switch ($Type) {
        'success' { $resultBox.SelectionColor = $Colors.Success }
        'error' { $resultBox.SelectionColor = $Colors.Danger }
        default { $resultBox.SelectionColor = $Colors.Muted }
    }

    $resultBox.AppendText($prefix + $Message + [Environment]::NewLine)
    $resultBox.SelectionColor = $resultBox.ForeColor
    $resultBox.ScrollToCaret()
}

function Set-Busy {
    param([bool]$Busy)

    # Mode selector
    $modeBasicRadio.Enabled = -not $Busy
    $modeSegmentRadio.Enabled = -not $Busy

    # Basic mode controls
    $dropZone.Enabled = -not $Busy
    $fileButton.Enabled = -not $Busy
    $clearButton.Enabled = -not $Busy

    # Shared controls
    $qualityCombo.Enabled = -not $Busy
    $outputButton.Enabled = -not $Busy
    $outputBox.Enabled = -not $Busy

    if ($script:currentMode -eq 'basic') {
        $convertButton.Enabled = (-not $Busy) -and ($script:selectedFiles.Count -gt 0)
        $convertButton.Text = if ($Busy) { 'Converting...' } else { 'Start Conversion' }
    }
    else {
        # Segment mode controls
        $segVideoUrlBox.Enabled = -not $Busy
        $segBrowseButton.Enabled = -not $Busy
        $segLoadButton.Enabled = -not $Busy
        $segStartBox.Enabled = -not $Busy
        $segEndBox.Enabled = -not $Busy
        $segSetStartButton.Enabled = -not $Busy
        $segSetEndButton.Enabled = -not $Busy
        $segAddButton.Enabled = -not $Busy
        $segRemoveButton.Enabled = -not $Busy
        $segPreviewButton.Enabled = -not $Busy
        $segTrackbar.Enabled = (-not $Busy) -and ($script:videoMediaInfo -ne $null)
        $segConvertButton.Enabled = (-not $Busy) -and ($script:segments.Count -gt 0)
        $segConvertButton.Text = if ($Busy) { 'Converting Segments...' } else { 'Convert Segments' }
    }
}

# ===========================================================================
#  BUILD THE FORM
# ===========================================================================

$form = New-Object Windows.Forms.Form
$form.Text = 'WebP Converter'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size([int](860 * $script:dpiScale), [int](920 * $script:dpiScale))
$form.MinimumSize = New-Object Drawing.Size([int](780 * $script:dpiScale), [int](860 * $script:dpiScale))
$form.Font = New-UiFont -Size 9
$form.BackColor = $Colors.Bg

$panel = New-Object Windows.Forms.Panel
$panel.Location = New-Object Drawing.Point([int](34 * $script:dpiScale), [int](24 * $script:dpiScale))
$panel.Size = New-Object Drawing.Size([int](776 * $script:dpiScale), [int](850 * $script:dpiScale))
$panel.Anchor = 'Top,Bottom,Left,Right'
$panel.BackColor = $Colors.Panel
$panel.AutoScroll = $true
Add-PanelBorder -Control $panel

# ---- Title ----
$titleLabel = New-Label -TextValue 'WebP Converter' -X 0 -Y 16 -Width 776 -Height 32 -ForeColor $Colors.Text -Size 18 -Style ([Drawing.FontStyle]::Bold)
$titleLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter

# ---- Mode Selector ----
$modePanel = New-Object Windows.Forms.Panel
$modePanel.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](56 * $script:dpiScale))
$modePanel.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](36 * $script:dpiScale))
$modePanel.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
Add-PanelBorder -Control $modePanel

$modeBasicRadio = New-Object Windows.Forms.RadioButton
$modeBasicRadio.Text = 'Basic Convert'
$modeBasicRadio.Location = New-Object Drawing.Point([int](20 * $script:dpiScale), [int](6 * $script:dpiScale))
$modeBasicRadio.Size = New-Object Drawing.Size([int](180 * $script:dpiScale), [int](24 * $script:dpiScale))
$modeBasicRadio.ForeColor = $Colors.Text
$modeBasicRadio.Font = New-UiFont -Size 9.5 -Style ([Drawing.FontStyle]::Bold)
$modeBasicRadio.Checked = $true
$modeBasicRadio.FlatStyle = [Windows.Forms.FlatStyle]::Flat

$modeSegmentRadio = New-Object Windows.Forms.RadioButton
$modeSegmentRadio.Text = 'Video Segments'
$modeSegmentRadio.Location = New-Object Drawing.Point([int](240 * $script:dpiScale), [int](6 * $script:dpiScale))
$modeSegmentRadio.Size = New-Object Drawing.Size([int](200 * $script:dpiScale), [int](24 * $script:dpiScale))
$modeSegmentRadio.ForeColor = $Colors.Text
$modeSegmentRadio.Font = New-UiFont -Size 9.5 -Style ([Drawing.FontStyle]::Bold)
$modeSegmentRadio.FlatStyle = [Windows.Forms.FlatStyle]::Flat

$modePanel.Controls.AddRange(@($modeBasicRadio, $modeSegmentRadio))

# ===========================================================================
#  BASIC MODE PANEL
# ===========================================================================

$basicPanel = New-Object Windows.Forms.Panel
$basicPanel.Location = New-Object Drawing.Point([int](0 * $script:dpiScale), [int](100 * $script:dpiScale))
$basicPanel.Size = New-Object Drawing.Size([int](776 * $script:dpiScale), [int](420 * $script:dpiScale))
$basicPanel.Anchor = 'Top,Left,Right'
$basicPanel.BackColor = [Drawing.Color]::Transparent

# -- Drop Zone --
$dropZone = New-Object Windows.Forms.Panel
$dropZone.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](8 * $script:dpiScale))
$dropZone.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](120 * $script:dpiScale))
$dropZone.Anchor = 'Top,Left,Right'
$dropZone.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
$dropZone.Cursor = [Windows.Forms.Cursors]::Hand
$dropZone.AllowDrop = $true
Add-PanelBorder -Control $dropZone -Dashed

$dropIcon = New-Label -TextValue 'UPLOAD' -X 0 -Y 16 -Width 696 -Height 22 -ForeColor $Colors.Accent1 -Size 10 -Style ([Drawing.FontStyle]::Bold)
$dropIcon.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$dropText = New-Label -TextValue 'Drag and drop media files here or browse' -X 0 -Y 42 -Width 696 -Height 24 -ForeColor $Colors.Text -Size 10.5
$dropText.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$dropHint = New-Label -TextValue 'Supports GIF, PNG, JPG, MP4, MOV, AVI, WEBM' -X 0 -Y 70 -Width 696 -Height 20 -ForeColor $Colors.Muted -Size 8.5
$dropHint.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$dropZone.Controls.AddRange(@($dropIcon, $dropText, $dropHint))

$fileButton = New-Object Windows.Forms.Button
$fileButton.Text = $Text.FileSelect
$fileButton.Location = New-Object Drawing.Point([int](286 * $script:dpiScale), [int](12 * $script:dpiScale))
$fileButton.Size = New-Object Drawing.Size([int](124 * $script:dpiScale), [int](32 * $script:dpiScale))
$fileButton.Visible = $false

# -- Quality / Output row --
$qualityLabel = New-Label -TextValue 'Conversion Quality' -X 40 -Y 152 -Width 220 -Height 20 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)
$qualityCombo = New-Object Windows.Forms.ComboBox
$qualityCombo.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](176 * $script:dpiScale))
$qualityCombo.Size = New-Object Drawing.Size([int](220 * $script:dpiScale), [int](30 * $script:dpiScale))
$qualityCombo.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$qualityCombo.BackColor = $Colors.PanelSoft
$qualityCombo.ForeColor = $Colors.Text
$qualityCombo.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$qualityCombo.Font = New-UiFont -Size 9
[void]$qualityCombo.Items.Add('High Quality (q80)')
[void]$qualityCombo.Items.Add('Ultra Quality (q90)')
[void]$qualityCombo.Items.Add('Lossless')
$qualityCombo.SelectedIndex = 0

$outputLabel = New-Label -TextValue 'Output Folder' -X 284 -Y 152 -Width 452 -Height 20 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)
$outputBox = New-Object Windows.Forms.TextBox
$outputBox.Text = $DefaultOutputDir
$outputBox.Location = New-Object Drawing.Point([int](284 * $script:dpiScale), [int](177 * $script:dpiScale))
$outputBox.Size = New-Object Drawing.Size([int](332 * $script:dpiScale), [int](24 * $script:dpiScale))
$outputBox.Anchor = 'Top,Left,Right'
$outputBox.BackColor = $Colors.PanelSoft
$outputBox.ForeColor = $Colors.Text
$outputBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$outputBox.Font = New-UiFont -Size 9

$outputButton = New-Object Windows.Forms.Button
$outputButton.Text = 'Change'
$outputButton.Location = New-Object Drawing.Point([int](626 * $script:dpiScale), [int](175 * $script:dpiScale))
$outputButton.Size = New-Object Drawing.Size([int](110 * $script:dpiScale), [int](30 * $script:dpiScale))
$outputButton.Anchor = 'Top,Right'
Set-FlatButtonStyle -Button $outputButton -BackColor ([Drawing.ColorTranslator]::FromHtml('#1f2937')) -ForeColor $Colors.Text -BorderColor $Colors.Border

# -- Files panel --
$filesPanel = New-Object Windows.Forms.Panel
$filesPanel.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](228 * $script:dpiScale))
$filesPanel.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](130 * $script:dpiScale))
$filesPanel.Anchor = 'Top,Left,Right'
$filesPanel.BackColor = $Colors.PanelSoft
Add-PanelBorder -Control $filesPanel

$fileCountLabel = New-Label -TextValue 'Selected Files (0)' -X 16 -Y 10 -Width 260 -Height 22 -ForeColor $Colors.Muted -Size 9 -Style ([Drawing.FontStyle]::Bold)
$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = 'Clear all'
$clearButton.Location = New-Object Drawing.Point([int](594 * $script:dpiScale), [int](8 * $script:dpiScale))
$clearButton.Size = New-Object Drawing.Size([int](86 * $script:dpiScale), [int](25 * $script:dpiScale))
$clearButton.Anchor = 'Top,Right'
$clearButton.Visible = $false
Set-FlatButtonStyle -Button $clearButton -BackColor $Colors.PanelSoft -ForeColor $Colors.Muted -BorderColor $Colors.PanelSoft

$fileList = New-Object Windows.Forms.ListBox
$fileList.Location = New-Object Drawing.Point([int](16 * $script:dpiScale), [int](38 * $script:dpiScale))
$fileList.Size = New-Object Drawing.Size([int](664 * $script:dpiScale), [int](80 * $script:dpiScale))
$fileList.Anchor = 'Top,Left,Right'
$fileList.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
$fileList.ForeColor = $Colors.Text
$fileList.BorderStyle = [Windows.Forms.BorderStyle]::None
$fileList.HorizontalScrollbar = $true
$fileList.Font = New-UiFont -Size 9
$filesPanel.Controls.AddRange(@($fileCountLabel, $clearButton, $fileList))

# -- Convert button --
$convertButton = New-Object Windows.Forms.Button
$convertButton.Text = 'Start Conversion'
$convertButton.Location = New-Object Drawing.Point([int](268 * $script:dpiScale), [int](376 * $script:dpiScale))
$convertButton.Size = New-Object Drawing.Size([int](240 * $script:dpiScale), [int](42 * $script:dpiScale))
$convertButton.Anchor = 'Top'
$convertButton.Enabled = $false
Set-FlatButtonStyle -Button $convertButton -BackColor $Colors.Accent2 -ForeColor $Colors.Text -BorderColor $Colors.Accent2
$convertButton.FlatAppearance.MouseOverBackColor = $Colors.Accent1
$convertButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#b91c5c')

$basicPanel.Controls.AddRange(@(
    $dropZone,
    $fileButton,
    $qualityLabel,
    $qualityCombo,
    $outputLabel,
    $outputBox,
    $outputButton,
    $filesPanel,
    $convertButton
))

# ===========================================================================
#  SEGMENT MODE PANEL
# ===========================================================================

$segmentPanel = New-Object Windows.Forms.Panel
$segmentPanel.Location = New-Object Drawing.Point([int](0 * $script:dpiScale), [int](100 * $script:dpiScale))
$segmentPanel.Size = New-Object Drawing.Size([int](776 * $script:dpiScale), [int](520 * $script:dpiScale))
$segmentPanel.Anchor = 'Top,Left,Right'
$segmentPanel.BackColor = [Drawing.Color]::Transparent
$segmentPanel.Visible = $false

# -- Video Source Section --
$segSourceLabel = New-Label -TextValue 'Video Source' -X 40 -Y 8 -Width 696 -Height 20 -ForeColor $Colors.Teal -Size 9 -Style ([Drawing.FontStyle]::Bold)

$segVideoUrlBox = New-Object Windows.Forms.TextBox
$segVideoUrlBox.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](32 * $script:dpiScale))
$segVideoUrlBox.Size = New-Object Drawing.Size([int](460 * $script:dpiScale), [int](26 * $script:dpiScale))
$segVideoUrlBox.Anchor = 'Top,Left,Right'
$segVideoUrlBox.BackColor = $Colors.PanelSoft
$segVideoUrlBox.ForeColor = $Colors.Text
$segVideoUrlBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$segVideoUrlBox.Font = New-UiFont -Size 9
$segVideoUrlBox.Text = ''

# Placeholder hint via GotFocus/LostFocus
$segVideoUrlPlaceholder = 'Enter video file path or direct URL...'
$segVideoUrlBox.Text = $segVideoUrlPlaceholder
$segVideoUrlBox.ForeColor = $Colors.Muted
$segVideoUrlBox.Add_GotFocus({
    if ($segVideoUrlBox.Text -eq $segVideoUrlPlaceholder) {
        $segVideoUrlBox.Text = ''
        $segVideoUrlBox.ForeColor = $Colors.Text
    }
})
$segVideoUrlBox.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($segVideoUrlBox.Text)) {
        $segVideoUrlBox.Text = $segVideoUrlPlaceholder
        $segVideoUrlBox.ForeColor = $Colors.Muted
    }
})

$segBrowseButton = New-Object Windows.Forms.Button
$segBrowseButton.Text = 'Browse...'
$segBrowseButton.Location = New-Object Drawing.Point([int](510 * $script:dpiScale), [int](30 * $script:dpiScale))
$segBrowseButton.Size = New-Object Drawing.Size([int](100 * $script:dpiScale), [int](30 * $script:dpiScale))
$segBrowseButton.Anchor = 'Top,Right'
Set-FlatButtonStyle -Button $segBrowseButton -BackColor ([Drawing.ColorTranslator]::FromHtml('#1f2937')) -ForeColor $Colors.Text -BorderColor $Colors.Border

$segLoadButton = New-Object Windows.Forms.Button
$segLoadButton.Text = 'Load Video'
$segLoadButton.Location = New-Object Drawing.Point([int](620 * $script:dpiScale), [int](30 * $script:dpiScale))
$segLoadButton.Size = New-Object Drawing.Size([int](116 * $script:dpiScale), [int](30 * $script:dpiScale))
$segLoadButton.Anchor = 'Top,Right'
Set-FlatButtonStyle -Button $segLoadButton -BackColor $Colors.Teal -ForeColor $Colors.Text -BorderColor $Colors.Teal
$segLoadButton.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#0d9488')
$segLoadButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#0f766e')

$videoInfoLabel = New-Label -TextValue 'No video loaded' -X 40 -Y 66 -Width 696 -Height 18 -ForeColor $Colors.Muted -Size 8.5

# -- Timeline Trackbar --
$segTimelineLabel = New-Label -TextValue 'Timeline' -X 40 -Y 92 -Width 696 -Height 18 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)

$segTrackbar = New-Object Windows.Forms.TrackBar
$segTrackbar.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](112 * $script:dpiScale))
$segTrackbar.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](30 * $script:dpiScale))
$segTrackbar.Anchor = 'Top,Left,Right'
$segTrackbar.Minimum = 0
$segTrackbar.Maximum = 1000
$segTrackbar.TickFrequency = 100
$segTrackbar.BackColor = $Colors.Panel
$segTrackbar.Enabled = $false

$segTrackbarTimeLabel = New-Label -TextValue '00:00:00.000' -X 40 -Y 140 -Width 150 -Height 18 -ForeColor $Colors.Text -Size 8.5
$segTrackbarTimeLabel.Font = New-Object Drawing.Font('Consolas', 9)

# -- Start / End Time Controls --
$segTimingPanel = New-Object Windows.Forms.Panel
$segTimingPanel.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](164 * $script:dpiScale))
$segTimingPanel.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](36 * $script:dpiScale))
$segTimingPanel.Anchor = 'Top,Left,Right'
$segTimingPanel.BackColor = [Drawing.Color]::Transparent

$segStartLabel = New-Label -TextValue 'Start:' -X 0 -Y 5 -Width 40 -Height 20 -ForeColor $Colors.Muted -Size 9
$segStartBox = New-Object Windows.Forms.TextBox
$segStartBox.Location = New-Object Drawing.Point([int](42 * $script:dpiScale), [int](2 * $script:dpiScale))
$segStartBox.Size = New-Object Drawing.Size([int](120 * $script:dpiScale), [int](24 * $script:dpiScale))
$segStartBox.BackColor = $Colors.PanelSoft
$segStartBox.ForeColor = $Colors.Text
$segStartBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$segStartBox.Font = New-Object Drawing.Font('Consolas', 9.5)
$segStartBox.Text = '00:00:00.000'

$segSetStartButton = New-Object Windows.Forms.Button
$segSetStartButton.Text = 'Set Start'
$segSetStartButton.Location = New-Object Drawing.Point([int](170 * $script:dpiScale), [int](0 * $script:dpiScale))
$segSetStartButton.Size = New-Object Drawing.Size([int](76 * $script:dpiScale), [int](28 * $script:dpiScale))
Set-FlatButtonStyle -Button $segSetStartButton -BackColor ([Drawing.ColorTranslator]::FromHtml('#1f2937')) -ForeColor $Colors.Text -BorderColor $Colors.Border

$segEndLabel = New-Label -TextValue 'End:' -X 264 -Y 5 -Width 36 -Height 20 -ForeColor $Colors.Muted -Size 9
$segEndBox = New-Object Windows.Forms.TextBox
$segEndBox.Location = New-Object Drawing.Point([int](300 * $script:dpiScale), [int](2 * $script:dpiScale))
$segEndBox.Size = New-Object Drawing.Size([int](120 * $script:dpiScale), [int](24 * $script:dpiScale))
$segEndBox.BackColor = $Colors.PanelSoft
$segEndBox.ForeColor = $Colors.Text
$segEndBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$segEndBox.Font = New-Object Drawing.Font('Consolas', 9.5)
$segEndBox.Text = '00:00:00.000'

$segSetEndButton = New-Object Windows.Forms.Button
$segSetEndButton.Text = 'Set End'
$segSetEndButton.Location = New-Object Drawing.Point([int](428 * $script:dpiScale), [int](0 * $script:dpiScale))
$segSetEndButton.Size = New-Object Drawing.Size([int](76 * $script:dpiScale), [int](28 * $script:dpiScale))
Set-FlatButtonStyle -Button $segSetEndButton -BackColor ([Drawing.ColorTranslator]::FromHtml('#1f2937')) -ForeColor $Colors.Text -BorderColor $Colors.Border

$segTimingPanel.Controls.AddRange(@($segStartLabel, $segStartBox, $segSetStartButton, $segEndLabel, $segEndBox, $segSetEndButton))

# -- Segment Action Buttons --
$segActionPanel = New-Object Windows.Forms.Panel
$segActionPanel.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](208 * $script:dpiScale))
$segActionPanel.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](36 * $script:dpiScale))
$segActionPanel.Anchor = 'Top,Left,Right'
$segActionPanel.BackColor = [Drawing.Color]::Transparent

$segAddButton = New-Object Windows.Forms.Button
$segAddButton.Text = 'Add Segment'
$segAddButton.Location = New-Object Drawing.Point([int](0 * $script:dpiScale), [int](0 * $script:dpiScale))
$segAddButton.Size = New-Object Drawing.Size([int](120 * $script:dpiScale), [int](30 * $script:dpiScale))
Set-FlatButtonStyle -Button $segAddButton -BackColor $Colors.Success -ForeColor $Colors.Text -BorderColor $Colors.Success
$segAddButton.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#059669')
$segAddButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#047857')

$segRemoveButton = New-Object Windows.Forms.Button
$segRemoveButton.Text = 'Remove Segment'
$segRemoveButton.Location = New-Object Drawing.Point([int](134 * $script:dpiScale), [int](0 * $script:dpiScale))
$segRemoveButton.Size = New-Object Drawing.Size([int](138 * $script:dpiScale), [int](30 * $script:dpiScale))
Set-FlatButtonStyle -Button $segRemoveButton -BackColor $Colors.Danger -ForeColor $Colors.Text -BorderColor $Colors.Danger
$segRemoveButton.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#dc2626')
$segRemoveButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#b91c1c')

$segPreviewButton = New-Object Windows.Forms.Button
$segPreviewButton.Text = 'Preview Segment'
$segPreviewButton.Location = New-Object Drawing.Point([int](286 * $script:dpiScale), [int](0 * $script:dpiScale))
$segPreviewButton.Size = New-Object Drawing.Size([int](140 * $script:dpiScale), [int](30 * $script:dpiScale))
Set-FlatButtonStyle -Button $segPreviewButton -BackColor $Colors.Purple -ForeColor $Colors.Text -BorderColor $Colors.Purple
$segPreviewButton.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#9333ea')
$segPreviewButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#7e22ce')

$segActionPanel.Controls.AddRange(@($segAddButton, $segRemoveButton, $segPreviewButton))

# -- Segment List (ListView) --
$segListLabel = New-Label -TextValue 'Segments' -X 40 -Y 250 -Width 696 -Height 20 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)

$segmentListView = New-Object Windows.Forms.ListView
$segmentListView.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](272 * $script:dpiScale))
$segmentListView.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](110 * $script:dpiScale))
$segmentListView.Anchor = 'Top,Left,Right'
$segmentListView.View = [Windows.Forms.View]::Details
$segmentListView.FullRowSelect = $true
$segmentListView.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
$segmentListView.ForeColor = $Colors.Text
$segmentListView.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$segmentListView.Font = New-Object Drawing.Font('Consolas', 9)
$segmentListView.HeaderStyle = [Windows.Forms.ColumnHeaderStyle]::Nonclickable
$segmentListView.GridLines = $true

[void]$segmentListView.Columns.Add('#', [int](36 * $script:dpiScale))
[void]$segmentListView.Columns.Add('Start', [int](120 * $script:dpiScale))
[void]$segmentListView.Columns.Add('End', [int](120 * $script:dpiScale))
[void]$segmentListView.Columns.Add('Duration', [int](80 * $script:dpiScale))
[void]$segmentListView.Columns.Add('Output', [int](320 * $script:dpiScale))

# -- Segment Quality / Output --
$segQualityLabel = New-Label -TextValue 'Conversion Quality' -X 40 -Y 394 -Width 220 -Height 20 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)
$segQualityCombo = New-Object Windows.Forms.ComboBox
$segQualityCombo.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](418 * $script:dpiScale))
$segQualityCombo.Size = New-Object Drawing.Size([int](220 * $script:dpiScale), [int](30 * $script:dpiScale))
$segQualityCombo.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$segQualityCombo.BackColor = $Colors.PanelSoft
$segQualityCombo.ForeColor = $Colors.Text
$segQualityCombo.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$segQualityCombo.Font = New-UiFont -Size 9
[void]$segQualityCombo.Items.Add('High Quality (q80)')
[void]$segQualityCombo.Items.Add('Ultra Quality (q90)')
[void]$segQualityCombo.Items.Add('Lossless')
$segQualityCombo.SelectedIndex = 0

$segOutputLabel = New-Label -TextValue 'Output Folder' -X 284 -Y 394 -Width 452 -Height 20 -ForeColor $Colors.Muted -Size 8.5 -Style ([Drawing.FontStyle]::Bold)
$segOutputBox = New-Object Windows.Forms.TextBox
$segOutputBox.Text = $DefaultOutputDir
$segOutputBox.Location = New-Object Drawing.Point([int](284 * $script:dpiScale), [int](419 * $script:dpiScale))
$segOutputBox.Size = New-Object Drawing.Size([int](332 * $script:dpiScale), [int](24 * $script:dpiScale))
$segOutputBox.Anchor = 'Top,Left,Right'
$segOutputBox.BackColor = $Colors.PanelSoft
$segOutputBox.ForeColor = $Colors.Text
$segOutputBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$segOutputBox.Font = New-UiFont -Size 9

$segOutputButton = New-Object Windows.Forms.Button
$segOutputButton.Text = 'Change'
$segOutputButton.Location = New-Object Drawing.Point([int](626 * $script:dpiScale), [int](417 * $script:dpiScale))
$segOutputButton.Size = New-Object Drawing.Size([int](110 * $script:dpiScale), [int](30 * $script:dpiScale))
$segOutputButton.Anchor = 'Top,Right'
Set-FlatButtonStyle -Button $segOutputButton -BackColor ([Drawing.ColorTranslator]::FromHtml('#1f2937')) -ForeColor $Colors.Text -BorderColor $Colors.Border

# -- Segment Convert Button --
$segConvertButton = New-Object Windows.Forms.Button
$segConvertButton.Text = 'Convert Segments'
$segConvertButton.Location = New-Object Drawing.Point([int](268 * $script:dpiScale), [int](464 * $script:dpiScale))
$segConvertButton.Size = New-Object Drawing.Size([int](240 * $script:dpiScale), [int](42 * $script:dpiScale))
$segConvertButton.Anchor = 'Top'
$segConvertButton.Enabled = $false
Set-FlatButtonStyle -Button $segConvertButton -BackColor $Colors.Accent2 -ForeColor $Colors.Text -BorderColor $Colors.Accent2
$segConvertButton.FlatAppearance.MouseOverBackColor = $Colors.Accent1
$segConvertButton.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#b91c5c')

$segmentPanel.Controls.AddRange(@(
    $segSourceLabel,
    $segVideoUrlBox,
    $segBrowseButton,
    $segLoadButton,
    $videoInfoLabel,
    $segTimelineLabel,
    $segTrackbar,
    $segTrackbarTimeLabel,
    $segTimingPanel,
    $segActionPanel,
    $segListLabel,
    $segmentListView,
    $segQualityLabel,
    $segQualityCombo,
    $segOutputLabel,
    $segOutputBox,
    $segOutputButton,
    $segConvertButton
))

# ===========================================================================
#  SHARED BOTTOM SECTION (status, progress, log)
# ===========================================================================

$bottomPanel = New-Object Windows.Forms.Panel
$bottomPanel.Location = New-Object Drawing.Point([int](0 * $script:dpiScale), [int](620 * $script:dpiScale))
$bottomPanel.Size = New-Object Drawing.Size([int](776 * $script:dpiScale), [int](220 * $script:dpiScale))
$bottomPanel.Anchor = 'Bottom,Left,Right'
$bottomPanel.BackColor = [Drawing.Color]::Transparent

$statusLabel = New-Label -TextValue ('{0}: {1}' -f $Text.Status, $Text.Ready) -X 40 -Y 0 -Width 536 -Height 20 -ForeColor $Colors.Muted -Size 8.5
$statusLabel.Anchor = 'Top,Left,Right'

$progressTextLabel = New-Label -TextValue '0%' -X 676 -Y 0 -Width 60 -Height 20 -ForeColor $Colors.Muted -Size 8.5
$progressTextLabel.Anchor = 'Top,Right'
$progressTextLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight

$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](24 * $script:dpiScale))
$progressBar.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](9 * $script:dpiScale))
$progressBar.Anchor = 'Top,Left,Right'
$progressBar.Style = [Windows.Forms.ProgressBarStyle]::Continuous

$resultBox = New-Object Windows.Forms.RichTextBox
$resultBox.Multiline = $true
$resultBox.ReadOnly = $true
$resultBox.ScrollBars = 'Vertical'
$resultBox.BorderStyle = [Windows.Forms.BorderStyle]::None
$resultBox.Location = New-Object Drawing.Point([int](40 * $script:dpiScale), [int](42 * $script:dpiScale))
$resultBox.Size = New-Object Drawing.Size([int](696 * $script:dpiScale), [int](170 * $script:dpiScale))
$resultBox.Anchor = 'Top,Bottom,Left,Right'
$resultBox.BackColor = [Drawing.ColorTranslator]::FromHtml('#05070d')
$resultBox.ForeColor = $Colors.Muted
$resultBox.Font = New-Object Drawing.Font('Consolas', 8)

$bottomPanel.Controls.AddRange(@(
    $statusLabel,
    $progressTextLabel,
    $progressBar,
    $resultBox
))

# ===========================================================================
#  Assemble into main panel
# ===========================================================================

$panel.Controls.AddRange(@(
    $titleLabel,
    $modePanel,
    $basicPanel,
    $segmentPanel,
    $bottomPanel
))

$form.Controls.Add($panel)

# ===========================================================================
#  MODE SWITCHING
# ===========================================================================

function Switch-Mode {
    param([string]$Mode)

    $script:currentMode = $Mode

    if ($Mode -eq 'basic') {
        $basicPanel.Visible = $true
        $segmentPanel.Visible = $false
    }
    else {
        $basicPanel.Visible = $false
        $segmentPanel.Visible = $true
    }
}

$modeBasicRadio.Add_CheckedChanged({
    if ($modeBasicRadio.Checked) {
        Switch-Mode -Mode 'basic'
    }
})

$modeSegmentRadio.Add_CheckedChanged({
    if ($modeSegmentRadio.Checked) {
        Switch-Mode -Mode 'segment'
    }
})

# ===========================================================================
#  RESIZE HANDLER
# ===========================================================================

$panel.Add_Resize({
    $titleLabel.Width = $panel.ClientSize.Width

    # Mode panel
    $modePanel.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)

    # Basic panel
    $basicPanel.Width = $panel.ClientSize.Width
    $dropZone.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $dropIcon.Width = $dropZone.ClientSize.Width
    $dropText.Width = $dropZone.ClientSize.Width
    $dropHint.Width = $dropZone.ClientSize.Width
    $outputBox.Width = $panel.ClientSize.Width - [int](444 * $script:dpiScale)
    $outputButton.Left = $panel.ClientSize.Width - [int](150 * $script:dpiScale)
    $filesPanel.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $clearButton.Left = $filesPanel.ClientSize.Width - [int](102 * $script:dpiScale)
    $fileList.Width = $filesPanel.ClientSize.Width - [int](32 * $script:dpiScale)
    $convertButton.Left = [Math]::Max([int](40 * $script:dpiScale), [int](($panel.ClientSize.Width - $convertButton.Width) / 2))

    # Segment panel
    $segmentPanel.Width = $panel.ClientSize.Width
    $segVideoUrlBox.Width = $panel.ClientSize.Width - [int](316 * $script:dpiScale)
    $segBrowseButton.Left = $panel.ClientSize.Width - [int](266 * $script:dpiScale)
    $segLoadButton.Left = $panel.ClientSize.Width - [int](156 * $script:dpiScale)
    $videoInfoLabel.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $segTrackbar.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $segTimingPanel.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $segActionPanel.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $segmentListView.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $segOutputBox.Width = $panel.ClientSize.Width - [int](444 * $script:dpiScale)
    $segOutputButton.Left = $panel.ClientSize.Width - [int](150 * $script:dpiScale)
    $segConvertButton.Left = [Math]::Max([int](40 * $script:dpiScale), [int](($panel.ClientSize.Width - $segConvertButton.Width) / 2))

    # Bottom panel
    $bottomPanel.Width = $panel.ClientSize.Width
    $statusLabel.Width = $panel.ClientSize.Width - [int](200 * $script:dpiScale)
    $progressTextLabel.Left = $panel.ClientSize.Width - [int](100 * $script:dpiScale)
    $progressBar.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
    $resultBox.Width = $panel.ClientSize.Width - [int](80 * $script:dpiScale)
})

# ===========================================================================
#  BASIC MODE EVENT HANDLERS
# ===========================================================================

$qualityCombo.Add_SelectedIndexChanged({
    switch ($qualityCombo.SelectedIndex) {
        0 { $script:selectedQuality = 'q80' }
        1 { $script:selectedQuality = 'q90' }
        2 { $script:selectedQuality = 'lossless' }
    }
})

$dropZone.Add_Click({ Open-FilePicker })
$dropText.Add_Click({ Open-FilePicker })
$dropHint.Add_Click({ Open-FilePicker })
$dropIcon.Add_Click({ Open-FilePicker })
$fileButton.Add_Click({ Open-FilePicker })

$dropZone.Add_DragEnter({
    param($sender, $eventArgs)

    if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
        $script:dropZoneHover = $true
        $dropZone.BackColor = [Drawing.ColorTranslator]::FromHtml('#1f1624')
        $dropZone.Invalidate()
    }
})

$dropZone.Add_DragLeave({
    $script:dropZoneHover = $false
    $dropZone.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
    $dropZone.Invalidate()
})

$dropZone.Add_DragDrop({
    param($sender, $eventArgs)

    $script:dropZoneHover = $false
    $dropZone.BackColor = [Drawing.ColorTranslator]::FromHtml('#111827')
    $dropZone.Invalidate()
    $files = [string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    Add-SelectedFiles -Files $files
})

$outputButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Text.PickOutputFolder
    $dialog.SelectedPath = $outputBox.Text

    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $outputBox.Text = $dialog.SelectedPath
    }
})

$clearButton.Add_Click({
    $script:selectedFiles = @()
    Update-FileUi
})

$convertButton.Add_Click({
    if ($script:selectedFiles.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($form, $Text.SelectFileFirst, $Text.Title, 'OK', 'Information')
        return
    }

    $outputDir = $outputBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputDir)) {
        [void][Windows.Forms.MessageBox]::Show($form, $Text.PickOutputFolder, $Text.Title, 'OK', 'Warning')
        return
    }

    Set-Busy -Busy $true
    $progressBar.Value = 0
    $progressBar.Maximum = $script:selectedFiles.Count
    $progressTextLabel.Text = '0%'
    $resultBox.Clear()
    Add-Log -Message 'Initializing conversion engine...'
    Add-Log -Message ('Starting conversion of {0} file(s)...' -f $script:selectedFiles.Count)

    $successCount = 0
    $failedCount = 0

    foreach ($file in $script:selectedFiles) {
        $statusLabel.Text = 'Processing: {0}' -f [IO.Path]::GetFileName($file)
        [Windows.Forms.Application]::DoEvents()

        try {
            $result = Invoke-WebPConversion -InputPath $file -OutputDir $outputDir -Quality $script:selectedQuality
            $successCount++
            Add-Log -Message ('SUCCESS: {0} -> {1}' -f [IO.Path]::GetFileName($file), $result.Output) -Type 'success'
        }
        catch {
            $failedCount++
            Add-Log -Message ('ERROR: {0}' -f [IO.Path]::GetFileName($file)) -Type 'error'
            Add-Log -Message ($_.Exception.Message.Trim()) -Type 'error'
        }

        if ($progressBar.Value -lt $progressBar.Maximum) {
            $progressBar.Value = $progressBar.Value + 1
        }
        $progressTextLabel.Text = '{0}%' -f [Math]::Round(($progressBar.Value / $progressBar.Maximum) * 100)
        [Windows.Forms.Application]::DoEvents()
    }

    $statusLabel.Text = 'Completed: {0} successful, {1} failed.' -f $successCount, $failedCount
    Add-Log -Message 'All tasks completed.'
    Set-Busy -Busy $false

    [void][Windows.Forms.MessageBox]::Show(
        $form,
        ('{0}: {1}{2}{3}: {4}' -f $Text.Success, $successCount, [Environment]::NewLine, $Text.Failed, $failedCount),
        $Text.Done,
        'OK',
        'Information'
    )
})

# ===========================================================================
#  SEGMENT MODE EVENT HANDLERS
# ===========================================================================

# -- Browse for video file --
$segBrowseButton.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select a video file'
    $dialog.Multiselect = $false
    $dialog.Filter = 'Video files|*.mp4;*.mov;*.avi;*.mkv;*.webm;*.flv;*.wmv;*.ts|All files|*.*'

    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $segVideoUrlBox.Text = $dialog.FileName
        $segVideoUrlBox.ForeColor = $Colors.Text
    }
})

# -- Load Video --
$segLoadButton.Add_Click({
    $source = $segVideoUrlBox.Text.Trim()
    if ($source -eq $segVideoUrlPlaceholder -or [string]::IsNullOrWhiteSpace($source)) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Please enter a video file path or direct video URL.', 'No Source', 'OK', 'Warning')
        return
    }

    $srcType = Test-VideoSource -Source $source
    if ($srcType -eq $null) {
        [void][Windows.Forms.MessageBox]::Show($form,
            "Could not find the specified source.`nFor local files, verify the path exists.`nFor URLs, use a direct video URL (http/https) — site pages like YouTube are unsupported in V1.",
            'Invalid Source', 'OK', 'Warning')
        return
    }

    $statusLabel.Text = 'Loading video information...'
    [Windows.Forms.Application]::DoEvents()

    # The actual source that ffprobe/ffmpeg/ffplay will use.
    # For local files and direct URLs, this equals $source.
    # For page URLs (YouTube etc.), yt-dlp resolves the real stream URL.
    $effectiveSource = $source

    try {
        $info = $null
        $usedYtDlp = $false

        if ($srcType -eq 'url') {
            # Try ffprobe directly first
            $probeOk = $false
            try {
                $info = Invoke-FfprobeMediaInfo -Source $source
                $probeOk = $true
            } catch {
                $probeOk = $false
            }

            if (-not $probeOk) {
                # Ffprobe failed — try yt-dlp to resolve a stream URL
                $statusLabel.Text = 'Resolving video URL via yt-dlp...'
                [Windows.Forms.Application]::DoEvents()
                Add-Log -Message 'Direct probe failed, trying yt-dlp...'

                $streamUrl = Resolve-YtDlpStreamUrl -PageUrl $source
                $effectiveSource = $streamUrl
                $usedYtDlp = $true

                $statusLabel.Text = 'Probing resolved stream...'
                [Windows.Forms.Application]::DoEvents()
                $info = Invoke-FfprobeMediaInfo -Source $effectiveSource
            }
        }
        else {
            # Local file — probe directly
            $info = Invoke-FfprobeMediaInfo -Source $source
        }

        $script:videoSource = $source
        $script:resolvedSource = $effectiveSource
        $script:videoSourceType = $srcType
        $script:videoMediaInfo = $info
        $script:segments = @()
        Update-VideoInfoDisplay
        Update-SegmentListView
        $statusLabel.Text = 'Video loaded successfully.'
        $logSource = if ($usedYtDlp) { '{0} (resolved via yt-dlp)' -f $source } else { $source }
        Add-Log -Message ('Video loaded: {0} ({1})' -f $logSource, (Format-SegmentTime -Seconds $info.Duration)) -Type 'success'
    }
    catch {
        $script:videoSource = ''
        $script:resolvedSource = ''
        $script:videoSourceType = $null
        $script:videoMediaInfo = $null
        Update-VideoInfoDisplay
        $statusLabel.Text = 'Failed to load video.'
        Add-Log -Message ('LOAD ERROR: {0}' -f $_.Exception.Message) -Type 'error'
        [void][Windows.Forms.MessageBox]::Show($form,
            $_.Exception.Message,
            'Load Failed', 'OK', 'Error')
    }
})

# -- Trackbar scroll updates time display --
$segTrackbar.Add_Scroll({
    if ($script:videoMediaInfo -ne $null) {
        $secs = $segTrackbar.Value / 10.0
        $segTrackbarTimeLabel.Text = Format-SegmentTime -Seconds $secs
    }
})

# -- Set Start from trackbar --
$segSetStartButton.Add_Click({
    if ($script:videoMediaInfo -ne $null) {
        $secs = $segTrackbar.Value / 10.0
        $segStartBox.Text = Format-SegmentTime -Seconds $secs
    }
})

# -- Set End from trackbar --
$segSetEndButton.Add_Click({
    if ($script:videoMediaInfo -ne $null) {
        $secs = $segTrackbar.Value / 10.0
        $segEndBox.Text = Format-SegmentTime -Seconds $secs
    }
})

# -- Add Segment --
$segAddButton.Add_Click({
    if ($script:videoMediaInfo -eq $null) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Load a video first.', 'No Video', 'OK', 'Warning')
        return
    }

    try {
        $startSec = Convert-TimeSpanText -Text $segStartBox.Text
        $endSec   = Convert-TimeSpanText -Text $segEndBox.Text
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Invalid Time', 'OK', 'Warning')
        return
    }

    if ($endSec -le $startSec) {
        [void][Windows.Forms.MessageBox]::Show($form, 'End time must be greater than start time.', 'Invalid Range', 'OK', 'Warning')
        return
    }

    $mediaDur = $script:videoMediaInfo.Duration
    if ($mediaDur -gt 0) {
        if ($startSec -ge $mediaDur) {
            [void][Windows.Forms.MessageBox]::Show($form,
                ('Start time ({0:F1}s) exceeds video duration ({1:F1}s).' -f $startSec, $mediaDur),
                'Out of Range', 'OK', 'Warning')
            return
        }
        if ($endSec -gt ($mediaDur + 0.5)) {
            [void][Windows.Forms.MessageBox]::Show($form,
                ('End time ({0:F1}s) exceeds video duration ({1:F1}s).' -f $endSec, $mediaDur),
                'Out of Range', 'OK', 'Warning')
            return
        }
    }

    $script:segments += @{ Start = $startSec; End = $endSec }
    Update-SegmentListView
    Add-Log -Message ('Segment {0} added: {1} - {2}' -f $script:segments.Count, (Format-SegmentTime -Seconds $startSec), (Format-SegmentTime -Seconds $endSec))
})

# -- Remove Segment --
$segRemoveButton.Add_Click({
    if ($segmentListView.SelectedIndices.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Select a segment to remove.', 'No Selection', 'OK', 'Information')
        return
    }

    $idx = $segmentListView.SelectedIndices[0]
    $newSegments = @()
    for ($i = 0; $i -lt $script:segments.Count; $i++) {
        if ($i -ne $idx) { $newSegments += $script:segments[$i] }
    }
    $script:segments = $newSegments
    Update-SegmentListView
    Add-Log -Message ('Segment {0} removed.' -f ($idx + 1))
})

# -- Preview Segment --
$segPreviewButton.Add_Click({
    if ($script:videoMediaInfo -eq $null -or [string]::IsNullOrWhiteSpace($script:videoSource)) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Load a video first.', 'No Video', 'OK', 'Warning')
        return
    }

    # Use selected segment if available, otherwise use the start/end boxes
    $startSec = 0.0
    $endSec = 0.0

    if ($segmentListView.SelectedIndices.Count -gt 0) {
        $idx = $segmentListView.SelectedIndices[0]
        $seg = $script:segments[$idx]
        $startSec = $seg.Start
        $endSec = $seg.End
    }
    else {
        try {
            $startSec = Convert-TimeSpanText -Text $segStartBox.Text
            $endSec   = Convert-TimeSpanText -Text $segEndBox.Text
        }
        catch {
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Invalid Time', 'OK', 'Warning')
            return
        }
    }

    $dur = $endSec - $startSec
    if ($dur -le 0) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Preview duration must be positive.', 'Invalid Range', 'OK', 'Warning')
        return
    }

    try {
        Invoke-SegmentPreview -Source $script:resolvedSource -StartSeconds $startSec -Duration $dur
        Add-Log -Message ('Preview: {0} - {1}' -f (Format-SegmentTime -Seconds $startSec), (Format-SegmentTime -Seconds $endSec))
    }
    catch {
        Add-Log -Message ('Preview error: {0}' -f $_.Exception.Message) -Type 'error'
    }
})

# -- Segment Quality Combo --
$segQualityCombo.Add_SelectedIndexChanged({
    # No need for a separate variable; we read from the combo at conversion time
})

# -- Segment Output Folder --
$segOutputButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Text.PickOutputFolder
    $dialog.SelectedPath = $segOutputBox.Text

    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $segOutputBox.Text = $dialog.SelectedPath
    }
})

# -- Convert Segments --
$segConvertButton.Add_Click({
    if ($script:segments.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Add at least one segment before converting.', 'No Segments', 'OK', 'Information')
        return
    }

    if ($script:videoMediaInfo -eq $null -or [string]::IsNullOrWhiteSpace($script:videoSource)) {
        [void][Windows.Forms.MessageBox]::Show($form, 'Load a video first.', 'No Video', 'OK', 'Warning')
        return
    }

    $outputDir = $segOutputBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputDir)) {
        [void][Windows.Forms.MessageBox]::Show($form, $Text.PickOutputFolder, $Text.Title, 'OK', 'Warning')
        return
    }

    # Determine quality from segment combo
    $segQuality = switch ($segQualityCombo.SelectedIndex) {
        0 { 'q80' }
        1 { 'q90' }
        2 { 'lossless' }
        default { 'q80' }
    }

    Set-Busy -Busy $true
    $progressBar.Value = 0
    $progressBar.Maximum = $script:segments.Count
    $progressTextLabel.Text = '0%'
    $resultBox.Clear()
    Add-Log -Message 'Initializing segment conversion engine...'
    Add-Log -Message ('Starting conversion of {0} segment(s)...' -f $script:segments.Count)

    $successCount = 0
    $failedCount = 0

    for ($i = 0; $i -lt $script:segments.Count; $i++) {
        $seg = $script:segments[$i]
        $segIdx = $i + 1
        $statusLabel.Text = 'Processing segment {0} of {1}...' -f $segIdx, $script:segments.Count
        [Windows.Forms.Application]::DoEvents()

        try {
            $result = Invoke-WebPSegmentConversion `
                -Source $script:resolvedSource `
                -SourceType $script:videoSourceType `
                -OutputDir $outputDir `
                -Quality $segQuality `
                -StartSeconds $seg.Start `
                -EndSeconds $seg.End `
                -SegmentIndex $segIdx

            $successCount++
            Add-Log -Message ('SUCCESS: segment {0:D3} {1}-{2} -> {3}' -f $segIdx,
                (Format-SegmentTime -Seconds $seg.Start),
                (Format-SegmentTime -Seconds $seg.End),
                $result.Output) -Type 'success'
        }
        catch {
            $failedCount++
            Add-Log -Message ('ERROR: segment {0:D3} {1}-{2}' -f $segIdx,
                (Format-SegmentTime -Seconds $seg.Start),
                (Format-SegmentTime -Seconds $seg.End)) -Type 'error'
            Add-Log -Message ($_.Exception.Message.Trim()) -Type 'error'
        }

        if ($progressBar.Value -lt $progressBar.Maximum) {
            $progressBar.Value = $progressBar.Value + 1
        }
        $progressTextLabel.Text = '{0}%' -f [Math]::Round(($progressBar.Value / $progressBar.Maximum) * 100)
        [Windows.Forms.Application]::DoEvents()
    }

    $statusLabel.Text = 'Completed: {0} successful, {1} failed.' -f $successCount, $failedCount
    Add-Log -Message 'All segment tasks completed.'
    Set-Busy -Busy $false

    [void][Windows.Forms.MessageBox]::Show(
        $form,
        ('{0}: {1}{2}{3}: {4}' -f $Text.Success, $successCount, [Environment]::NewLine, $Text.Failed, $failedCount),
        $Text.Done,
        'OK',
        'Information'
    )
})

# ===========================================================================
#  INIT AND SHOW
# ===========================================================================

Update-FileUi

if ($UiSelfTest) {
    Write-Output 'UiSelfTest OK'
    exit 0
}

[void]$form.ShowDialog()
