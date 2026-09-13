[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 900,
    [int]$TargetFrames = 24,
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

$sources = @(
    (Join-Path $PSScriptRoot 'tb_refresh_sweep.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/frame_read_write.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/frame_fifo_write.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v'),
    (Join-Path $PSScriptRoot 'rfifo_32_32_512.v'),
    (Join-Path $PSScriptRoot 'wfifo_32_32_512.v'),
    (Join-Path $PSScriptRoot 'sdram_model_refresh.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/video_delay.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/video_timing_data.v'),
    (Join-Path $root 'fpga/osd_display/rtl/vendor/SD/color_bar.v')
)
$includeDir = Join-Path $root 'fpga/osd_display/rtl/vendor/SD'
$matrix = @(
    [pscustomobject]@{ Stall = 1;  Depth = 512;  Bits = 9 },
    [pscustomobject]@{ Stall = 2;  Depth = 512;  Bits = 9 },
    [pscustomobject]@{ Stall = 4;  Depth = 512;  Bits = 9 },
    [pscustomobject]@{ Stall = 8;  Depth = 512;  Bits = 9 },
    [pscustomobject]@{ Stall = 16; Depth = 512;  Bits = 9 },
    [pscustomobject]@{ Stall = 16; Depth = 1024; Bits = 10 },
    [pscustomobject]@{ Stall = 16; Depth = 4096; Bits = 12 }
)
$allCaseNames = @($matrix | ForEach-Object { "refresh_stall_$($_.Stall)_depth_$($_.Depth)" })
$summaryPath = Join-Path $resultDir 'summary.csv'
$previousSummary = @()
if (($Only.Count -ne 0) -and (Test-Path $summaryPath)) {
    $previousSummary = @(Import-Csv $summaryPath)
    $matrix = @($matrix | Where-Object {
        "refresh_stall_$($_.Stall)_depth_$($_.Depth)" -in $Only
    })
    $unknownNames = @($Only | Where-Object { $_ -notin $allCaseNames })
    if ($unknownNames.Count -ne 0) {
        throw "Unknown case name(s): $($unknownNames -join ', ')"
    }
}

function Convert-ResultLine {
    param([string]$Line)
    $values = [ordered]@{}
    foreach ($token in ($Line -split ' ' | Select-Object -Skip 1)) {
        $pair = $token -split '=', 2
        if ($pair.Count -eq 2) { $values[$pair[0]] = $pair[1] }
    }
    return $values
}

$summary = @()
$runs = @()
foreach ($case in $matrix) {
    $name = "refresh_stall_$($case.Stall)_depth_$($case.Depth)"
    $image = Join-Path $resultDir "$name.out"
    $compileLog = Join-Path $resultDir "$name.compile.log"
    $runLog = Join-Path $resultDir "$name.log"
    Write-Host "[$name] compiling"

    $compileArgs = @(
        '-g2012', '-s', 'tb_refresh_sweep', '-I', $includeDir,
        '-o', $image,
        '-P', "tb_refresh_sweep.FIFO_DEPTH=$($case.Depth)",
        '-P', "tb_refresh_sweep.FIFO_LEVEL_BITS=$($case.Bits)",
        '-P', "tb_refresh_sweep.REFRESH_STALL_CYCLES=$($case.Stall)",
        '-P', "tb_refresh_sweep.TARGET_FRAMES=$TargetFrames"
    ) + $sources
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $compileOutput = & iverilog @compileArgs 2>&1
    $compileExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorAction
    $compileOutput | Set-Content -Encoding utf8 $compileLog
    if ($compileExitCode -ne 0) {
        $summary += [pscustomobject]@{ Name=$name; Status='COMPILE_ERROR'; Completed=''; Frames=''; FifoDepth=$case.Depth; Stall=$case.Stall; RawUnderflow=''; Episodes=''; FramesWithUnderflow=''; Dropped=''; SchedulerStuck=''; MaxFifoUsed=''; Log=$compileLog }
        continue
    }

    $stdout = Join-Path $resultDir "$name.stdout.tmp"
    $stderr = Join-Path $resultDir "$name.stderr.tmp"
    $process = Start-Process -FilePath 'vvp' -ArgumentList @($image) -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $runs += [pscustomobject]@{
        Name = $name; Case = $case; Image = $image; RunLog = $runLog
        Stdout = $stdout; Stderr = $stderr; Process = $process
        Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        Done = $false; TimedOut = $false
    }
    Write-Host "[$name] started pid=$($process.Id)"
}

while (@($runs | Where-Object { -not $_.Done }).Count -ne 0) {
    foreach ($run in @($runs | Where-Object { -not $_.Done })) {
        $run.Process.Refresh()
        if ($run.Process.HasExited) {
            $run.Process.WaitForExit()
            $run.Done = $true
            Write-Host "[$($run.Name)] finished"
        } elseif ([DateTime]::UtcNow -ge $run.Deadline) {
            $run.Process.Kill()
            $run.Process.WaitForExit()
            $run.Done = $true
            $run.TimedOut = $true
            Write-Host "[$($run.Name)] timed out"
        }
    }
    if (@($runs | Where-Object { -not $_.Done }).Count -ne 0) {
        Start-Sleep -Seconds 1
    }
}

foreach ($run in $runs) {
    $content = @()
    if (Test-Path $run.Stdout) { $content += Get-Content $run.Stdout }
    if (Test-Path $run.Stderr) { $content += Get-Content $run.Stderr }
    $content | Set-Content -Encoding utf8 $run.RunLog
    Remove-Item -LiteralPath $run.Stdout, $run.Stderr -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $run.Image -Force -ErrorAction SilentlyContinue

    $resultLine = $content | Where-Object { $_ -like 'RESULT *' } | Select-Object -Last 1
    if ($run.TimedOut) {
        $status = 'PROCESS_TIMEOUT'
        $values = @{}
    } elseif (-not $resultLine) {
        $status = 'NO_RESULT'
        $values = @{}
    } else {
        $status = 'OK'
        $values = Convert-ResultLine $resultLine
    }
    $summary += [pscustomobject]@{
        Name=$run.Name; Status=$status; Completed=$values.completed;
        Frames=$values.frames; FifoDepth=$run.Case.Depth; Stall=$run.Case.Stall;
        RawUnderflow=$values.total_raw_underflow;
        Episodes=$values.total_underflow_episodes;
        FramesWithUnderflow=$values.frames_with_underflow;
        Dropped=$values.dropped_commands;
        SchedulerStuck=$values.scheduler_stuck;
        MaxFifoUsed=$values.max_fifo_used; Log=$run.RunLog
    }
}

if ($Only.Count -ne 0) {
    $completedNames = @($summary | ForEach-Object { $_.Name })
    $summary = @($previousSummary | Where-Object { $_.Name -notin $completedNames }) + $summary
    $summary = @($summary | Sort-Object { [array]::IndexOf($allCaseNames, $_.Name) })
}
$summary | Export-Csv -NoTypeInformation -Encoding utf8 $summaryPath
$summary | Format-Table Name,Status,Frames,FifoDepth,Stall,RawUnderflow,Episodes,FramesWithUnderflow,Dropped,SchedulerStuck,MaxFifoUsed -AutoSize
Write-Host "Summary: $summaryPath"

if ($summary.Status | Where-Object { $_ -ne 'OK' }) { exit 1 }
