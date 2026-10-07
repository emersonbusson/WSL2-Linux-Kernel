$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'serial-report.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'runtime-verdict-policy.psm1') -Force

function New-TestReportFrames([string]$ReportText) {
  $plain = [Text.UTF8Encoding]::new($false).GetBytes($ReportText)
  $packedStream = [IO.MemoryStream]::new()
  $gzip = [IO.Compression.GZipStream]::new($packedStream, [IO.Compression.CompressionMode]::Compress, $true)
  $gzip.Write($plain, 0, $plain.Length)
  $gzip.Dispose()
  $packed = $packedStream.ToArray()
  $packedStream.Dispose()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $digest = [BitConverter]::ToString($sha.ComputeHash($packed)).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $encoded = [Convert]::ToBase64String($packed)
  $chunks = @()
  $chunkWidth = 40
  for ($offset = 0; $offset -lt $encoded.Length; $offset += $chunkWidth) {
    $length = [Math]::Min($chunkWidth, $encoded.Length - $offset)
    $chunks += $encoded.Substring($offset, $length)
  }
  $header = 'HYPERV_DRILL_REPORT format=gzip-base64-indexed-v2 width={0} copies=7 rows={1} sha256={2}' -f $chunkWidth, $chunks.Count, $digest
  $frames = @()
  for ($copy = 0; $copy -lt 7; $copy++) {
    $frames += $header
    $start = [int][Math]::Floor($copy * $chunks.Count / 7.0)
    for ($offset = 0; $offset -lt $chunks.Count; $offset++) {
      $index = ($start + $offset) % $chunks.Count
      $frames += ('HYPERV_DRILL_REPORT_DATA index={0} data={1}' -f $index, $chunks[$index])
    }
    $frames += 'HYPERV_DRILL_REPORT end=1'
  }
  return ,@{ Lines = $frames; Chunks = $chunks }
}

$payload = @(
  'HYPERV_DRILL_EVIDENCE schema=1',
  'HYPERV_DRILL_LIFECYCLE status=0',
  'HYPERV_DRILL_FRAGMENT status=0',
  'HYPERV_DRILL_HOST_RESCIND status=PASS target_absent=yes matching_events=1',
  'HYPERV_DRILL_RESULT status=PASS',
  'HYPERV_DRILL_RESULT status=PASS',
  'HYPERV_DRILL_RESULT status=PASS',
  'HYPERV_DRILL_RESULT lifecycle=0 fragment=0 splats=0 faults=0',
  'HYPERV_DRILL_RESULT scope=ordinary-hyperv-gpadl-uio-and-ring-under-fragmentation',
  'HYPERV_DRILL_SPLATS count=0',
  'HYPERV_DRILL_FAULTS count=0',
  'HYPERV_DRILL_EVIDENCE_END'
) -join "`n"
$fixture = New-TestReportFrames $payload

# One damaged byte row and one independently lost row are recovered from the
# remaining replicas, then the compressed payload digest validates the result.
$recoverable = [Collections.Generic.List[string]]::new()
foreach ($line in $fixture.Lines) { $recoverable.Add([string]$line) }
$dataLines = @($recoverable | Where-Object { $_ -match '^HYPERV_DRILL_REPORT_DATA index=' })
$firstRow = $dataLines[0]
$firstDataOffset = $firstRow.IndexOf('data=', [StringComparison]::Ordinal) + 5
$firstCharacter = [string]$firstRow[$firstDataOffset]
if ($firstCharacter -cmatch '^[A-Z]$') {
  $firstReplacement = $firstCharacter.ToLowerInvariant()
}
elseif ($firstCharacter -cmatch '^[a-z]$') {
  $firstReplacement = $firstCharacter.ToUpperInvariant()
}
else {
  $firstReplacement = if ($firstCharacter -ceq 'A') { 'B' } else { 'A' }
}
$recoverable[$recoverable.IndexOf($firstRow)] = $firstRow.Substring(0, $firstDataOffset) +
  $firstReplacement + $firstRow.Substring($firstDataOffset + 1)
$secondRow = $dataLines[1]
$recoverable.Remove($secondRow) | Out-Null
$recovered = Get-HypervDrillEvidenceReport -ConsoleText ($recoverable -join "`n")
if (-not $recovered.Verified -or $recovered.Text -cne $payload) {
  throw "replicated report recovery failed: $($recovered.Error)"
}
Write-Output 'PASS serial_report_recovers_corrupt_and_missing_rows'

# Reproduce the observed serial failure shape: one replica loses the row and
# two others lose one character. The four intact copies still reach quorum.
$serialLoss = [Collections.Generic.List[string]]::new()
foreach ($line in $fixture.Lines) { $serialLoss.Add([string]$line) }
$rowOne = @($serialLoss | Where-Object { $_ -match '^HYPERV_DRILL_REPORT_DATA index=1 ' })
for ($copy = 0; $copy -lt 2; $copy++) {
  $line = $rowOne[$copy]
  $dataOffset = $line.IndexOf('data=', [StringComparison]::Ordinal) + 5
  $cutOffset = $dataOffset + 12
  $serialLoss[$serialLoss.IndexOf($line)] = $line.Substring(0, $cutOffset) + $line.Substring($cutOffset + 1)
}
$serialLoss.Remove($rowOne[2]) | Out-Null
$lossRecovered = Get-HypervDrillEvidenceReport -ConsoleText ($serialLoss -join "`n")
if (-not $lossRecovered.Verified -or $lossRecovered.Text -cne $payload) {
  throw "serial-loss regression was not recovered: $($lossRecovered.Error)"
}
Write-Output 'PASS serial_report_recovers_two_truncated_rows_and_one_lost_replica'

# A burst can damage more than half of a row's copies. The unique top
# candidate is acceptable only when the complete compressed SHA-256 matches.
$majorityLoss = [Collections.Generic.List[string]]::new()
foreach ($line in $fixture.Lines) { $majorityLoss.Add([string]$line) }
$rowCopies = 0
$alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
for ($lineIndex = 0; $lineIndex -lt $majorityLoss.Count; $lineIndex++) {
  $line = $majorityLoss[$lineIndex]
  if ($line -notmatch '^HYPERV_DRILL_REPORT_DATA index=0 ') { continue }
  if ($rowCopies -ge 3) {
    $dataOffset = $line.IndexOf('data=', [StringComparison]::Ordinal) + 5
    $oldChar = [string]$line[$dataOffset]
    $replacementIndex = ($alphabet.IndexOf($oldChar) + $rowCopies) % $alphabet.Length
    $replacement = [string]$alphabet[$replacementIndex]
    $majorityLoss[$lineIndex] = $line.Substring(0, $dataOffset) + $replacement +
      $line.Substring($dataOffset + 1)
  }
  $rowCopies++
}
$majorityRecovered = Get-HypervDrillEvidenceReport -ConsoleText ($majorityLoss -join [Environment]::NewLine)
if (-not $majorityRecovered.Verified -or $majorityRecovered.Text -cne $payload) {
  throw "unique checksum-bound row recovery failed: $($majorityRecovered.Error)"
}
Write-Output 'PASS serial_report_recovers_unique_rows_below_copy_quorum_by_digest'

$reportOutcome = Get-HypervDrillReportVerdict -ReportText $recovered.Text -RequireHostRescind
if ($reportOutcome.Verdict -ne 'PASS') { throw "verified candidate report rejected: $($reportOutcome.Error)" }
$passDecision = Get-HypervDrillDecision -Policy RequirePass -Verdict $reportOutcome.Verdict -ConsoleText $recovered.Text
if ($passDecision.ExitCode -ne 0) { throw 'verified candidate report did not reach the passing gate' }
Write-Output 'PASS verified_candidate_report_reaches_runtime_gate'
$counterMismatch = Get-HypervDrillReportVerdict -ReportText ($recovered.Text -replace 'lifecycle=0 fragment=0', 'lifecycle=1 fragment=0') -RequireHostRescind
if ($counterMismatch.Verdict -ne 'NO_RESULT') { throw 'conflicting PASS counters were accepted' }
$faultedPassText = $recovered.Text.Replace('splats=0 faults=0', 'splats=1 faults=0').Replace('HYPERV_DRILL_SPLATS count=0', 'HYPERV_DRILL_SPLATS count=1')
$faultedPass = Get-HypervDrillReportVerdict -ReportText $faultedPassText -RequireHostRescind
if ($faultedPass.Verdict -ne 'NO_RESULT') { throw 'PASS with a nonzero fault count was accepted' }
$rescindedMissing = Get-HypervDrillReportVerdict -ReportText ($recovered.Text -replace 'status=PASS target_absent=yes matching_events=1', 'status=PARTIAL target_absent=no matching_events=0') -RequireHostRescind
if ($rescindedMissing.Verdict -ne 'NO_RESULT') { throw 'missing required host rescind was accepted' }
Write-Output 'PASS serial_verdict_refuses_counter_fault_or_rescind_conflicts'

$baselinePayload = @(
  'HYPERV_DRILL_EVIDENCE schema=1',
  'HYPERV_DRILL_LIFECYCLE status=1',
  'HYPERV_DRILL_FRAGMENT status=0',
  'HYPERV_DRILL_HOST_RESCIND status=PARTIAL target_absent=no matching_events=0',
  'CLEANUP_VERDICT=FAIL teardown released nothing',
  'MAP_ACCOUNTING_VERDICT=FAIL outside the expected band: tuple unreadable',
  'RESTORE_VERDICT=PARTIAL rebind=no (hv_netvsc did not rebind; open channel is the known hv_uio_remove gap); device restoration not proven',
  'LIFECYCLE_VERDICT=FAIL cleanup=FAIL map_uio=PASS map_sysfs=PASS map_accounting=FAIL restore=PARTIAL cycles=100 maps=(0 0 0) gap_retained=(0/0/0)',
  'HYPERV_DRILL_RESULT status=FAIL',
  'HYPERV_DRILL_RESULT status=FAIL',
  'HYPERV_DRILL_RESULT status=FAIL',
  'HYPERV_DRILL_RESULT lifecycle=1 fragment=0 splats=0 faults=0',
  'HYPERV_DRILL_RESULT scope=drill-failed',
  'HYPERV_DRILL_SPLATS count=0',
  'HYPERV_DRILL_FAULTS count=0',
  'HYPERV_DRILL_EVIDENCE_END'
) -join "`n"
$baselineFixture = New-TestReportFrames $baselinePayload
$baselineDecoded = Get-HypervDrillEvidenceReport -ConsoleText ($baselineFixture.Lines -join "`n")
if (-not $baselineDecoded.Verified) { throw "baseline fixture did not verify: $($baselineDecoded.Error)" }
$baselineOutcome = Get-HypervDrillReportVerdict -ReportText $baselineDecoded.Text
if ($baselineOutcome.Verdict -ne 'FAIL') { throw "planned baseline report rejected: $($baselineOutcome.Error)" }
$baselineDecision = Get-HypervDrillDecision -Policy ExpectedBaselineFailure -Verdict $baselineOutcome.Verdict -ConsoleText $baselineDecoded.Text
if ($baselineDecision.ExitCode -ne 0) { throw 'verified planned negative control was not accepted' }
$unexpectedWarning = Get-HypervDrillDecision -Policy ExpectedBaselineFailure -Verdict FAIL `
  -ConsoleText ($baselineDecoded.Text + "`nWARNING: unexpected guest warning")
if ($unexpectedWarning.ExitCode -eq 0) { throw 'unexpected warning was accepted in a negative control' }
Write-Output 'PASS verified_report_accepts_only_planned_baseline_signature'

# A corrupted variant can have more copies than the valid fragment; the
# complete packed digest must still reject the assembled report.
$wrongMajority = [Collections.Generic.List[string]]::new()
foreach ($line in $fixture.Lines) { $wrongMajority.Add([string]$line) }
$rowCopies = 0
$badRowReplacement = ''
for ($lineIndex = 0; $lineIndex -lt $wrongMajority.Count; $lineIndex++) {
  $line = $wrongMajority[$lineIndex]
  if ($line -notmatch '^HYPERV_DRILL_REPORT_DATA index=0 ') { continue }
  $dataOffset = $line.IndexOf('data=', [StringComparison]::Ordinal) + 5
  if ($rowCopies -eq 0) {
    $oldChar = [string]$line[$dataOffset]
    $badRowReplacement = if ($oldChar -ceq 'A') { 'B' } else { 'A' }
  }
  if ($rowCopies -lt 4) {
    $wrongMajority[$lineIndex] = $line.Substring(0, $dataOffset) +
      $badRowReplacement + $line.Substring($dataOffset + 1)
  }
  $rowCopies++
}
$rejected = Get-HypervDrillEvidenceReport -ConsoleText ($wrongMajority -join [Environment]::NewLine)
if ($rejected.Verified -or $rejected.Error -ne 'report-checksum-mismatch') {
  throw "wrong checksum-bound majority was not rejected: verified=$($rejected.Verified) error=$($rejected.Error)"
}
Write-Output 'PASS serial_report_rejects_wrong_row_majority_by_digest'

$missing = Get-HypervDrillEvidenceReport -ConsoleText 'HYPERV_DRILL_DONE'
if ($missing.Verified -or $missing.Error -ne 'report-frame-missing') {
  throw 'missing serial report was not refused'
}
Write-Output 'PASS serial_report_rejects_missing_frame'
$empty = Get-HypervDrillEvidenceReport -ConsoleText ''
if ($empty.Verified -or $empty.Error -ne 'report-frame-missing') {
  throw 'empty console was not converted into a missing-report result'
}
Write-Output 'PASS serial_report_handles_empty_console'
