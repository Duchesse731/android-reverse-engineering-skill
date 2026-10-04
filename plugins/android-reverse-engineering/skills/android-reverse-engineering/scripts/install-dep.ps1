# install-dep.ps1 — Install a single dependency for Android reverse engineering
# Usage: install-dep.ps1 <dependency>
# Dependencies: java, jadx, vineflower, dex2jar, apktool, adb
#
# Exit codes:
#   0 — installed successfully
#   1 — installation failed
#   2 — requires manual action
param(
    [Parameter(Position=0)]
    [string]$Dep
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Show-Usage {
    Write-Host @"
Usage: install-dep.ps1 <dependency>

Install a dependency required for Android reverse engineering.

Available dependencies:
  java         Java JDK 17+
  jadx         jadx decompiler
  vineflower   Vineflower (Fernflower fork) decompiler
  dex2jar      DEX to JAR converter
  apktool      Android resource decoder
  adb          Android Debug Bridge

The script detects available package managers (winget, scoop, choco), then:
  - Installs using the first available manager
  - Falls back to direct download to %USERPROFILE%\.local\share\
  - Prints manual instructions if no option works
"@
    exit 0
}

if (-not $Dep -or $Dep -eq '-h' -or $Dep -eq '--help') { Show-Usage }

# --- Detect environment ---
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$hasScoop  = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
$hasChoco  = [bool](Get-Command choco -ErrorAction SilentlyContinue)

function Write-Info  { param($msg) Write-Host "[INFO] $msg" }
function Write-Ok    { param($msg) Write-Host "[OK] $msg" }
function Write-Fail  { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Manual {
    param($msg)
    Write-Host "[MANUAL] $msg" -ForegroundColor Yellow
    Write-Host "         Cannot install automatically. Please install manually and retry." -ForegroundColor Yellow
    exit 2
}

# --- Helper: download a file ---
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    Write-Info "Downloading $Url..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    $python = $null
    $pythonPrefix = @()
    foreach ($name in @('python3', 'python', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $prefix = @(); if ($name -eq 'py') { $prefix = @('-3') }
            $previousPreference = $ErrorActionPreference
            $probeCode = 1
            try {
                $ErrorActionPreference = 'Continue'
                $LASTEXITCODE = 1
                & $cmd.Source @prefix -c 'import sys; assert sys.version_info.major == 3' 2>$null
                $probeCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $previousPreference }
            if ($probeCode -eq 0) { $python = $cmd.Source; $pythonPrefix = $prefix; break }
        }
    }
    if (-not $python) { Remove-Item -LiteralPath $Dest -Force; throw 'Python 3 is required to verify release downloads.' }
    & $python @pythonPrefix (Join-Path $PSScriptRoot 'verify-release.py') $Url $Dest
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $Dest -Force; throw 'Release SHA-256 verification failed; use a package manager or verify manually.' }
}

# --- Helper: get latest GitHub release tag ---
function Get-GHLatestTag {
    param([string]$Repo)
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Uri $url -UseBasicParsing
    return $response.tag_name
}

# --- Helper: ensure directory on PATH ---
function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($currentPath -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$Dir;$currentPath", 'User')
        Write-Info "Added $Dir to user PATH. Restart your terminal to apply."
    }
    if ($env:PATH -notlike "*$Dir*") {
        $env:PATH = "$Dir;$env:PATH"
    }
}

$localBin   = Join-Path $env:USERPROFILE '.local\bin'
$localShare = Join-Path $env:USERPROFILE '.local\share'

# =====================================================================
# Dependency installers
# =====================================================================

function Get-JavaMajor {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = 1
        $lines = @(& java -version 2>&1)
        if ($LASTEXITCODE -ne 0) { return 0 }
        $text = $lines -join ' '
        if ($text -match '"(\d+)') { return [int]$Matches[1] }
        return 0
    } finally { $ErrorActionPreference = $previousPreference }
}
function Install-Java {
    $javaBin = Get-Command java -ErrorAction SilentlyContinue
    if ($javaBin -and (Get-JavaMajor) -ge 17) {
        Write-Ok 'Java 17+ already installed'
        return
    }

    Write-Info "Installing Java JDK 17+..."
    if ($hasWinget) {
        Write-Info "Installing via winget..."
        winget install --id Microsoft.OpenJDK.17 --accept-source-agreements --accept-package-agreements
    } elseif ($hasScoop) {
        Write-Info "Installing via scoop..."
        scoop install openjdk17
    } elseif ($hasChoco) {
        Write-Info "Installing via choco..."
        choco install openjdk17 -y
    } else {
        Write-Manual "Install Java JDK 17+ from https://adoptium.net/"
    }

    if ($LASTEXITCODE -ne 0) { throw 'Java package-manager installation failed.' }
    # Refresh persisted paths before validating the actual new Java version.
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' + [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
    # Verify
    $javaBin = Get-Command java -ErrorAction SilentlyContinue
    if ($javaBin -and (Get-JavaMajor) -ge 17) {
        Write-Ok "Java 17+ installed"
    } else {
        Write-Fail "Java installation may require a terminal restart for PATH update."
        exit 1
    }
}

function Install-Jadx {
    if (Get-Command jadx -ErrorAction SilentlyContinue) {
        Write-Ok "jadx already installed"
        return
    }

    # Try scoop first (cleanest on Windows)
    if ($hasScoop) {
        Write-Info "Installing jadx via scoop..."
        scoop install jadx
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
        if (Get-Command jadx -ErrorAction SilentlyContinue) {
            Write-Ok "jadx installed via scoop"
            return
        }
    }

    # Direct download from GitHub releases
    Write-Info "Installing jadx from GitHub releases..."
    $tag = Get-GHLatestTag "skylot/jadx"
    if (-not $tag) {
        Write-Fail "Could not determine latest jadx version."
        Write-Manual "Download from https://github.com/skylot/jadx/releases/latest"
    }

    $version = $tag -replace '^v', ''
    $url = "https://github.com/skylot/jadx/releases/download/$tag/jadx-$version.zip"
    $tmpZip = Join-Path $env:TEMP "jadx-$version.zip"

    Invoke-Download -Url $url -Dest $tmpZip

    $installDir = Join-Path $localShare 'jadx'
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $installDir -Force
    Remove-Item $tmpZip -Force

    # Add jadx\bin to PATH
    $jadxBin = Join-Path $installDir 'bin'
    Add-ToUserPath $jadxBin

    if (Get-Command jadx -ErrorAction SilentlyContinue) {
        Write-Ok "jadx $version installed to $installDir"
    } else {
        Write-Ok "jadx $version installed to $installDir"
        Write-Info "Restart your terminal or run: `$env:PATH = '$jadxBin;' + `$env:PATH"
    }
}

function Install-Vineflower {
    if (Get-Command vineflower -ErrorAction SilentlyContinue) {
        Write-Ok "Vineflower CLI already installed"
        return
    }
    if (Get-Command fernflower -ErrorAction SilentlyContinue) {
        Write-Ok "Fernflower CLI already installed"
        return
    }
    $ffCandidates = @(
        $env:FERNFLOWER_JAR_PATH,
        "$env:USERPROFILE\.local\share\vineflower\vineflower.jar",
        "$env:USERPROFILE\vineflower\vineflower.jar",
        "$env:USERPROFILE\fernflower\fernflower.jar"
    )
    foreach ($c in $ffCandidates) {
        if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) {
            Write-Ok "Vineflower/Fernflower JAR already exists: $c"
            return
        }
    }

    # Download JAR from GitHub releases
    Write-Info "Installing Vineflower from GitHub releases..."
    $tag = Get-GHLatestTag "Vineflower/vineflower"
    if (-not $tag) {
        Write-Fail "Could not determine latest Vineflower version."
        Write-Manual "Download from https://github.com/Vineflower/vineflower/releases/latest"
    }

    $version = $tag -replace '^v', ''
    $url = "https://github.com/Vineflower/vineflower/releases/download/$tag/vineflower-$version.jar"
    $installDir = Join-Path $localShare 'vineflower'
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    $tmpJar = Join-Path $env:TEMP "vineflower-$version-$([Guid]::NewGuid()).jar"
    Invoke-Download -Url $url -Dest $tmpJar
    Move-Item -LiteralPath $tmpJar -Destination (Join-Path $installDir 'vineflower.jar') -Force

    # Create wrapper batch file
    New-Item -ItemType Directory -Path $localBin -Force | Out-Null
    $wrapperPath = Join-Path $localBin 'vineflower.cmd'
    Set-Content -Path $wrapperPath -Value "@echo off`r`njava -jar `"$installDir\vineflower.jar`" %*"

    Add-ToUserPath $localBin
    [Environment]::SetEnvironmentVariable('FERNFLOWER_JAR_PATH', "$installDir\vineflower.jar", 'User')
    $env:FERNFLOWER_JAR_PATH = "$installDir\vineflower.jar"

    Write-Ok "Vineflower $version installed to $installDir\vineflower.jar"
    Write-Info "FERNFLOWER_JAR_PATH set to $installDir\vineflower.jar"
}

function Install-Dex2Jar {
    if ((Get-Command d2j-dex2jar -ErrorAction SilentlyContinue) -or
        (Get-Command d2j-dex2jar.bat -ErrorAction SilentlyContinue)) {
        Write-Ok "dex2jar already installed"
        return
    }

    Write-Info "Installing dex2jar from GitHub releases..."
    $tag = try { Get-GHLatestTag "ThexXTURBOXx/dex2jar" } catch { "2.4.35" }
    if (-not $tag) { $tag = "2.4.35" }

    $version = $tag -replace '^v', ''
    $url = "https://github.com/ThexXTURBOXx/dex2jar/releases/download/$tag/dex-tools-$version.zip"
    $tmpZip = Join-Path $env:TEMP "dex2jar-$version.zip"

    try {
        Invoke-Download -Url $url -Dest $tmpZip
    } catch {
        # Try alternate naming (pre-2.4.30 releases)
        $url = "https://github.com/ThexXTURBOXx/dex2jar/releases/download/$tag/dex-tools-v$version.zip"
        try {
            Invoke-Download -Url $url -Dest $tmpZip
        } catch {
            Write-Fail "Download failed."
            Write-Manual "Download from https://github.com/ThexXTURBOXx/dex2jar/releases/latest"
        }
    }

    $installDir = Join-Path $localShare 'dex2jar'
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $installDir -Force
    Remove-Item $tmpZip -Force

    # Find the actual bin directory (may be nested)
    $d2jBat = Get-ChildItem -Path $installDir -Recurse -Filter 'd2j-dex2jar.bat' | Select-Object -First 1
    if (-not $d2jBat) {
        $d2jBat = Get-ChildItem -Path $installDir -Recurse -Filter 'd2j-dex2jar.sh' | Select-Object -First 1
    }
    if (-not $d2jBat) {
        Write-Fail "Could not find d2j-dex2jar in extracted archive."
        Write-Manual "Download and extract manually from https://github.com/ThexXTURBOXx/dex2jar/releases"
    }

    $binDir = $d2jBat.DirectoryName
    Add-ToUserPath $binDir

    Write-Ok "dex2jar $version installed to $installDir"
}

function Install-Apktool {
    if (Get-Command apktool -ErrorAction SilentlyContinue) {
        Write-Ok "apktool already installed"
        return
    }

    if ($hasScoop) {
        Write-Info "Installing apktool via scoop..."
        scoop install apktool
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
    } elseif ($hasChoco) {
        Write-Info "Installing apktool via choco..."
        choco install apktool -y
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
    } else {
        Write-Manual "Install apktool from https://apktool.org/docs/install"
    }

    if (Get-Command apktool -ErrorAction SilentlyContinue) {
        Write-Ok "apktool installed"
    } else {
        Write-Fail "apktool installation may have failed."
        exit 1
    }
}

function Install-Adb {
    if (Get-Command adb -ErrorAction SilentlyContinue) {
        Write-Ok "adb already installed"
        return
    }

    if ($hasScoop) {
        Write-Info "Installing adb via scoop..."
        scoop install adb
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
    } elseif ($hasChoco) {
        Write-Info "Installing adb via choco..."
        choco install adb -y
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
    } elseif ($hasWinget) {
        Write-Info "Installing via winget..."
        winget install Google.PlatformTools --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw 'Package-manager installation failed.' }
    } else {
        Write-Manual "Install Android SDK Platform Tools from https://developer.android.com/tools/releases/platform-tools"
    }

    if (Get-Command adb -ErrorAction SilentlyContinue) {
        Write-Ok "adb installed"
    } else {
        Write-Fail "adb installation may have failed."
        exit 1
    }
}

# =====================================================================
# Dispatch
# =====================================================================

switch ($Dep) {
    'python3' {
        if ($hasWinget) { winget install --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements }
        elseif ($hasScoop) { scoop install python }
        elseif ($hasChoco) { choco install python -y }
        else { Write-Manual 'Install Python 3 from https://www.python.org/downloads/' }
        if ($LASTEXITCODE -ne 0) { throw 'Python installation failed.' }
    }
    'java'        { Install-Java }
    'jadx'        { Install-Jadx }
    'vineflower'  { Install-Vineflower }
    'fernflower'  { Install-Vineflower }
    'dex2jar'     { Install-Dex2Jar }
    'apktool'     { Install-Apktool }
    'adb'         { Install-Adb }
    default {
        Write-Host "Error: Unknown dependency '$Dep'" -ForegroundColor Red
        Write-Host "Available: java, jadx, vineflower, dex2jar, apktool, adb"
        exit 1
    }
}
