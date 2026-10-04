# Portable Python implementation; no Bash dependency on Windows.
param(
    [Parameter(Position=0)][string]$SourceDir,
    [Parameter(Position=1)][string]$OutputDir,
    [Alias('h')][switch]$Help
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
function Find-Python3 {
    foreach ($name in @('python3','python','py')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        $prefix = @()
        if ($name -eq 'py') { $prefix = @('-3') }
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $LASTEXITCODE = 1
            $major = & $command.Source @prefix -c 'import sys; print(sys.version_info[0]); sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>$null
            $pythonExitCode = $LASTEXITCODE
            if ($pythonExitCode -eq 0 -and "$major".Trim() -eq '3') {
                return [pscustomobject]@{ Command=$command.Source; Prefix=$prefix }
            }
        } catch { } finally { $ErrorActionPreference = $previousPreference }
    }
    throw 'Python 3 is required. Install Python 3 and enable its PATH entry, or the py launcher.'
}

try { $python = Find-Python3 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }
$implementation = Join-Path $PSScriptRoot 'recover-kotlin-names.py'
$toolArguments = @($SourceDir)
if ($OutputDir) { $toolArguments += $OutputDir }
if ($Help) { $toolArguments = @('--help') }
if (-not $Help -and -not $toolArguments[0]) { Write-Host 'An input path is required.' -ForegroundColor Red; exit 1 }
$pythonPrefix = @($python.Prefix)
try {
    # Let Python print its own stderr; return its explicit exit status.
    $ErrorActionPreference = 'Continue'
    $LASTEXITCODE = 1
    & $python.Command @pythonPrefix $implementation @toolArguments
    $pythonExitCode = $LASTEXITCODE
} catch { Write-Host $_ -ForegroundColor Red; exit 1 }
exit $pythonExitCode
