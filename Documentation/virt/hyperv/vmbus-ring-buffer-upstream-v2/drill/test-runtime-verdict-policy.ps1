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
[    0.731452] Warning: unable to open an initial console.
OWNER_TRACE_QUIESCE verified=no reason=event-unavailable
NIC_QUIESCE verified=no reason=owner-trace-unavailable previous_maps=0 remaining_maps=0
VERDICT=FAIL target channel owner was not proven live after fragmented open
HYPERV_DRILL_FRAGMENT status=1
OWNER_TRACE_POST_OPEN verified=no reason=owner-trace-unavailable
HYPERV_DRILL_LIFECYCLE status=skipped
HYPERV_DRILL_SPLATS count=0
HYPERV_DRILL_FAULTS count=0
HYPERV_DRILL_RESULT status=FAIL
HYPERV_DRILL_RESULT status=FAIL
HYPERV_DRILL_RESULT status=FAIL
HYPERV_DRILL_RESULT lifecycle=skipped fragment=1 splats=0 faults=0
HYPERV_DRILL_RESULT scope=drill-failed
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
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'target channel owner was not proven live', 'unexpected allocator result') 1 'baseline rejects unrelated failure'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_SPLATS count=0', 'HYPERV_DRILL_SPLATS count=1') 1 'baseline rejects kernel splat'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_LIFECYCLE status=skipped', 'HYPERV_DRILL_LIFECYCLE status=skipped reason=runner-timeout') 1 'baseline rejects an unrelated lifecycle skip'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_LIFECYCLE status=skipped', 'HYPERV_DRILL_LIFECYCLE status=skipped reason=fragmentation-status-1') 0 'baseline accepts explicit matching lifecycle skip reason'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'fragment=1', 'fragment=3') 1 'baseline rejects partial fragmentation result'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_LIFECYCLE status=skipped', 'HYPERV_DRILL_LIFECYCLE status=0') 1 'baseline rejects lifecycle after failed fragmentation precondition'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'OWNER_TRACE_QUIESCE verified=no reason=event-unavailable', '') 1 'baseline requires explicit missing-owner-trace evidence'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'NIC_QUIESCE verified=no', 'NIC_QUIESCE verified=yes') 1 'baseline rejects unexpected NIC quiescence claim'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline + "`nHYPERV_DRILL_RESULT status=PASS") 1 'baseline rejects conflicting aggregate result'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'HYPERV_DRILL_RESULT status=FAIL', '') 1 'baseline rejects missing repeated status'
Assert-Decision ExpectedBaselineFailure FAIL ($expectedBaseline -replace 'Warning: unable to open an initial console\.', 'WARNING: unexpected kernel warning') 1 'baseline rejects unexpected kernel warning'
$singleStatus = $expectedBaseline -replace '(?m)^HYPERV_DRILL_RESULT status=FAIL[ \t]*\r?\n', ''
$singleStatus += "`nHYPERV_DRILL_RESULT status=FAIL`n"
Assert-Decision ExpectedBaselineFailure FAIL $singleStatus 0 'baseline accepts intact status after serial copy loss'

Write-Output 'runtime verdict policy tests: PASS'
