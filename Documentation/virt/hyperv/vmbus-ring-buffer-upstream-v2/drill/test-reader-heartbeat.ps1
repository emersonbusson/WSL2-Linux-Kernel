# Tests extract only the observer; no Hyper-V VM is created.
$ErrorActionPreference = 'Stop'
$script:seen = @()
$script:calls = 0
$script:missingVm = $false
function Note { param($Key, $Value); $script:seen += $Value; return $Value }
function Wait-Job { param($Job, $Timeout); $script:calls++; if ($script:calls -ge 2) { return $Job } }
function Get-VM { param($Name, $ErrorAction); if ($script:missingVm) { throw 'missing' }; return [pscustomobject]@{ State = 'Running'; CPUUsage = 2; MemoryAssigned = 2147483648 } }
$source = Join-Path $PSScriptRoot 'new-drill-vm.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'drill harness has parse errors' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-DrillReader' }, $true)
if (-not $function) { throw 'observer function missing' }
Invoke-Expression $function.Extent.Text

$fixture = Join-Path $env:TEMP ('ramshared-reader-fixture-' + [guid]::NewGuid() + '.txt')
try {
 Set-Content $fixture 'HYPERV_DRILL_PHASE name=lifecycle event=begin uptime_s=10.0'
 $job = [pscustomobject]@{ State = 'Running' }
 $result = Wait-DrillReader -Job $job -BudgetSec 30 -Vm 'fixture' -ConsolePath $fixture
 if (-not [object]::ReferenceEquals($result, $job) -or $script:seen.Count -ne 1 -or $script:seen[0] -notmatch 'phase=lifecycle vm_state=Running') { throw 'heartbeat/progress fixture failed' }
 Write-Output 'PASS independent_observer_records_guest_phase'
 $script:seen = @(); $script:calls = 0; $script:missingVm = $true
 $result = Wait-DrillReader -Job $job -BudgetSec 30 -Vm 'fixture' -ConsolePath $fixture
 if (-not [object]::ReferenceEquals($result, $job) -or $script:seen[0] -notmatch 'vm_state=unavailable') { throw 'missing VM fixture failed' }
 Write-Output 'PASS missing_vm_is_observation_not_diagnosis'
 Remove-Item $fixture
 $script:seen = @(); $script:calls = 0
 $result = Wait-DrillReader -Job $job -BudgetSec 30 -Vm 'fixture' -ConsolePath $fixture
 if (-not [object]::ReferenceEquals($result, $job) -or $script:seen[0] -notmatch 'console_bytes=0 phase=unknown') { throw 'missing console fixture failed' }
 Write-Output 'PASS missing_console_preserves_reader_wait'
} finally { Remove-Item $fixture -ErrorAction SilentlyContinue }
