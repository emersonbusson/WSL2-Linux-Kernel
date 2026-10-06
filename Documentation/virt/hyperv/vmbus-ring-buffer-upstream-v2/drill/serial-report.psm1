function Get-HypervDrillEvidenceReport {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ConsoleText)

  $headers = @{}
  $rowsByIndex = @{}
  $endMarkers = 0
  foreach ($rawLine in ($ConsoleText -split "`n")) {
    $line = $rawLine.TrimEnd("`r")
    if ($line -match '^HYPERV_DRILL_REPORT format=gzip-base64-indexed rows=(?<rows>[1-9][0-9]{0,4}) sha256=(?<sha>[0-9a-f]{64})$') {
      $rowCount = [int]$Matches.rows
      if ($rowCount -gt 50000) {
        continue
      }
      $key = '{0}:{1}' -f $rowCount, $Matches.sha
      if (-not $headers.ContainsKey($key)) { $headers[$key] = 0 }
      $headers[$key]++
      continue
    }

    if ($line -match '^HYPERV_DRILL_REPORT_DATA index=(?<index>[0-9]{1,5}) data=(?<data>[A-Za-z0-9+/=]{4,76})$') {
      $index = [int]$Matches.index
      $data = $Matches.data
      if ($index -ge 50000 -or ($data.Length % 4) -ne 0) { continue }
      if (-not $rowsByIndex.ContainsKey($index)) {
        $rowsByIndex[$index] = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
      }
      if (-not $rowsByIndex[$index].ContainsKey($data)) { $rowsByIndex[$index][$data] = 0 }
      $rowsByIndex[$index][$data]++
      continue
    }

    if ($line -ceq 'HYPERV_DRILL_REPORT end=1') { $endMarkers++ }
  }

  if ($headers.Count -eq 0 -or $endMarkers -eq 0) {
    return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-frame-missing'; Sha256 = ''; Rows = 0; Copies = 0; RecoveredRows = 0 }
  }

  $rankedHeaders = @($headers.GetEnumerator() | Sort-Object -Property Value -Descending)
  if ($rankedHeaders.Count -gt 1 -and $rankedHeaders[0].Value -eq $rankedHeaders[1].Value) {
    return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'conflicting-report-headers'; Sha256 = ''; Rows = 0; Copies = 0; RecoveredRows = 0 }
  }
  $header = [string]$rankedHeaders[0].Key
  $parts = $header.Split(':')
  $rowCount = [int]$parts[0]
  $expectedHash = $parts[1]
  if ($rowCount -lt 1 -or $rowCount -gt 50000) {
    return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-row-limit'; Sha256 = ''; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = 0 }
  }

  $fragments = [System.Collections.Generic.List[string]]::new()
  $recoveredRows = 0
  for ($index = 0; $index -lt $rowCount; $index++) {
    if (-not $rowsByIndex.ContainsKey($index)) {
      return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-row-missing'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
    }
    $choices = @($rowsByIndex[$index].GetEnumerator() | Sort-Object -Property Value -Descending)
    if ($choices.Count -gt 1 -and $choices[0].Value -eq $choices[1].Value) {
      return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-row-conflict'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
    }
    $fragment = [string]$choices[0].Key
    if (($index -lt ($rowCount - 1) -and $fragment.Length -ne 76) -or $fragment.Length -gt 76) {
      return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-row-length'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
    }
    if ($choices[0].Value -lt $rankedHeaders[0].Value) { $recoveredRows++ }
    $fragments.Add($fragment)
  }

  $encoded = [string]::Join('', $fragments)
  if ($encoded.Length -gt (4 * 1024 * 1024)) {
    return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-size-limit'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
  }

  $inputStream = $null
  $gzip = $null
  $outputStream = $null
  try {
    $packed = [Convert]::FromBase64String($encoded)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      $actualHash = [BitConverter]::ToString($sha.ComputeHash($packed)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    if ($actualHash -cne $expectedHash) {
      return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-checksum-mismatch'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
    }

    $inputStream = [IO.MemoryStream]::new($packed)
    $gzip = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
    $outputStream = [IO.MemoryStream]::new()
    $buffer = New-Object byte[] 8192
    while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
      if (($outputStream.Length + $read) -gt (16 * 1024 * 1024)) {
        return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-expanded-size-limit'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
      }
      $outputStream.Write($buffer, 0, $read)
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($outputStream.ToArray())
    if (-not $text.StartsWith("HYPERV_DRILL_EVIDENCE schema=1`n", [StringComparison]::Ordinal) -or
        -not $text.TrimEnd("`r", "`n").EndsWith('HYPERV_DRILL_EVIDENCE_END', [StringComparison]::Ordinal)) {
      return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-payload-boundary-invalid'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
    }
    return [pscustomobject]@{ Verified = $true; Text = $text; Error = ''; Sha256 = $actualHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
  }
  catch {
    return [pscustomobject]@{ Verified = $false; Text = ''; Error = 'report-decode-failed'; Sha256 = $expectedHash; Rows = $rowCount; Copies = [int]$rankedHeaders[0].Value; RecoveredRows = $recoveredRows }
  }
  finally {
    if ($gzip) { $gzip.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($outputStream) { $outputStream.Dispose() }
  }
}

function Get-HypervDrillReportVerdict {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReportText,
    [switch]$RequireHostRescind
  )

  $noResult = { param($reason) [pscustomobject]@{ Verdict = 'NO_RESULT'; Error = $reason } }
  $statuses = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_RESULT status=(PASS|PARTIAL|FAIL)\s*$')
  $summaries = [regex]::Matches(
    $ReportText,
    '(?m)^HYPERV_DRILL_RESULT lifecycle=(?<life>0|[1-9][0-9]{0,2}) fragment=(?<fragment>0|[1-9][0-9]{0,2}) splats=(?<splats>0|[1-9][0-9]{0,8}) faults=(?<faults>0|[1-9][0-9]{0,8})\s*$')
  $lifecycle = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_LIFECYCLE status=(?<value>0|[1-9][0-9]{0,2})\s*$')
  $fragment = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_FRAGMENT status=(?<value>0|[1-9][0-9]{0,2})\s*$')
  $splats = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_SPLATS count=(?<value>0|[1-9][0-9]{0,8})\s*$')
  $faults = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_FAULTS count=(?<value>0|[1-9][0-9]{0,8})\s*$')
  $rescinds = [regex]::Matches(
    $ReportText,
    '(?m)^HYPERV_DRILL_HOST_RESCIND status=(?<status>PASS|PARTIAL|skipped) target_absent=(?<absent>yes|no) matching_events=(?<events>0|[1-9][0-9]{0,8})\s*$')
  $scopes = [regex]::Matches($ReportText, '(?m)^HYPERV_DRILL_RESULT scope=(?<value>[a-z0-9-]+)\s*$')

  if ($statuses.Count -ne 3 -or $summaries.Count -ne 1 -or
      $lifecycle.Count -ne 1 -or $fragment.Count -ne 1 -or
      $splats.Count -ne 1 -or $faults.Count -ne 1 -or
      $rescinds.Count -ne 1 -or $scopes.Count -ne 1) {
    return (& $noResult 'report-fields-missing-or-duplicated')
  }
  $status = $statuses[0].Groups[1].Value
  foreach ($entry in $statuses) {
    if ($entry.Groups[1].Value -cne $status) {
      return (& $noResult 'report-status-replicas-conflict')
    }
  }

  $summary = $summaries[0]
  if ([int]$summary.Groups['life'].Value -ne [int]$lifecycle[0].Groups['value'].Value -or
      [int]$summary.Groups['fragment'].Value -ne [int]$fragment[0].Groups['value'].Value -or
      [int]$summary.Groups['splats'].Value -ne [int]$splats[0].Groups['value'].Value -or
      [int]$summary.Groups['faults'].Value -ne [int]$faults[0].Groups['value'].Value) {
    return (& $noResult 'report-summary-counters-conflict')
  }

  if ($status -ceq 'PASS') {
    if ([int]$summary.Groups['life'].Value -ne 0 -or
        [int]$summary.Groups['fragment'].Value -ne 0 -or
        [int]$summary.Groups['splats'].Value -ne 0 -or
        [int]$summary.Groups['faults'].Value -ne 0 -or
        $scopes[0].Groups['value'].Value -cne 'ordinary-hyperv-gpadl-uio-and-ring-under-fragmentation') {
      return (& $noResult 'pass-verdict-conflicts-with-measured-counters-or-scope')
    }
    if ($RequireHostRescind -and
        ($rescinds[0].Groups['status'].Value -cne 'PASS' -or
         $rescinds[0].Groups['absent'].Value -cne 'yes' -or
         [int]$rescinds[0].Groups['events'].Value -lt 1)) {
      return (& $noResult 'required-host-rescind-not-proven')
    }
  }

  return [pscustomobject]@{ Verdict = $status; Error = '' }
}

Export-ModuleMember -Function Get-HypervDrillEvidenceReport, Get-HypervDrillReportVerdict
