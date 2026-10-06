<#
.SYNOPSIS
  Boot the VMBus drill kernel as a disposable Gen2 Hyper-V guest and capture
  its serial console.

.DESCRIPTION
  Builds a 128 MiB FAT32 ESP VHDX holding only \EFI\BOOT\BOOTX64.EFI, defines
  a Gen2 Hyper-V VM around it with a COM1 named pipe, boots, streams the
  console until the guest prints HYPERV_DRILL_DONE, then deletes the VM and
  the VHDX.

  This is a capability-and-drill harness, not a production host path. It never
  runs on the daily WSL2 host (guard below), never activates swap, never
  applies memory pressure to the host, and never changes RamShared lifecycle
  state. The only mutation is a VM that exists for the length of the job.

.PARAMETER BzImage
  Path to the bootable drill bzImage (built by build-hyperv-drill-kernel.sh).

.PARAMETER WorkDir
  Scratch directory for the VHDX and logs. Defaults to .\drill-vm-work.

.PARAMETER VmName
  Hyper-V VM name. Defaults to vmbus-drill-$PID.

.PARAMETER TimeoutSec
  Maximum wall-clock to wait for the guest to finish. Default 1200.

  The backstop preserves time for slow disposable guests. Earlier runs
  reached lifecycle phase one and then produced no more console progress.
  The cause is unproven: timeout alone does not distinguish descheduling,
  a guest wait, pressure or a blocked reader. Independent observer
  heartbeats record VM state and console progress for that investigation.

.EXAMPLE
  ./new-hyperv-drill-vm.ps1 -BzImage ./drill-out/BOOTX64.EFI
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BzImage,

  [string]$WorkDir = (Join-Path (Get-Location) 'drill-vm-work'),

  [string]$VmName = "vmbus-drill-$PID",

  [int]$TimeoutSec = 1200,

  [int]$MemoryMB = 2048,

  [int]$CpuCount = 2,

  [switch]$HostRescind,

  [ValidateSet('Observe', 'RequirePass', 'ExpectedBaselineFailure')]
  [string]$VerdictPolicy = 'Observe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'host-rescind.ps1')

function Note($k, $v) {
  '{0}={1}' -f $k, $v | Tee-Object -FilePath $script:report -Append
  Write-Host "DRILL-VM $k=$v"
}

function AsText($raw) {
  if ($null -eq $raw) { return '' }
  $s = ($raw | Out-String)
  return (($s -replace "`0", '') -replace "\s+", ' ').Trim()
}

# --- host-safety guard -------------------------------------------------------
if (Test-Path '/proc/version') {
  $pv = ''
  try { $pv = Get-Content '/proc/version' -Raw } catch {}
  if ($pv -match 'microsoft-standard-WSL2') {
    Write-Host 'REFUSE: this is the daily WSL2 host. The drill guest must be a disposable Hyper-V VM.'
    exit 2
  }
}

if (-not $env:GITHUB_ACTIONS -and -not $env:HYPERV_DRILL_OK) {
  Write-Host 'REFUSE: set HYPERV_DRILL_OK=1 to confirm this is a disposable lab/CI host.'
  Write-Host 'This harness defines and deletes a Hyper-V VM. It must not run unattended on a shared machine.'
  exit 2
}

# --- inputs ------------------------------------------------------------------
if (-not (Test-Path $BzImage)) {
  Write-Host "ERROR: bzImage not found at $BzImage"
  exit 2
}
$BzImage = (Resolve-Path $BzImage).Path

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path $WorkDir).Path
$script:report = Join-Path $WorkDir 'drill-vm-report.txt'
$consoleLog = Join-Path $WorkDir 'drill-console.log'
$vhdPath = Join-Path $WorkDir 'drill-esp.vhdx'
$pipeName = "vmbus-drill-$PID"
$pipePath = "\\.\pipe\$pipeName"

Set-Content -Path $script:report -Value "DRILL-VM start $(Get-Date -Format o)"
Set-Content -Path $consoleLog -Value ''

Note runner $env:RUNNER_OS
Note bzimage_bytes (Get-Item $BzImage).Length
Note vm_name $VmName
Note pipe_path $pipePath
Note memory_mb $MemoryMB
Note cpu_count $CpuCount
Note timeout_sec $TimeoutSec

if (Test-Path $vhdPath) {
  Note esp_build refused_existing_vhdx
  Write-Host "REFUSE: refusing to overwrite an existing VHDX at $vhdPath"
  exit 2
}

# --- module preflight --------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
  Note hyperv_module unavailable
  Write-Host 'ERROR: Hyper-V PowerShell module is not available.'
  exit 1
}
Import-Module Hyper-V
Note hyperv_module imported

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
  Note new_vm_cmdlet unavailable
  Write-Host 'ERROR: New-VM cmdlet is not available.'
  exit 1
}
Note new_vm_cmdlet present
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
  Note vm_define refused_existing_vm
  Write-Host "REFUSE: refusing to modify an existing VM named $VmName"
  exit 2
}

# --- build the ESP VHDX ------------------------------------------------------
$vhd = $null
$mounted = $false
try {
  Note esp_build begin
  # Fixed 128 MiB: one kernel image, nothing else. Small enough to keep the
  # runner's C: footprint bounded and large enough for any bzImage we build.
  $vhd = New-VHD -Path $vhdPath -SizeBytes 128MB -Fixed
  $disk = $vhd | Mount-VHD -PassThru
  $mounted = $true
  Note esp_mounted_disk $disk.Number

  $disk | Initialize-Disk -PartitionStyle GPT -Confirm:$false

  # GptType is the EFI System Partition GUID. A plain data partition will not
  # be offered to the Gen2 UEFI firmware as a boot target.
  $ESP_GPT = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $part = New-Partition -DiskNumber $disk.Number -Size 100MB -AssignDriveLetter -GptType $ESP_GPT
  $vol = $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'DRILLESP' -Confirm:$false
  $esp = '{0}:\' -f $vol.DriveLetter
  Note esp_drive $esp

  New-Item -ItemType Directory -Force -Path (Join-Path $esp 'EFI\BOOT') | Out-Null
  Copy-Item $BzImage (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI') -Force

  $onEsp = Get-Item (Join-Path $esp 'EFI\BOOT\BOOTX64.EFI')
  Note esp_bootx64_bytes $onEsp.Length
  Note esp_bootx64_sha256 (Get-FileHash $onEsp.FullName -Algorithm SHA256).Hash

  Dismount-VHD -Path $vhdPath
  $mounted = $false
  Note esp_build ok
}
catch {
  Note esp_build ("failed: " + $_.Exception.Message)
  if ($mounted) {
    try { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue } catch {}
  }
  try { Remove-VHD -Path $vhdPath -Force -ErrorAction SilentlyContinue } catch {}
  if (Test-Path $vhdPath) {
    try { Remove-Item $vhdPath -Force -ErrorAction SilentlyContinue } catch {}
  }
  Write-Host "ERROR: could not build the ESP VHDX: $($_.Exception.Message)"
  exit 1
}

# --- define the guest --------------------------------------------------------
$vm = $null
$script:vmOwned = $false
$script:drillSwitchCreated = $false
try {
  Note vm_define begin
  $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vhdPath
  $script:vmOwned = $true
  Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled
  Set-VMProcessor -VMName $VmName -Count $CpuCount
  Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
  Set-VMComPort -VMName $VmName -Number 1 -Path $pipePath

  # One synthetic NIC. The lifecycle and fragmentation drills rebind it to
  # force a fresh ring allocation; without it neither drill can run. The NIC
  # does not need to reach anything: a netvsc device bound to a private switch
  # is enough for the rebind cycle.
  #
  # "Default Switch" exists on Windows client Hyper-V only. Hosted runners are
  # Windows Server, so a private switch is the normal path and the default
  # switch is the convenience.
  $switchName = $null
  foreach ($candidate in 'Default Switch', 'vmbus-drill-private') {
    if (Get-VMSwitch -Name $candidate -ErrorAction SilentlyContinue) {
      $switchName = $candidate
      break
    }
  }
  if (-not $switchName) {
    try {
      New-VMSwitch -Name 'vmbus-drill-private' -SwitchType Private -ErrorAction Stop | Out-Null
      $script:drillSwitchCreated = $true
      Note drill_switch created
      $switchName = 'vmbus-drill-private'
    }
    catch {
      Note drill_switch ("failed: " + $_.Exception.Message)
    }
  }
  else {
    Note drill_switch existing
  }

  Get-VMNetworkAdapter -VMName $VmName | Remove-VMNetworkAdapter -ErrorAction SilentlyContinue
  if ($switchName) {
    Add-VMNetworkAdapter -VMName $VmName -SwitchName $switchName -Name 'drill-nic'
    Note vm_network_adapter $switchName
  }
  else {
    Note vm_network_adapter none
  }

  Note vm_define ok
}
catch {
  Note vm_define ("failed: " + $_.Exception.Message)
  Write-Host "ERROR: could not define the VM: $($_.Exception.Message)"
  try {
    if ($script:vmOwned -and (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
      Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
      Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
    }
  }
  catch { Note early_vm_cleanup ("failed: " + $_.Exception.Message) }
  if ($script:drillSwitchCreated) {
    try { Remove-VMSwitch -Name 'vmbus-drill-private' -Force -ErrorAction SilentlyContinue } catch {}
  }
  $partialVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if (-not $partialVm) {
    try {
      Dismount-VHD -Path $vhdPath -Force -ErrorAction SilentlyContinue
      Remove-VHD -Path $vhdPath -Force -ErrorAction SilentlyContinue
    }
    catch { Note early_vhd_cleanup ("failed: " + $_.Exception.Message) }
    if (Test-Path $vhdPath) {
      try { Remove-Item $vhdPath -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  else {
    Note early_vhd_cleanup 'preserved because same-name VM ownership is unproven'
  }
  exit 1
}

# --- console reader ----------------------------------------------------------
# Hyper-V owns the named pipe as the server the moment the VM starts. The host
# connects as a client. Connecting before Start-VM would block with no server,
# so the reader runs on a thread job that blocks in Connect() and the VM start
# unblocks it. Doing it in that order keeps the earliest guest output.
$readerScript = {
  param($pipeName, $logPath, $timeoutSec)

  $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
  $pipe = $null
  for ($i = 0; $i -lt 30 -and -not $pipe; $i++) {
    try {
      $p = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.', $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::None)
      $p.Connect(10000)
      $pipe = $p
    }
    catch {
      try { $p.Dispose() } catch {}
      Start-Sleep -Milliseconds 500
    }
  }
  if (-not $pipe) {
    Add-Content -Path $logPath -Value 'DRILL-VM console_connect=failed'
    return 'CONNECT_FAILED'
  }
  Add-Content -Path $logPath -Value 'DRILL-VM console_connect=ok'

  # NamedPipeClientStream.ReadTimeout is not supported on every .NET this
  # harness runs on — the property setter throws "Timeouts are not supported
  # on this stream" and, with the default ErrorActionPreference, that error
  # becomes the job's whole output while a subsequent blocking Read parks the
  # loop until the outer Wait-Job kills it. Do not depend on the property.
  # ReadAsync + Wait(1000) gives a real deadline on every runtime and still
  # keeps a quiet guest from stalling the reader.
  $buf = New-Object byte[] 4096
  $pending = ''
  $seenDone = $false
  $readTask = $pipe.ReadAsync($buf, 0, $buf.Length)

  while ([DateTime]::UtcNow -lt $deadline -and -not $seenDone) {
    try {
      if (-not $readTask.Wait(1000)) { continue }
      $n = $readTask.Result
      if ($n -le 0) { break }
      $chunk = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
      # Drain the next chunk while file output runs. The immutable string
      # above no longer depends on the byte buffer reused by ReadAsync.
      $readTask = $pipe.ReadAsync($buf, 0, $buf.Length)
      $pending += $chunk
      Add-Content -Path $logPath -Value $chunk -NoNewline
      if ($pending -match 'HYPERV_DRILL_DONE') {
        $seenDone = $true
      }
    }
    catch {
      # A faulted read is the pipe closing under us. Record it and stop;
      # rethrowing here would lose everything already written to the log.
      Add-Content -Path $logPath -Value ("`nDRILL-VM console_read=error " + $_.Exception.Message)
      break
    }
  }

  try { $pipe.Dispose() } catch {}
  return $(if ($seenDone) { 'DONE' } else { 'TIMEOUT' })
}

$readerJob = $null
$readerStatus = 'NOT_STARTED'
try {
  if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $readerJob = Start-ThreadJob -ScriptBlock $readerScript -ArgumentList $pipeName, $consoleLog, $TimeoutSec
    Note reader_job threadjob
  }
  else {
    $readerJob = Start-Job -ScriptBlock $readerScript -ArgumentList $pipeName, $consoleLog, $TimeoutSec
    Note reader_job job
  }
}
catch {
  Note reader_job ("failed: " + $_.Exception.Message)
}

# --- boot --------------------------------------------------------------------
$booted = $false
try {
  Note vm_start begin
  Start-VM -Name $VmName -ErrorAction Stop
  $booted = $true
  Note vm_start ok
  Start-Sleep -Seconds 3
  Note vm_state (Get-VM -Name $VmName).State
}
catch {
  Note vm_start ("failed: " + $_.Exception.Message)
}

# --- wait for the guest ------------------------------------------------------
function Wait-DrillReader {
  param($Job, [int]$BudgetSec, [string]$Vm, [string]$ConsolePath,
        [switch]$Rescind, [guid]$ExpectedVmId)

  # This observer runs outside the serial reader. A blocked ReadAsync must
  # not suppress host progress evidence. No heartbeat implies no verdict;
  # it does not by itself identify starvation, guest OOM, or a kernel hang.
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $rescindAttempted = $false
  while ($watch.Elapsed.TotalSeconds -lt $BudgetSec) {
    $remaining = [Math]::Max(1, [Math]::Ceiling($BudgetSec - $watch.Elapsed.TotalSeconds))
    $finished = Wait-Job -Job $Job -Timeout ([Math]::Min(10, $remaining))
    if ($finished) { return $finished }

    $bytes = 0
    $phase = 'unknown'
    if (Test-Path $ConsolePath) {
      $bytes = (Get-Item $ConsolePath).Length
      $markers = Get-Content $ConsolePath -Tail 40 -ErrorAction SilentlyContinue |
        Select-String 'HYPERV_DRILL_PHASE name=([a-z_]+)'
      if ($markers) { $phase = $markers[-1].Matches[0].Groups[1].Value }
    }
    if ($Rescind -and -not $rescindAttempted -and (Test-Path $ConsolePath) -and
        (Select-String -Path $ConsolePath -Pattern '^HOST_RESCIND_READY relid=[0-9]+$' -Quiet)) {
      $rescindAttempted = $true
      try {
        Invoke-DrillHostRescind -VmName $Vm -ExpectedVmId $ExpectedVmId
        Note host_rescind 'adapter_removed' | Out-Null
      } catch { Note host_rescind ('failed: ' + $_.Exception.Message) | Out-Null }
    }
    try {
      $guest = Get-VM -Name $Vm -ErrorAction Stop
      $state = $guest.State
      $cpu = $guest.CPUUsage
      $memory = $guest.MemoryAssigned
    }
    catch { $state = 'unavailable'; $cpu = 'unknown'; $memory = 'unknown' }
    $elapsed = [Math]::Floor($watch.Elapsed.TotalSeconds)
    Note observer_heartbeat "elapsed_s=$elapsed reader=$($Job.State) console_bytes=$bytes phase=$phase vm_state=$state cpu_pct=$cpu memory_bytes=$memory" | Out-Null
  }
  return $null
}

if ($readerJob) {
  try {
    $finished = Wait-DrillReader -Job $readerJob -BudgetSec ($TimeoutSec + 30) -Vm $VmName -ConsolePath $consoleLog -Rescind:$HostRescind -ExpectedVmId $(if ($vm) { $vm.Id } else { [guid]::Empty })
    if ($finished) {
      $readerStatus = Receive-Job -Job $readerJob
    }
    else {
      $readerStatus = 'HOST_TIMEOUT'
      Stop-Job -Job $readerJob -ErrorAction SilentlyContinue
    }
    Note reader_status $readerStatus
  }
  catch {
    Note reader_status ("failed: " + $_.Exception.Message)
    $readerStatus = 'READER_ERROR'
  }
  finally {
    Remove-Job -Job $readerJob -Force -ErrorAction SilentlyContinue
  }
}

# --- console + verdict -------------------------------------------------------
$console = ''
if (Test-Path $consoleLog) { $console = Get-Content $consoleLog -Raw }
if (-not $console) { $console = '' }
$console = $console -replace "`0", ''

Write-Host '======== GUEST CONSOLE ========'
Write-Host $console
Write-Host '==============================='

# Verdict parse. A serial write of the verdict can be split by printk on the
# same port: run 36808657969 (windows-latest) captured
#   HYPERV_DRILL_RESULT[17.508] sysrq: Power Off
#    status=PARTIAL[17.512] ACPI: PM: Preparing to enter system sleep state S5
# so no single line carried both tokens and a per-line match reported
# NO_RESULT on a guest that had actually printed PARTIAL. The guest now emits
# the status line three times and drains the UART before poweroff; this side
# still prefers an intact line and only then rebuilds the verdict by stripping
# printk insertions. The captured value is constrained to the verdict
# vocabulary so a torn line can never be read as a status.
$verdict = 'NO_RESULT'
$verdict_source = 'intact_line'
$resultLine = ($console -split "`n" |
  Where-Object { $_ -match 'HYPERV_DRILL_RESULT status=' } |
  Select-Object -Last 1)
if ($resultLine -match 'HYPERV_DRILL_RESULT status=(PASS|PARTIAL|FAIL)') {
  $verdict = $Matches[1]
}
else {
  # Rebuild a verdict that printk split on the wire. Two kinds of insertion
  # land mid-line: a timestamped chunk (`[17.508] sysrq: Power Off` plus its
  # message up to end of line) and a bare poweroff printk with no timestamp
  # (`reboot: Power down` in run 36808657969). Strip both from the middle of
  # the stream -- the whole printk text, not just its timestamp -- then rejoin
  # a token printk tore in half (`HYPERV_DRIL` + `L_RESULT`) and collapse the
  # remaining whitespace so a verdict torn across two writes matches again.
  # The capture is anchored on HYPERV_DRILL_RESULT and constrained to the
  # verdict vocabulary, so the status= on the FRAGMENT and LIFECYCLE lines
  # can never be read as the result. No trailing boundary on the value: the
  # token rejoin above can leave the verdict glued to the next token
  # (`PARTIALHYPERV_DRILL_DONE`), and nothing in this output ever uses a
  # longer word that starts with PASS, PARTIAL or FAIL.
  $flat = $console -replace '\[\s*\d+\.\d+\][^\r\n]*', ''
  $flat = $flat -replace '(?:sysrq: Power[^\r\n]*|reboot: Power down[^\r\n]*|ACPI: PM:[^\r\n]*)', ''
  $flat = $flat -replace '(?<=[A-Z_])\s+(?=[A-Z_])', ''
  $flat = $flat -replace '\s+', ' '
  $flatMatches = [regex]::Matches(
    $flat, 'HYPERV_DRILL_RESULT\s+status=\s*(PASS|PARTIAL|FAIL)')
  if ($flatMatches.Count -gt 0) {
    $verdict = $flatMatches[$flatMatches.Count - 1].Groups[1].Value
    $verdict_source = 'printk_stripped'
    Note verdict_reconstructed printk_interleave
  }
}
if ($verdict -eq 'NO_RESULT') {
  $idx = $console.LastIndexOf('HYPERV_DRILL_RESULT')
  if ($idx -ge 0) {
    $tail = $console.Substring($idx, [Math]::Min(400, $console.Length - $idx))
    if ($tail -match 'status=(PASS|PARTIAL|FAIL)') {
      $verdict = $Matches[1]
      $verdict_source = 'status_token_window'
      Note verdict_reconstructed status_token_window
    }
    elseif ($tail -match '\b(PASS|PARTIAL|FAIL)\b') {
      $verdict = $Matches[1]
      $verdict_source = 'bare_token_window'
      Note verdict_reconstructed bare_token_window
    }
  }
}
Note drill_result $verdict
Note verdict_source $verdict_source
Note console_bytes $console.Length

# --- teardown ----------------------------------------------------------------
$cleanupOk = $true
try {
  $remainingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if ($script:vmOwned -and $remainingVm) {
    if ($booted) {
      Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    }
    Remove-VM -Name $VmName -Force -ErrorAction Stop
  }
  $remainingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if ($remainingVm) {
    $cleanupOk = $false
    if ($script:vmOwned) {
      Note vm_remove 'failed: VM remains registered after removal'
    }
    else {
      Note vm_remove 'failed: same-name VM was not created by this run and was preserved'
    }
  }
  elseif ($script:vmOwned) { Note vm_remove ok }
  else { Note vm_remove nothing_to_remove }
}
catch {
  $cleanupOk = $false
  Note vm_remove ("failed: " + $_.Exception.Message)
}

try {
  $remainingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if ($remainingVm -and (Test-Path $vhdPath)) {
    $cleanupOk = $false
    Note vhd_remove 'failed: VHDX preserved because the VM remains registered'
  }
  elseif (Test-Path $vhdPath) {
    try { Dismount-VHD -Path $vhdPath -Force -ErrorAction SilentlyContinue } catch {}
    Remove-Item $vhdPath -Force -ErrorAction Stop
  }
  if (Test-Path $vhdPath) {
    $cleanupOk = $false
    Note vhd_remove 'failed: VHDX remains on disk'
  }
  else { Note vhd_remove ok }
}
catch {
  $cleanupOk = $false
  Note vhd_remove ("failed: " + $_.Exception.Message)
}

# Remove only the private switch this run created. Existing switches are
# shared host infrastructure and remain untouched.
try {
  if ($script:drillSwitchCreated) {
    $sw = Get-VMSwitch -Name 'vmbus-drill-private' -ErrorAction SilentlyContinue
    if ($sw) {
      Remove-VMSwitch -Name 'vmbus-drill-private' -Force -ErrorAction Stop
    }
    if (Get-VMSwitch -Name 'vmbus-drill-private' -ErrorAction SilentlyContinue) {
      $cleanupOk = $false
      Note drill_switch_remove 'failed: switch remains registered after removal'
    }
    else { Note drill_switch_remove ok }
  }
  else { Note drill_switch_remove preserved_existing_or_not_created }
}
catch {
  $cleanupOk = $false
  Note drill_switch_remove ("failed: " + $_.Exception.Message)
}

if ($cleanupOk) {
  Note harness_cleanup PASS
}
else {
  Note harness_cleanup FAIL
}

# --- exit --------------------------------------------------------------------
Write-Host '---- drill-vm report ----'
Get-Content $script:report | Write-Host

# The selected policy decides whether an observed result can close this gate.
# The candidate path requires full PASS; the baseline path accepts only its
# exact, fault-free negative-control signature.
Import-Module (Join-Path $PSScriptRoot 'runtime-verdict-policy.psm1') -Force
$decision = Get-HypervDrillDecision `
  -Policy $VerdictPolicy `
  -Verdict $verdict `
  -ConsoleText $console
if (-not $cleanupOk) {
  Note runtime_policy_reason 'harness teardown did not prove resource removal'
  Note exit_code 1
  Note verdict $verdict
  exit 1
}
Note runtime_policy $VerdictPolicy
Note runtime_policy_reason $decision.Reason
Note exit_code $decision.ExitCode
Note verdict $verdict
exit $decision.ExitCode
