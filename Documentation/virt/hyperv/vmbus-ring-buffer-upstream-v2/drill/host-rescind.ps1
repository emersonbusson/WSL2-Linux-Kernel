# Acts only on the sole adapter of the disposable VM created by this run.
function Invoke-DrillHostRescind {
  param([string]$VmName, [guid]$ExpectedVmId)
  if ($ExpectedVmId -eq [guid]::Empty) { throw 'VM identity unavailable' }
  $guest = Get-VM -Name $VmName -ErrorAction Stop
  if ($guest.Id -ne $ExpectedVmId) { throw 'VM identity changed' }
  $adapters = @(Get-VMNetworkAdapter -VM $guest -ErrorAction Stop)
  if ($adapters.Count -ne 1 -or $adapters[0].Name -cne 'drill-nic' -or
      $adapters[0].VMId -ne $ExpectedVmId) { throw 'adapter identity/cardinality mismatch' }
  Remove-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -Confirm:$false -ErrorAction Stop
  if (@(Get-VMNetworkAdapter -VM $guest -ErrorAction Stop).Count -ne 0) {
    throw 'adapter removal not confirmed'
  }
}
