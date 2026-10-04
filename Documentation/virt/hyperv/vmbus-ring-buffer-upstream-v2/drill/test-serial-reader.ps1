# Exercise the actual reader against a local named pipe; no VM is created.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'new-drill-vm.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'drill harness has parse errors' }
$assignment = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'readerScript'
}, $true)
$expression = $assignment.Right.Find({
  param($node)
  $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true)
$reader = $expression.ScriptBlock.GetScriptBlock()
$pipeName = 'vmbus-reader-test-' + [Guid]::NewGuid().ToString('N')
$logPath = Join-Path ([IO.Path]::GetTempPath()) ($pipeName + '.log')
$payload = (1..3000 | ForEach-Object { 'OWNER_TRACE_DATA fixture-{0:D5}-abcdefghijklmnopqrstuvwxyz' -f $_ }) -join "`n"
$payload += "`nHYPERV_DRILL_DONE`n"
$server = Start-Job -ScriptBlock {
  param($Name, $Payload)
  $pipe = New-Object IO.Pipes.NamedPipeServerStream($Name, [IO.Pipes.PipeDirection]::InOut)
  try {
    $pipe.WaitForConnection()
    $bytes = [Text.Encoding]::ASCII.GetBytes($Payload)
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
  } finally { $pipe.Dispose() }
} -ArgumentList $pipeName, $payload
try {
  $result = & $reader $pipeName $logPath 30
  if ($result -ne 'DONE') { throw "reader returned $result" }
  $job = Wait-Job $server -Timeout 10
  if (-not $job -or $job.State -ne 'Completed') { throw 'pipe writer did not finish' }
  Receive-Job $server -ErrorAction Stop | Out-Null
  $capture = Get-Content $logPath -Raw
  $capture = $capture -replace '^DRILL-VM console_connect=ok\r?\n', ''
  if ($capture -cne $payload) { throw 'reader lost or changed payload bytes' }
  Write-Host 'PASS serial_reader_preserves_burst_across_chunk_boundaries'
} finally {
  Stop-Job $server -ErrorAction SilentlyContinue
  Remove-Job $server -Force -ErrorAction SilentlyContinue
  Remove-Item $logPath -ErrorAction SilentlyContinue
}
