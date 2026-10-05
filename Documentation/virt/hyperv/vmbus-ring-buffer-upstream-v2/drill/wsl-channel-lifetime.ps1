# Ordinary command turnover on a disposable GitHub-hosted Windows runner.
# No pressure, NBD, RamShared daemon, rebind or injected disconnect.
# Baseline success means the expected defect was measured. Candidate success
# requires actual matching host acknowledgments and bounded physical backing.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KernelDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)]
    [ValidateSet('retention-baseline', 'ack-candidate')][string]$Variant,
    [string]$CandidateSourceCommit = $env:GITHUB_SHA
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'REFUSE: requires a disposable GitHub-hosted Windows runner'
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$KernelDirectory = (Resolve-Path $KernelDirectory).Path
$distro = 'vmbus-channel-lifetime-' + $env:GITHUB_RUN_ID + '-' + $Variant
$config = Join-Path $env:USERPROFILE '.wslconfig'
$priorConfig = if (Test-Path $config) { [IO.File]::ReadAllBytes($config) } else { $null }
$imported = $false
$importAttempted = $false
$configOwned = $false
$traceStarted = $false
$kernelScratch = $null
$script:sequence = 0
$report = [ordered]@{
    schema = 1; scope = 'ordinary-wsl-protocol'; variant = $Variant
    verdict = 'INCOMPLETE'; commands_completed = 0; cleanup_errors = @()
    phase = 'artifact-admission'
    complete_kernel_modules_pair = $false; confidential_transitions = $false
    harness_commit = $env:GITHUB_SHA
}

function Invoke-OwnedProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutSec = 30) {
    $script:sequence++
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $start
    $started = $false
    try {
        [void]$p.Start()
        $started = $true
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $p.Kill($true)
            [void]$p.WaitForExit(5000)
            throw "owned process query timed out after $TimeoutSec seconds"
        }
        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) {
            throw 'owned query output handles did not close within five seconds'
        }
        $text = $stdout.Result.Replace([string][char]0, '')
        $errors = $stderr.Result.Replace([string][char]0, '')
        [IO.File]::WriteAllText((Join-Path $OutputDirectory "command-$script:sequence.stdout"), $text)
        [IO.File]::WriteAllText((Join-Path $OutputDirectory "command-$script:sequence.stderr"), $errors)
        if ($p.ExitCode -ne 0) { throw "owned query exited $($p.ExitCode): $errors$text" }
        return $text
    } finally {
        if ($started) {
            if (-not $p.HasExited) {
                try { $p.Kill($true); [void]$p.WaitForExit(5000) } catch { }
                if (-not $p.HasExited) { $report.cleanup_errors += 'owned process exit unproven' }
            }
            foreach ($entry in @(@('stdout', $stdout), @('stderr', $stderr))) {
                $captured = if ($entry[1].IsCompletedSuccessfully) {
                    $entry[1].Result.Replace([string][char]0, '')
                } else { 'INCOMPLETE: output task did not finish' }
                [IO.File]::WriteAllText((Join-Path $OutputDirectory "command-$script:sequence.$($entry[0])"), $captured)
            }
        }
        $p.Dispose()
    }
}

function Invoke-Wsl([string[]]$Arguments, [int]$TimeoutSec = 30) {
    Invoke-OwnedProcess 'wsl.exe' $Arguments $TimeoutSec
}

function Read-Guest([string]$Command) {
    Invoke-Wsl @('-d', $distro, '-u', 'root', '--exec', '/bin/sh', '-c', $Command)
}

function ConvertFrom-WslSnapshot([string]$Text) {
    $result = @{}
    foreach ($line in $Text.Trim().Split([char]10)) {
        $kv = $line.Trim().Split('=', 2)
        if ($kv.Count -ne 2 -or $result.ContainsKey($kv[0])) {
            throw 'malformed or duplicate snapshot field'
        }
        $result[$kv[0]] = $kv[1]
    }
    foreach ($field in 'kernel', 'notes', 'boot', 'regions', 'pages', 'available_kib', 'close_errors') {
        if (-not $result.ContainsKey($field)) { throw "missing snapshot field $field" }
    }
    if ($result.Count -ne 7 -or $result.kernel -notmatch '^[A-Za-z0-9._+-]+$' -or
        $result.notes -cnotmatch '^[0-9a-f]{64}$' -or
        $result.boot -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        throw 'invalid snapshot identity'
    }
    foreach ($field in 'regions', 'pages', 'available_kib', 'close_errors') {
        if ($result[$field] -cnotmatch '^[0-9]+$') { throw "invalid numeric snapshot field $field" }
        $result[$field] = [int64]$result[$field]
    }
    return $result
}

function Read-Snapshot {
    $text = Read-Guest @'
set -eu
printf 'kernel='; uname -r
printf 'notes='; sha256sum /sys/kernel/notes | cut -d' ' -f1
printf 'boot='; cat /proc/sys/kernel/random/boot_id
awk '/vmbus_alloc_buffer[+]/ { regions++; for(i=1;i<=NF;i++) if($i ~ /^pages=/) { split($i,v,"="); pages+=v[2] } } END { print "regions=" regions+0; print "pages=" pages+0 }' /proc/vmallocinfo
awk '/MemAvailable:/ {print "available_kib=" $2}' /proc/meminfo
printf 'close_errors='; dmesg | grep -c 'Close failed: teardown gpadl return' || true
'@
    ConvertFrom-WslSnapshot $text
}

function Get-ProtocolEvidence([string]$Trace) {
    $counts = [regex]::Match($Trace, 'entries-in-buffer/entries-written:\s+(\d+)/(\d+)')
    if (-not $counts.Success -or $counts.Groups[1].Value -cne $counts.Groups[2].Value) {
        throw 'trace completeness unproven'
    }
    $requests = @([regex]::Matches($Trace, 'vmbus_teardown_gpadl: sending child_relid 0x[0-9a-f]+, gpadl (0x[0-9a-f]+), ret 0') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $acks = @([regex]::Matches($Trace, 'vmbus_ongpadl_torndown: gpadl (0x[0-9a-f]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    return @{
        requests = $requests.Count; acks = $acks.Count
        rescinds = [regex]::Matches($Trace, 'vmbus_onoffer_rescind:').Count
        unacknowledged = @($requests | Where-Object { $_ -notin $acks }).Count
    }
}

function Assert-LifetimeEvidence($Evidence, $Before, $First, $Last, [string]$Kind) {
    if ($Last.boot -cne $Before.boot -or $Last.notes -cne $Before.notes -or
        $Last.kernel -cne $Before.kernel) { throw 'guest identity changed' }
    if ($Last.available_kib -lt 262144) { throw 'insufficient guest headroom' }
    if ($Evidence.rescinds -lt 16) { throw 'insufficient ordinary rescind observation' }
    $delta = ($Last.pages - $Before.pages) * 4096
    $tail = ($Last.pages - $First.pages) * 4096
    if ($Kind -ceq 'ack-candidate') {
        if ($Last.close_errors -ne 0 -or $Evidence.requests -lt 16 -or
            $Evidence.unacknowledged -ne 0 -or $delta -gt 8388608 -or $tail -gt 4194304) {
            throw 'candidate acknowledgment or physical backing gate failed'
        }
    } elseif ($Kind -ceq 'retention-baseline') {
        if ($Last.close_errors -lt 16 -or $delta -lt 8388608) {
            throw 'baseline did not expose the expected retention defect'
        }
    } else { throw 'unknown evidence variant' }
    return @{ backing_delta_bytes = $delta; tail_delta_bytes = $tail }
}

function Assert-ArtifactManifest([string]$Directory) {
    $expected = @('kernel', 'config', 'kernel-notes.bin', 'source-sha.txt', 'kernel-release.txt', 'notes-sha256.txt')
    if (Test-Path (Join-Path $Directory 'modules.vhdx')) {
        $expected += @('modules.vhdx', 'modules.sha256')
    }
    $seen = @{}
    foreach ($line in Get-Content (Join-Path $Directory 'SHA256SUMS')) {
        if ($line -cnotmatch '^([0-9a-f]{64})  ([a-z0-9.-]+)$') { throw 'invalid artifact inventory' }
        $digest = $Matches[1]; $name = $Matches[2]
        if ($name -notin $expected -or $seen.ContainsKey($name)) { throw 'unexpected artifact inventory entry' }
        if ((Get-FileHash (Join-Path $Directory $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
            throw "artifact checksum mismatch: $name"
        }
        $seen[$name] = $true
    }
    if ($seen.Count -ne $expected.Count) { throw 'incomplete artifact inventory' }
}

try {
    Assert-ArtifactManifest $KernelDirectory
    $report.phase = 'platform-admission'
    $running = (Invoke-Wsl @('--list', '--running', '--quiet')).Trim()
    if ($running) { throw 'REFUSE: a running distro shares this runner VM' }
    $registered = Invoke-Wsl @('--list', '--quiet')
    if ($registered.Split([char]10).Trim() -contains $distro) {
        throw 'scratch distro name collision'
    }
    foreach ($feature in 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature
        if ($state.State -ne 'Enabled') {
            $enabled = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            if ($enabled.RestartNeeded) { throw "runner needs reboot for $feature" }
        }
    }
    $rootfs = Join-Path $env:RUNNER_TEMP 'channel-rootfs.tar.gz'
    $url = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.2-x86_64.tar.gz'
    Invoke-WebRequest $url -OutFile $rootfs -TimeoutSec 60
    $rootfsSha = (Get-FileHash $rootfs -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($rootfsSha -cne '412454ed98025ad9cd910d13f3d448b184e81502baa83180e89f98d0f13674be') {
        throw 'pinned rootfs digest mismatch'
    }
    $kernel = Join-Path $KernelDirectory 'kernel'
    $report.kernel_sha256 = (Get-FileHash $kernel -Algorithm SHA256).Hash.ToLowerInvariant()
    $report.source_commit = (Get-Content (Join-Path $KernelDirectory 'source-sha.txt') -Raw).Trim()
    $expectedNotes = (Get-Content (Join-Path $KernelDirectory 'notes-sha256.txt') -Raw).Trim()
    $expectedRelease = (Get-Content (Join-Path $KernelDirectory 'kernel-release.txt') -Raw).Trim()
    $expectedSource = if ($Variant -ceq 'retention-baseline') {
        'f67a72ca25a54b58b9ae9b8dbeaed9b3c017a0bc'
    } else { $CandidateSourceCommit }
    if ($report.source_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $report.source_commit -cne $expectedSource -or $expectedNotes -cnotmatch '^[0-9a-f]{64}$') {
        throw 'source or notes identity mismatch'
    }
    $report.config_sha256 = (Get-FileHash (Join-Path $KernelDirectory 'config') -Algorithm SHA256).Hash.ToLowerInvariant()
    $hasModules = Test-Path (Join-Path $KernelDirectory 'modules.vhdx')
    if ((Get-Content (Join-Path $KernelDirectory 'config') -Raw) -match '(?m)^CONFIG_MODULES=y$' -and -not $hasModules) {
        throw 'module-enabled kernel lacks its exact paired module artifact'
    }
    # Establish that this runner can boot the bundled WSL kernel first.
    # Failure here is platform evidence, not execution of the custom kernel.
    $report.phase = 'bundled-import'
    $selectedConfig = @('[wsl2]', 'memory=2GB', 'processors=2', 'swap=0', '') -join [Environment]::NewLine
    [IO.File]::WriteAllText($config, $selectedConfig)
    $configOwned = $true
    [void](Invoke-Wsl @('--shutdown'))
    $location = Join-Path $env:RUNNER_TEMP $distro
    $importAttempted = $true
    [void](Invoke-Wsl @('--import', $distro, $location, $rootfs, '--version', '2') 60)
    $imported = $true
    $report.phase = 'bundled-boot'
    $report.bundled_kernel = (Read-Guest 'uname -r').Trim()
    [void](Invoke-Wsl @('--terminate', $distro))
    [void](Invoke-Wsl @('--shutdown'))
    # Use an owned system-drive path, and test the same override with stock bytes.
    $kernelScratch = Join-Path $env:USERPROFILE ('channel-kernel-' + [guid]::NewGuid())
    New-Item -ItemType Directory $kernelScratch | Out-Null
    $stockKernel = Join-Path $env:ProgramFiles 'WSL/tools/kernel'
    if (Test-Path $stockKernel) {
        $report.phase = 'copied-bundled-boot'
        $stockCopy = Join-Path $kernelScratch 'bundled-kernel'
        Copy-Item $stockKernel $stockCopy
        $report.copied_bundled_sha256 = (Get-FileHash $stockCopy -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($report.copied_bundled_sha256 -cne (Get-FileHash $stockKernel -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'bundled control copy differs'
        }
        $stockConfigPath = $stockCopy.Replace('\', '/')
        $selectedConfig = @('[wsl2]', "kernel=$stockConfigPath", 'memory=2GB', 'processors=2', 'swap=0', '') -join [Environment]::NewLine
        [IO.File]::WriteAllText($config, $selectedConfig)
        $report.copied_bundled_kernel = (Read-Guest 'uname -r').Trim()
        if ($report.copied_bundled_kernel -cne $report.bundled_kernel) { throw 'bundled control release differs' }
        [void](Invoke-Wsl @('--terminate', $distro))
        [void](Invoke-Wsl @('--shutdown'))
    } else { $report.copied_bundled_control = 'UNAVAILABLE' }
    $kernelCopy = Join-Path $kernelScratch 'candidate-kernel'
    Copy-Item $kernel $kernelCopy
    if ((Get-FileHash $kernelCopy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $report.kernel_sha256) {
        throw 'selected kernel copy differs from the immutable artifact'
    }
    $report.phase = 'custom-boot'
    $configKernelPath = $kernelCopy.Replace('\', '/')
    $selectedConfig = @('[wsl2]', "kernel=$configKernelPath", 'memory=2GB', 'processors=2', 'swap=0', '') -join [Environment]::NewLine
    if ($hasModules) {
        $moduleCopy = Join-Path $kernelScratch 'modules.vhdx'
        Copy-Item (Join-Path $KernelDirectory 'modules.vhdx') $moduleCopy
        $moduleDigest = (Get-FileHash (Join-Path $KernelDirectory 'modules.vhdx') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ((Get-FileHash $moduleCopy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $moduleDigest) {
            throw 'paired module copy differs from the immutable artifact'
        }
        $moduleConfigPath = $moduleCopy.Replace('\', '/')
        $selectedConfig = @('[wsl2]', "kernel=$configKernelPath", "kernelModules=$moduleConfigPath", 'memory=2GB', 'processors=2', 'swap=0', '') -join [Environment]::NewLine
        $report.modules_vhdx_sha256 = $moduleDigest
    }
    [IO.File]::WriteAllText($config, $selectedConfig)
    [void](Read-Guest 'uname -r; test -d /sys/bus/vmbus/devices; test -r /proc/vmallocinfo')
    [void](Read-Guest @'
set -eu
t=/sys/kernel/tracing
mount -t tracefs tracefs "$t" 2>/dev/null || test -d "$t/events/hyperv"
mkdir "$t/instances/channel_lifetime"
t="$t/instances/channel_lifetime"
echo 0 > "$t/tracing_on"
echo 1024 > "$t/buffer_size_kb"
for e in vmbus_onoffer_rescind vmbus_teardown_gpadl vmbus_ongpadl_torndown; do echo 1 > "$t/events/hyperv/$e/enable"; done
echo 1 > "$t/tracing_on"
'@)
    $traceStarted = $true
    for ($i = 0; $i -lt 5; $i++) { [void](Read-Guest 'true') }
    Start-Sleep -Seconds 10
    $before = Read-Snapshot
    if ($before.notes -cne $expectedNotes -or $before.kernel -cne $expectedRelease) {
        throw 'running identity differs from the exact built artifact'
    }
    if ($hasModules) {
        $moduleInventory = Read-Guest 'cd "/lib/modules/$(uname -r)"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum'
        $expectedInventory = (Get-Content (Join-Path $KernelDirectory 'modules.sha256') -Raw).Replace("`r`n", "`n").Trim()
        if ($moduleInventory.Replace("`r`n", "`n").Trim() -cne $expectedInventory) {
            throw 'running module inventory differs from the exact pair'
        }
        $report.complete_kernel_modules_pair = $true
        $report.module_inventory_entries = $expectedInventory.Split([char]10).Count
    }
    $report.before = $before
    $report.phase = 'ordinary-turnover'
    if ($before.available_kib -lt 262144 -or
        ($Variant -ceq 'ack-candidate' -and $before.close_errors -ne 0)) {
        throw 'candidate warmup teardown or initial headroom gate failed'
    }
    foreach ($batch in 1, 2) {
        for ($i = 0; $i -lt 32; $i++) {
            [void](Read-Guest 'true')
            $report.commands_completed++
        }
        Start-Sleep -Seconds 10
        $sample = Read-Snapshot
        $report["batch_$batch"] = $sample
        if ($sample.boot -cne $before.boot -or $sample.notes -cne $expectedNotes -or
            $sample.kernel -cne $expectedRelease) {
            throw 'guest changed during ordinary command turnover'
        }
        if ([int64]$sample.available_kib -lt 262144) {
            throw 'headroom gate refused further turnover'
        }
        if ($Variant -eq 'ack-candidate' -and [int64]$sample.close_errors -ne 0) {
            throw 'candidate ordinary teardown failed'
        }
    }
    $trace = Read-Guest 'echo 0 > /sys/kernel/tracing/instances/channel_lifetime/tracing_on; cat /sys/kernel/tracing/instances/channel_lifetime/trace'
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'protocol-trace.log'), $trace)
    $journal = Read-Guest 'dmesg'
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'kernel.log'), $journal)
    if ($journal -match 'BUG:|Oops:|Kernel panic|hung_task|watchdog: BUG|Out of memory: Killed process|Write-error on swap-device') {
        throw 'kernel fatal or failed-swap signature observed'
    }
    $evidence = Get-ProtocolEvidence $trace
    foreach ($key in $evidence.Keys) { $report[$key] = $evidence[$key] }
    $growth = Assert-LifetimeEvidence $evidence $before $report.batch_1 $sample $Variant
    foreach ($key in $growth.Keys) { $report[$key] = $growth[$key] }
    $report.verdict = 'PASS'
} catch {
    $report.verdict = 'FAIL'
    $report.error = $_.Exception.Message
    $report.failure_phase = $report.phase
} finally {
    try {
        $native = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); events = @() }
        $native.computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 8 | Select-Object HypervisorPresent, TotalPhysicalMemory
        $native.processor = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 8 | Select-Object VMMonitorModeExtensions, SecondLevelAddressTranslationExtensions, VirtualizationFirmwareEnabled)
        foreach ($log in 'Microsoft-Windows-Hyper-V-Compute-Admin', 'Microsoft-Windows-Lxss/Operational') {
            try {
                $native.events += @(Get-WinEvent -FilterHashtable @{LogName = $log; StartTime = (Get-Date).AddMinutes(-10)} -MaxEvents 6 -ErrorAction Stop | ForEach-Object {
                    @{ log = $log; id = $_.Id; level = $_.LevelDisplayName; message = $_.Message.Substring(0, [Math]::Min(1600, $_.Message.Length)) }
                })
            } catch { $native.events += @{log = $log; query_error = $_.Exception.Message} }
        }
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'native-platform.json'), ($native | ConvertTo-Json -Depth 6))
    } catch { $report.native_diagnostic_error = $_.Exception.Message }
    if ($importAttempted -and -not $imported) {
        try {
            $registered = Invoke-Wsl @('--list', '--quiet')
            $imported = $registered.Split([char]10).Trim() -contains $distro
        } catch { $report.cleanup_errors += $_.Exception.Message }
    }
    if ($imported) {
        $captures = @{ 'kernel.log' = 'dmesg'; 'meminfo.log' = 'cat /proc/meminfo' }
        if ($traceStarted) {
            $captures['protocol-trace.log'] = 'echo 0 > /sys/kernel/tracing/instances/channel_lifetime/tracing_on; cat /sys/kernel/tracing/instances/channel_lifetime/trace'
        }
        foreach ($name in $captures.Keys) {
            try {
                $capture = Read-Guest $captures[$name]
                [IO.File]::WriteAllText((Join-Path $OutputDirectory $name), $capture)
            } catch { $report.cleanup_errors += $_.Exception.Message }
        }
        try { [void](Invoke-Wsl @('--terminate', $distro)) } catch { $report.cleanup_errors += $_.Exception.Message }
        try { [void](Invoke-Wsl @('--unregister', $distro)) } catch { $report.cleanup_errors += $_.Exception.Message }
        try { [void](Invoke-Wsl @('--shutdown')) } catch { $report.cleanup_errors += $_.Exception.Message }
    }
    $configRestored = -not $configOwned
    if ($configOwned) {
        try {
        if (-not (Test-Path $config) -or [IO.File]::ReadAllText($config) -cne $selectedConfig) {
            $report.cleanup_errors += 'configuration changed concurrently; preserved current bytes'
        } elseif ($null -ne $priorConfig) {
            [IO.File]::WriteAllBytes($config, $priorConfig)
            $configRestored = $true
        } else {
            Remove-Item $config
            $configRestored = $true
        }
        } catch { $report.cleanup_errors += $_.Exception.Message }
    }
    if ($kernelScratch -and $configRestored -and $report.cleanup_errors.Count -eq 0) {
        try { Remove-Item -LiteralPath $kernelScratch -Recurse -Force } catch { $report.cleanup_errors += $_.Exception.Message }
    } elseif ($kernelScratch) { $report.kernel_scratch_retained = $true }
    if ($report.cleanup_errors.Count -gt 0) { $report.verdict = 'FAIL' }
    $json = $report | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'report.json'), $json)
    Write-Output $json
}
if ($report.verdict -cne 'PASS') { exit 1 }
