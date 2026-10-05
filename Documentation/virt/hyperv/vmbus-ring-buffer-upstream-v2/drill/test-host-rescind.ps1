$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'host-rescind.ps1')
$script:expected = [guid]::NewGuid()
$script:guestId = $script:expected
$script:count = 1
$script:name = 'drill-nic'
$script:adapterId = $script:expected
$script:effects = 0
$script:fail = $false
function Get-VM { param($Name, $ErrorAction); [pscustomobject]@{ Id=$script:guestId } }
function Get-VMNetworkAdapter {
 param($VM, $ErrorAction)
 for ($i=0; $i -lt $script:count; $i++) {
  [pscustomobject]@{ Name=$script:name; VMId=$script:adapterId }
 }
}
function Remove-VMNetworkAdapter {
 param($VMNetworkAdapter, $Confirm, $ErrorAction)
 if ($script:fail) { throw 'effect failed' }
 if ($VMNetworkAdapter.Name -cne 'drill-nic' -or $VMNetworkAdapter.VMId -ne $script:expected) { throw 'wrong effect object' }
 $script:effects++; $script:count=0
}
function Expect-Refusal([string]$Case) {
 $refused=$false
 try { Invoke-DrillHostRescind -VmName fixture -ExpectedVmId $script:expected } catch { $refused=$true }
 if (-not $refused -or $script:effects -ne 0) { throw "$Case admitted effect" }
 Write-Output "PASS $Case"
}
$script:guestId=[guid]::NewGuid(); Expect-Refusal vm_guid_changed
$script:guestId=$script:expected; $script:count=2; Expect-Refusal multiple_adapters
$script:count=0; Expect-Refusal no_adapter
$script:count=1; $script:name='foreign'; Expect-Refusal wrong_adapter_name
$script:name='drill-nic'; $script:adapterId=[guid]::NewGuid(); Expect-Refusal wrong_adapter_vm
$script:adapterId=$script:expected; $script:fail=$true; Expect-Refusal removal_failure
$script:fail=$false
Invoke-DrillHostRescind -VmName fixture -ExpectedVmId $script:expected
if ($script:effects -ne 1 -or $script:count -ne 0) { throw 'valid removal failed' }
Write-Output 'PASS exact_adapter_removed_once'
