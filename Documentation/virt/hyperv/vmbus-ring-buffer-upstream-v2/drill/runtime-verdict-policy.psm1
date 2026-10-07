function Test-HypervExpectedBaselineFailure {
  param([string]$ConsoleText = '')

  $required = @(
    'OWNER_TRACE_QUIESCE verified=no reason=event-unavailable',
    'NIC_QUIESCE verified=no reason=owner-trace-unavailable',
    'VERDICT=FAIL target channel owner was not proven live after fragmented open',
    'HYPERV_DRILL_FRAGMENT status=1',
    'OWNER_TRACE_POST_OPEN verified=no reason=owner-trace-unavailable',
    'HYPERV_DRILL_LIFECYCLE status=skipped reason=fragmentation-status-1',
    'HYPERV_DRILL_RESULT scope=drill-failed'
  )

  foreach ($line in $required) {
    if ($ConsoleText.IndexOf($line, [StringComparison]::Ordinal) -lt 0) {
      return $false
    }
  }

  $statusMatches = [regex]::Matches(
    $ConsoleText, '(?m)^HYPERV_DRILL_RESULT status=(PASS|PARTIAL|FAIL)\s*$')
  if ($statusMatches.Count -lt 1 -or $statusMatches.Count -gt 3) {
    return $false
  }
  foreach ($status in $statusMatches) {
    if ($status.Groups[1].Value -ne 'FAIL') {
      return $false
    }
  }

  $summaryMatches = [regex]::Matches(
    $ConsoleText, '(?m)^HYPERV_DRILL_RESULT lifecycle=skipped fragment=1 splats=0 faults=0\s*$')
  if ($summaryMatches.Count -ne 1) {
    return $false
  }

  $fragmentMatches = [regex]::Matches(
    $ConsoleText, '(?m)^HYPERV_DRILL_FRAGMENT status=(\d+)\s*$')
  if ($fragmentMatches.Count -ne 1 -or $fragmentMatches[0].Groups[1].Value -ne '1') {
    return $false
  }

  foreach ($counter in @('SPLATS', 'FAULTS')) {
    $matches = [regex]::Matches(
      $ConsoleText, "(?m)^HYPERV_DRILL_${counter} count=(\d+)\s*$")
    if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -ne '0') {
      return $false
    }
  }

  $unexpectedFaultText = [regex]::Replace(
    $ConsoleText,
    '(?m)^\[\s*\d+\.\d+\]\s+Warning: unable to open an initial console\.\s*$',
    '')
  return $unexpectedFaultText -notmatch '(?im)\b(BUG:|Oops:|WARNING:|Warning:|hung task|Out of memory|Kernel panic)'
}

function Get-HypervDrillDecision {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Observe', 'RequirePass', 'ExpectedBaselineFailure')]
    [string]$Policy,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS', 'PARTIAL', 'FAIL', 'NO_RESULT')]
    [string]$Verdict,

    [string]$ConsoleText = ''
  )

  switch ($Policy) {
    'Observe' {
      if ($Verdict -in @('PASS', 'PARTIAL')) {
        return [pscustomobject]@{ ExitCode = 0; Reason = "observed $Verdict" }
      }
      return [pscustomobject]@{ ExitCode = 1; Reason = "observed $Verdict" }
    }
    'RequirePass' {
      if ($Verdict -eq 'PASS') {
        return [pscustomobject]@{ ExitCode = 0; Reason = 'candidate passed every runtime gate' }
      }
      return [pscustomobject]@{ ExitCode = 1; Reason = "candidate verdict was $Verdict; full PASS required" }
    }
    'ExpectedBaselineFailure' {
      if ($Verdict -eq 'FAIL' -and (Test-HypervExpectedBaselineFailure -ConsoleText $ConsoleText)) {
        return [pscustomobject]@{ ExitCode = 0; Reason = 'known negative control reproduced without guest faults' }
      }
      return [pscustomobject]@{ ExitCode = 1; Reason = 'expected baseline signature was absent or another failure occurred' }
    }
  }
}

Export-ModuleMember -Function Get-HypervDrillDecision, Test-HypervExpectedBaselineFailure
