# check-deps.ps1 — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL_REQUIRED/INSTALL_OPTIONAL lines.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Refresh PATH from user environment so we pick up tools installed in the same session
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath) {
    foreach ($dir in $userPath -split ';') {
        if ($dir -and $env:PATH -notlike "*$dir*") {
            $env:PATH = "$dir;$env:PATH"
        }
    }
}

$REQUIRED_JAVA_MAJOR = 17
$errors = 0
$missingRequired = @()
$missingOptional = @()

Write-Host "=== Android Reverse Engineering: Dependency Check ==="
Write-Host ""

# --- Java ---
$javaOk = $false
$javaBin = Get-Command java -ErrorAction SilentlyContinue
if ($javaBin) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $javaVersionOutput = & java -version 2>&1 | Select-Object -First 1
    $javaExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    $javaVersionStr = "$javaVersionOutput"
    if ($javaVersionStr -match '"(\d+)') {
        $javaVersion = [int]$Matches[1]
        if ($javaVersion -eq 1 -and $javaVersionStr -match '"1\.(\d+)') {
            $javaVersion = [int]$Matches[1]
        }
        if ($javaExitCode -eq 0 -and $javaVersion -ge $REQUIRED_JAVA_MAJOR) {
            Write-Host "[OK] Java $javaVersion detected"
            $javaOk = $true
        } else {
            Write-Host "[WARN] Java detected but version $javaVersion is below $REQUIRED_JAVA_MAJOR"
            $errors++
            $missingRequired += "java"
        }
    } else {
        Write-Host "[WARN] Java detected but could not parse version from: $javaVersionStr"
        $errors++
        $missingRequired += "java"
    }
} else {
    Write-Host "[MISSING] Java is not installed or not in PATH"
    $errors++
    $missingRequired += "java"
}

# --- Python 3 (portable fingerprinting / Kotlin recovery) ---
$pythonFound = $false
foreach ($pythonName in @('python3','python','py')) {
    $pythonCommand = Get-Command $pythonName -CommandType Application -ErrorAction SilentlyContinue
    if (-not $pythonCommand) { continue }
    $pythonArguments = @()
    if ($pythonName -eq 'py') { $pythonArguments += '-3' }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = 1
        $version = & $pythonCommand.Source @pythonArguments -c 'import sys; print(sys.version_info[0]); sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>$null
        $pythonExitCode = $LASTEXITCODE
        if ($pythonExitCode -eq 0 -and "$version".Trim() -eq '3') {
            Write-Host "[OK] Python 3 detected via $pythonName"
            $pythonFound = $true
            break
        }
    } catch { } finally { $ErrorActionPreference = $previousPreference }
}
if (-not $pythonFound) {
    Write-Host '[MISSING] Python 3 (required for fingerprinting and Kotlin name recovery)'
    $errors++
    $missingRequired += 'python3'
}
# PowerShell searches source and .NET handles ZIP/JAR archives; Unix utilities
# and Bash are not dependencies of the Windows helpers.
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Write-Host '[OK] .NET ZIP archive support'
} catch {
    Write-Host '[MISSING] .NET ZIP archive support'
    $errors++
    $missingRequired += 'dotnet-zip'
}

# --- jadx ---
$jadxBin = Get-Command jadx -ErrorAction SilentlyContinue
if (-not $jadxBin) {
    # Check common Windows install locations
    $jadxCandidates = @(
        "$env:USERPROFILE\.local\share\jadx\bin\jadx.bat",
        "$env:USERPROFILE\jadx\bin\jadx.bat",
        "$env:LOCALAPPDATA\jadx\bin\jadx.bat"
    )
    foreach ($c in $jadxCandidates) {
        if (Test-Path $c) {
            $jadxBin = $c
            break
        }
    }
}
if ($jadxBin) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = 1
        $jadxCmd = if ($jadxBin -is [string]) { $jadxBin } else { 'jadx' }
        $jadxVersion = & $jadxCmd --version 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'jadx version check failed' }
        Write-Host "[OK] jadx $jadxVersion detected"
    } catch {
        Write-Host '[MISSING] jadx command failed its version check'
        $errors++
        $missingRequired += 'jadx'
    } finally { $ErrorActionPreference = $previousPreference }
} else {
    Write-Host "[MISSING] jadx is not installed or not in PATH"
    $errors++
    $missingRequired += "jadx"
}

# --- Fernflower / Vineflower ---
$ffFound = $false
$vineflowerBin = Get-Command vineflower -ErrorAction SilentlyContinue
$fernflowerBin = Get-Command fernflower -ErrorAction SilentlyContinue
if ($vineflowerBin) {
    Write-Host "[OK] vineflower CLI detected"
    $ffFound = $true
} elseif ($fernflowerBin) {
    Write-Host "[OK] fernflower CLI detected"
    $ffFound = $true
} else {
    $ffCandidates = @(
        $env:FERNFLOWER_JAR_PATH,
        "$env:USERPROFILE\.local\share\vineflower\vineflower.jar",
        "$env:USERPROFILE\fernflower\build\libs\fernflower.jar",
        "$env:USERPROFILE\vineflower\build\libs\vineflower.jar",
        "$env:USERPROFILE\fernflower\fernflower.jar",
        "$env:USERPROFILE\vineflower\vineflower.jar"
    )
    foreach ($candidate in $ffCandidates) {
        if ($candidate -and (Test-Path $candidate -ErrorAction SilentlyContinue)) {
            Write-Host "[OK] Fernflower/Vineflower JAR found: $candidate"
            $ffFound = $true
            break
        }
    }
}
if (-not $ffFound) {
    Write-Host "[MISSING] Fernflower/Vineflower not found (optional - better output on complex Java code)"
    $missingOptional += "vineflower"
}

# --- dex2jar ---
$d2jBin = Get-Command d2j-dex2jar -ErrorAction SilentlyContinue
if (-not $d2jBin) {
    $d2jBin = Get-Command d2j-dex2jar.bat -ErrorAction SilentlyContinue
}
if ($d2jBin) {
    Write-Host "[OK] dex2jar detected"
} else {
    Write-Host "[MISSING] dex2jar not found (optional - needed to use Fernflower on APK/DEX files)"
    $missingOptional += "dex2jar"
}

# --- Optional: apktool ---
if (Get-Command apktool -ErrorAction SilentlyContinue) {
    Write-Host "[OK] apktool detected (optional)"
} else {
    Write-Host "[MISSING] apktool not found (optional - useful for resource decoding)"
    $missingOptional += "apktool"
}

# --- Optional: adb ---
if (Get-Command adb -ErrorAction SilentlyContinue) {
    Write-Host "[OK] adb detected (optional)"
} else {
    Write-Host "[MISSING] adb not found (optional - useful for pulling APKs from devices)"
    $missingOptional += "adb"
}

# --- Machine-readable summary ---
Write-Host ""
foreach ($dep in $missingRequired) {
    Write-Host "INSTALL_REQUIRED:$dep"
}
foreach ($dep in $missingOptional) {
    Write-Host "INSTALL_OPTIONAL:$dep"
}

Write-Host ""
if ($errors -gt 0) {
    Write-Host "*** $($missingRequired.Count) required dependency/ies missing. ***"
    Write-Host 'See references/setup-guide.md. install-dep.ps1 supports java/jadx and optional decompilers; install Python 3 separately.'
    exit 1
} else {
    if ($missingOptional.Count -gt 0) {
        Write-Host "Required dependencies OK. $($missingOptional.Count) optional dependency/ies missing."
        Write-Host "Run install-dep.ps1 <name> to install optional tools."
    } else {
        Write-Host "All dependencies are installed. Ready to decompile."
    }
    exit 0
}
