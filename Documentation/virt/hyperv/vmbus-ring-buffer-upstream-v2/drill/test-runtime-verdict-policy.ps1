$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = Join-Path $PSScriptRoot 'runtime-verdict-policy.psm1'
Import-Module $module -Force

function Assert-Decision {
  param(
    [string]$Policy,
    [string]$Verdict,
    [string]$Console,
    [int]$ExpectedExitCode,
    [string]$Name
  )

  $decision = Get-HypervDrillDecision -Policy $Policy -Verdict $Verdict -ConsoleText $Console
  if ($decision.ExitCode -ne $ExpectedExitCode) {
    throw "$Name`: expected exit $ExpectedExitCode, got $($decision.ExitCode) ($($decision.Reason))"
  }
}

$expectedBaseline = @'
HYPERV_DRILL_LIFECYCLE status=1
CLEANUP_VERDICT=FAIL teardown released nothing
MAP_ACCOUNTING_VERDICT=FAIL outside the expected band: tuple unreadable
RESTORE_VERDICT=PARTIAL rebind=no (hv_netvsc did not rebind; open channel is the known hv_uio_remove gap); device restoration not proven
LIFECYCLE_VERDICT=FAIL cleanup=FAIL map_uio=PASS map_sysfs=PASS map_accounting=FAIL restore=PARTIAL cycles=100 maps=(0 0 0) gap_retained=(0/0/0)
HYPERV_DRILL_SPLATS count=0
HYPERV_DRILL_FAULTS count=0
'@

Assert-Decision Observe PASS '' 0 'observe accepts pass'
Assert-Decision Observe PARTIAL '' 0 'observe preserves bounded partial'
Assert-Decision Observe FAIL '' 1 'observe rejects failure'
Assert-Decision Observe NO_RESULT '' 1 'observe rejects missing verdict'

Assert-Decision RequirePass PASS '' 0 'strict candidate accepts pass'
Assert-Decision RequirePass PARTIAL '' 1 'strict candidate rejects partial'
Assert-Decision RequirePass FAIL '' 1 'strict candidate rejects failure'
Assert-Decision RequirePass NO_RESULT '' 1 'strict candidate rejects missing verdict'

Assert-Decision ExpectedBaselineFailure FAIL $expectedBaseline 0 'baseline recognizes exact negative control'
Assert-Decision ExpectedBaselineFailure PASS $expectedBaseline 1 'baseline rejects unexpected pass'
Assert-Decision ExpectedBaselineFailure PARTIAL $expectedBaseline 1 'baseline rejects partial'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'tuple unreadable', 'unexpected allocator result') 1 'baseline rejects unrelated failure'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_SPLATS count=0', 'HYPERV_DRILL_SPLATS count=1') 1 'baseline rejects kernel splat'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'cycles=100', 'cycles=99') 1 'baseline rejects incomplete lifecycle run'

Write-Output 'runtime verdict policy tests: PASS'
