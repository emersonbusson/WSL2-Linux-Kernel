# Parser and admission regressions; never starts WSL or changes host settings.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'wsl-channel-lifetime.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in 'ConvertFrom-WslSnapshot', 'Get-ProtocolEvidence', 'Assert-LifetimeEvidence', 'Assert-ArtifactManifest', 'Invoke-OwnedProcess', 'ConvertTo-GuestShellCommand') {
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
    if ($functions.Count -ne 1) { throw "expected one function $name" }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
$script:cases = 0
function Reject([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'unsafe evidence was accepted' }
    $script:cases++
}
function Accept([scriptblock]$Action) { & $Action | Out-Null; $script:cases++ }
Accept {
    $actual = ConvertTo-GuestShellCommand "set -eu`r`necho data`r`n"
    if ($actual -cne "set -eu`necho data`n") { throw 'guest shell received Windows line endings' }
    if ((ConvertTo-GuestShellCommand "printf literal`rbyte") -cne "printf literal`rbyte") { throw 'literal carriage return changed' }
}
$valid = @'
kernel=6.18.40.1-channel-ack-candidate
notes=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
boot=12345678-1234-1234-1234-123456789abc
regions=100
pages=1000
available_kib=1000000
close_errors=0
'@
Accept { ConvertFrom-WslSnapshot $valid }
Reject { ConvertFrom-WslSnapshot ($valid + "`nregions=100") }
Reject { ConvertFrom-WslSnapshot ($valid.Replace('regions=100', '')) }
Reject { ConvertFrom-WslSnapshot ($valid.Replace('pages=1000', 'pages=-1')) }
Reject { ConvertFrom-WslSnapshot ($valid.Replace('pages=1000', 'pages=9999999999999999999999')) }
Reject { ConvertFrom-WslSnapshot ($valid.Replace('boot=12345678', 'boot=INVALID')) }
Reject { ConvertFrom-WslSnapshot ($valid + "`nunknown=10") }
$before = ConvertFrom-WslSnapshot $valid
$first = $before.Clone(); $last = $before.Clone()
$evidence = @{ requests = 32; acks = 32; rescinds = 32; unacknowledged = 0 }
Accept { Assert-LifetimeEvidence $evidence $before $first $last 'ack-candidate' }
Reject { $bad = $evidence.Clone(); $bad.unacknowledged = 1; Assert-LifetimeEvidence $bad $before $first $last 'ack-candidate' }
Reject { $bad = $evidence.Clone(); $bad.rescinds = 0; Assert-LifetimeEvidence $bad $before $first $last 'ack-candidate' }
Reject { $bad = $last.Clone(); $bad.pages += 4096; Assert-LifetimeEvidence $evidence $before $first $bad 'ack-candidate' }
Reject { $bad = $last.Clone(); $bad.pages += 1025; Assert-LifetimeEvidence $evidence $before $first $bad 'ack-candidate' }
Reject { $bad = $last.Clone(); $bad.close_errors = 1; Assert-LifetimeEvidence $evidence $before $first $bad 'ack-candidate' }
Reject { $bad = $last.Clone(); $bad.available_kib = 1; Assert-LifetimeEvidence $evidence $before $first $bad 'ack-candidate' }
Reject { $bad = $last.Clone(); $bad.boot = '12345678-1234-1234-1234-123456789abd'; Assert-LifetimeEvidence $evidence $before $first $bad 'ack-candidate' }
Reject { Assert-LifetimeEvidence $evidence $before $first $last 'retention-baseline' }
Accept { $bad = $last.Clone(); $bad.pages += 4096; $bad.close_errors = 32; Assert-LifetimeEvidence $evidence $before $first $bad 'retention-baseline' }
Reject { Assert-LifetimeEvidence $evidence $before $first $last 'unknown' }
$trace = @'
# entries-in-buffer/entries-written: 3/3
worker: vmbus_teardown_gpadl: sending child_relid 0x2, gpadl 0x123, ret 0
worker: vmbus_ongpadl_torndown: gpadl 0x123
worker: vmbus_onoffer_rescind: child_relid 0x2
'@
Accept {
    $actual = Get-ProtocolEvidence $trace
    if ($actual.requests -ne 1 -or $actual.acks -ne 1 -or $actual.unacknowledged -ne 0 -or $actual.rescinds -ne 1) { throw 'incorrect protocol counts' }
}
Accept {
    foreach ($ending in "`n", "`r`n") {
        $fixture = $trace.Replace("`r`n", "`n").Replace("`n", $ending)
        $fixture = $fixture.Replace('vmbus_ongpadl_torndown: gpadl 0x123', 'vmbus_ongpadl_torndown: gpadl 0x124')
        $actual = Get-ProtocolEvidence $fixture
        if ($actual.unacknowledged -ne 1) { throw 'wrong handle was accepted' }
    }
}
Reject { Get-ProtocolEvidence ($trace.Replace('3/3', '2/3')) }
Reject { Get-ProtocolEvidence '' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('channel-manifest-' + [guid]::NewGuid())
New-Item -ItemType Directory $fixture | Out-Null
try {
    $entries = foreach ($name in 'kernel', 'config', 'kernel-notes.bin', 'source-sha.txt', 'kernel-release.txt', 'notes-sha256.txt') {
        [IO.File]::WriteAllText((Join-Path $fixture $name), $name)
        (Get-FileHash (Join-Path $fixture $name) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
    }
    $inventory = Join-Path $fixture 'SHA256SUMS'
    [IO.File]::WriteAllLines($inventory, $entries)
    Accept { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllLines($inventory, @($entries) + $entries[0])
    Reject { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllLines($inventory, $entries[0..4])
    Reject { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllLines($inventory, $entries)
    [IO.File]::WriteAllText((Join-Path $fixture 'kernel'), 'tampered')
    Reject { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllText((Join-Path $fixture 'kernel'), 'kernel')
    foreach ($name in 'modules.vhdx', 'modules.sha256') {
        [IO.File]::WriteAllText((Join-Path $fixture $name), $name)
        $entries += (Get-FileHash (Join-Path $fixture $name) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
    }
    [IO.File]::WriteAllLines($inventory, $entries)
    Accept { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllText((Join-Path $fixture 'modules-layout.json'), '{"schema":1}')
    $entries += (Get-FileHash (Join-Path $fixture 'modules-layout.json') -Algorithm SHA256).Hash.ToLowerInvariant() + '  modules-layout.json'
    [IO.File]::WriteAllLines($inventory, $entries)
    Accept { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllText((Join-Path $fixture 'modules-layout.json'), 'tampered')
    Reject { Assert-ArtifactManifest $fixture }
    [IO.File]::WriteAllText((Join-Path $fixture 'modules-layout.json'), '{"schema":1}')
    [IO.File]::WriteAllText((Join-Path $fixture 'modules.vhdx'), 'wrong-pair')
    Reject { Assert-ArtifactManifest $fixture }
    $OutputDirectory = $fixture; $script:sequence = 0
    $report = @{ cleanup_errors = @() }
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    Accept {
        $actual = Invoke-OwnedProcess $pwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Write-Output process-success') 10
        if ($actual.Trim() -cne 'process-success') { throw 'native output was lost' }
    }
    Reject { Invoke-OwnedProcess $pwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 7') 10 }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Reject { Invoke-OwnedProcess $pwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') 1 }
    if ($watch.Elapsed.TotalSeconds -gt 12 -or $report.cleanup_errors.Count -ne 0) {
        throw 'native timeout was not bounded or process exit was unproven'
    }
    foreach ($number in 1, 2, 3) {
        if (-not (Test-Path (Join-Path $fixture "command-$number.stdout")) -or
            -not (Test-Path (Join-Path $fixture "command-$number.stderr"))) { throw 'native query evidence was lost' }
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Output "PASS: $script:cases parser and refusal regressions; no WSL invocation"
