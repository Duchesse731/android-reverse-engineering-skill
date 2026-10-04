# Decompile APK/XAPK/JAR/AAR with checked results and preserved partial sources.
param(
    [Alias('o')][string]$Output,
    [switch]$Deobf,
    [switch]$NoRes,
    [ValidateSet('jadx','fernflower','both')][string]$Engine = 'jadx',
    [ValidateRange(1,2147483)][int]$TimeoutSeconds = 600,
    [Parameter(Position=0)][string]$InputFile,
    [Alias('h')][switch]$Help
)
$ErrorActionPreference = 'Stop'
# Native failures are checked explicitly; stderr is diagnostic output.
$PSNativeCommandUseErrorActionPreference = $false
Add-Type -AssemblyName System.IO.Compression.FileSystem
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath) { $env:PATH = "$userPath;$env:PATH" }

function Show-Usage {
    Write-Host @'
Usage: decompile.ps1 [OPTIONS] <file.apk|file.xapk|file.jar|file.aar>
  -Output DIR         Output directory (default: <filename>-decompiled)
  -Engine ENGINE      jadx, fernflower, or both
  -Deobf              Enable deobfuscation
  -NoRes              Skip jadx resources
  -TimeoutSeconds N   Per external command timeout (default: 600)
  -Help               Show help
FERNFLOWER_JAR_PATH can select a Vineflower/Fernflower jar. APK conversion
requires dex2jar; AAR classes.jar and libs/*.jar are processed directly.
Exit 0 means all requested runs completed with usable Java sources.
Exit 1 means failure or partial output; partial sources are retained.
'@
}
if ($Help) { Show-Usage; exit 0 }
if (-not $InputFile -or -not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    Write-Host 'Error: specify an existing input file.' -ForegroundColor Red
    Show-Usage; exit 1
}
$inputFileAbs = (Resolve-Path -LiteralPath $InputFile).Path
$extLower = [IO.Path]::GetExtension($inputFileAbs).TrimStart('.').ToLowerInvariant()
if ($extLower -notin @('apk','xapk','jar','aar')) {
    Write-Host "Unsupported input extension: $extLower" -ForegroundColor Red; exit 1
}
$baseName = [IO.Path]::GetFileNameWithoutExtension($inputFileAbs)
if (-not $Output) { $Output = "$baseName-decompiled" }
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) {
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) {
        Write-Host 'Output path exists and is not a directory.' -ForegroundColor Red; exit 1
    }
    if (@(Get-ChildItem -LiteralPath $Output -Force).Count -gt 0) {
        Write-Host 'Output directory must be empty. Choose a fresh directory to avoid mixing runs.' -ForegroundColor Red; exit 1
    }
}

function Find-Tool {
    param([string[]]$Names, [string[]]$Candidates = @())
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}
function Find-FernflowerJar {
    foreach ($candidate in @($env:FERNFLOWER_JAR_PATH,
        "$env:USERPROFILE\.local\share\vineflower\vineflower.jar",
        "$env:USERPROFILE\fernflower\build\libs\fernflower.jar",
        "$env:USERPROFILE\vineflower\build\libs\vineflower.jar",
        "$env:USERPROFILE\fernflower\fernflower.jar",
        "$env:USERPROFILE\vineflower\vineflower.jar")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}
function Quote-NativeArgument {
    param([string]$Value)
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Tool {
    param([string]$Command, [string[]]$Arguments)
    $logRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $stdout = "$logRoot.out"; $stderr = "$logRoot.err"
    $process = $null; $timedOut = $false; $code = -1
    try {
        $argumentLine = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
        if ([IO.Path]::GetExtension($Command) -in @('.bat','.cmd')) {
            # cmd.exe needs one additional quote pair around the command line.
            # Disable delayed expansion to preserve exclamation marks in paths.
            if (($Command + ($Arguments -join '')) -match '[%\r\n]') {
                throw 'Batch tool paths/arguments containing percent signs or newlines are not supported.'
            }
            $argumentLine = '/d /v:off /s /c "' + (Quote-NativeArgument $Command) + ' ' + $argumentLine + '"'
            $Command = $env:ComSpec
        }
        $process = Start-Process -FilePath $Command -ArgumentList $argumentLine -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            # Stop the complete tree, including Java children of .bat launchers.
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & taskkill.exe /PID $process.Id /T /F 2>&1 | ForEach-Object { Write-Host $_ }
            } finally {
                $ErrorActionPreference = $previousPreference
                if (-not $process.HasExited) { $process.Kill() }
            }
            $process.WaitForExit()
        }
        $process.Refresh(); $code = $process.ExitCode
    } catch { Write-Host "Tool invocation failed: $_" -ForegroundColor Red }
    finally {
        foreach ($log in @($stdout,$stderr)) {
            if (Test-Path -LiteralPath $log) {
                Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ }
                Remove-Item -LiteralPath $log -Force
            }
        }
        if ($process) { $process.Dispose() }
    }
    if ($timedOut) { Write-Host "Tool timed out after $TimeoutSeconds seconds." -ForegroundColor Yellow }
    return [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut }
}
function New-Stage {
    param([string]$OutDir)
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $stage = Join-Path $OutDir ('.run-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $stage | Out-Null
    return $stage
}
function Publish-Stage {
    param([string]$Stage, [string]$OutDir)
    # Preserve this run's actual results even on timeout/failure. Never count
    # previous output as evidence that the current tool invocation succeeded.
    Get-ChildItem -LiteralPath $Stage -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $OutDir -Recurse -Force
    }
    Remove-Item -LiteralPath $Stage -Recurse -Force
}
function Invoke-Jadx {
    param([string]$OutDir, [string]$FileAbs)
    $tool = Find-Tool @('jadx','jadx.bat') @(
        "$env:USERPROFILE\.local\share\jadx\bin\jadx.bat",
        "$env:USERPROFILE\jadx\bin\jadx.bat", "$env:LOCALAPPDATA\jadx\bin\jadx.bat")
    if (-not $tool) { Write-Host 'jadx not found.' -ForegroundColor Red; return $false }
    $stage = New-Stage $OutDir
    try {
        $toolArgs = @('-d',$stage,'--show-bad-code')
        if ($Deobf) { $toolArgs += '--deobf' }
        if ($NoRes) { $toolArgs += '--no-res' }
        $result = Invoke-Tool $tool ($toolArgs + @($FileAbs))
        $count = @(Get-ChildItem -LiteralPath $stage -Recurse -Filter '*.java' -File).Count
        $ok = $result.ExitCode -eq 0 -and -not $result.TimedOut -and $count -gt 0
        Write-Host "jadx: $count Java files; exit=$($result.ExitCode); timeout=$($result.TimedOut)."
        if (-not $ok -and $count -gt 0) { Write-Host 'jadx partial output preserved; inspect warnings.' -ForegroundColor Yellow }
        if ($count -eq 0) { Write-Host 'jadx produced no usable Java sources.' -ForegroundColor Red }
        return $ok
    } finally { Publish-Stage $stage $OutDir }
}
function Invoke-Fernflower {
    param([string]$OutDir, [string]$FileAbs)
    $jar = Find-FernflowerJar
    $tool = Find-Tool @('vineflower','fernflower','vineflower.bat','fernflower.bat')
    $java = Find-Tool @('java')
    if (-not $tool -and (-not $jar -or -not $java)) {
        Write-Host 'Vineflower/Fernflower CLI or Java plus its JAR is required.' -ForegroundColor Red; return $false
    }
    $stage = New-Stage $OutDir
    $workspace = Join-Path ([IO.Path]::GetTempPath()) ('ff-' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $workspace | Out-Null
    try {
        $fileExt = [IO.Path]::GetExtension($FileAbs).ToLowerInvariant()
        $jars = @(); $conversionOk = $true
        if ($fileExt -eq '.apk') {
            $d2j = Find-Tool @('d2j-dex2jar','d2j-dex2jar.bat')
            if (-not $d2j) { Write-Host 'dex2jar is required for APK input.' -ForegroundColor Red; return $false }
            $converted = Join-Path $workspace 'converted.jar'
            $conversion = Invoke-Tool $d2j @('-f','-o',$converted,$FileAbs)
            $conversionOk = $conversion.ExitCode -eq 0 -and -not $conversion.TimedOut
            if (-not (Test-Path -LiteralPath $converted -PathType Leaf)) { Write-Host 'dex2jar produced no JAR.' -ForegroundColor Red; return $false }
            $jars = @($converted)
        } elseif ($fileExt -eq '.aar') {
            $aarDir = Join-Path $workspace 'aar'
            [IO.Compression.ZipFile]::ExtractToDirectory($FileAbs,$aarDir)
            $classesJar = Join-Path $aarDir 'classes.jar'
            if (Test-Path -LiteralPath $classesJar -PathType Leaf) { $jars += $classesJar }
            $libsDir = Join-Path $aarDir 'libs'
            if (Test-Path -LiteralPath $libsDir -PathType Container) {
                $jars += @(Get-ChildItem -LiteralPath $libsDir -Recurse -Filter '*.jar' -File | ForEach-Object { $_.FullName })
            }
            if ($jars.Count -eq 0) { Write-Host 'AAR contains no classes.jar or libs/*.jar.' -ForegroundColor Red; return $false }
        } else { $jars = @($FileAbs) }
        $allOk = $conversionOk; $index = 0
        foreach ($inputJar in $jars) {
            $index++
            $runDir = Join-Path $workspace "result-$index"
            New-Item -ItemType Directory -Path $runDir | Out-Null
            $ffArgs = @('-dgs=1','-mpm=60')
            if ($Deobf) { $ffArgs += '-ren=1' }
            $ffArgs += @($inputJar,$runDir)
            if ($jar -and $java) { $result = Invoke-Tool $java (@('-jar',$jar) + $ffArgs) }
            else { $result = Invoke-Tool $tool $ffArgs }
            $sources = Join-Path $stage 'sources'
            # Isolate AAR jars to avoid duplicate package/class names overwriting.
            if ($fileExt -eq '.aar') { $sources = Join-Path $sources ("$index-" + [IO.Path]::GetFileNameWithoutExtension($inputJar)) }
            New-Item -ItemType Directory -Path $sources -Force | Out-Null
            $resultJar = Join-Path $runDir ([IO.Path]::GetFileName($inputJar))
            if (Test-Path -LiteralPath $resultJar -PathType Leaf) {
                [IO.Compression.ZipFile]::ExtractToDirectory($resultJar,$sources)
            }
            # Engines also support direct directory output; retain those files.
            Get-ChildItem -LiteralPath $runDir -Recurse -File | Where-Object { $_.Extension -eq '.java' } | ForEach-Object {
                $relative = $_.FullName.Substring($runDir.Length).TrimStart([char[]]'\/')
                $destination = Join-Path $sources $relative
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
            }
            $count = @(Get-ChildItem -LiteralPath $sources -Recurse -Filter '*.java' -File).Count
            $ok = $result.ExitCode -eq 0 -and -not $result.TimedOut -and $count -gt 0
            if (-not $ok) { $allOk = $false }
            Write-Host "Fernflower $([IO.Path]::GetFileName($inputJar)): $count Java files; exit=$($result.ExitCode); timeout=$($result.TimedOut)."
        }
        if (-not $allOk) { Write-Host 'Fernflower failed or produced partial output; retained sources require review.' -ForegroundColor Yellow }
        return $allOk
    } catch { Write-Host "Fernflower failed: $_" -ForegroundColor Red; return $false }
    finally {
        Publish-Stage $stage $OutDir
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
function Invoke-DecompileSingle {
    param([string]$FileAbs, [string]$OutDir)
    Write-Host "Decompiling $FileAbs with $Engine"
    if ($Engine -eq 'jadx') { return (Invoke-Jadx $OutDir $FileAbs) }
    if ($Engine -eq 'fernflower') { return (Invoke-Fernflower $OutDir $FileAbs) }
    $jadxDir = Join-Path $OutDir 'jadx'; $ffDir = Join-Path $OutDir 'fernflower'
    $jadxOk = Invoke-Jadx $jadxDir $FileAbs
    $ffOk = Invoke-Fernflower $ffDir $FileAbs
    $jadxSources = Join-Path $jadxDir 'sources'
    if (Test-Path -LiteralPath $jadxSources) {
        $warnings = @(Get-ChildItem -LiteralPath $jadxSources -Recurse -Filter '*.java' -File |
            Select-String -Pattern 'JADX WARNING|JADX WARN|JADX ERROR|Code decompiled incorrectly' |
            Select-Object -ExpandProperty Path -Unique).Count
        Write-Host "jadx source files with warnings/errors: $warnings"
    }
    Write-Host "Engine completion: jadx=$jadxOk; fernflower=$ffOk"
    return ($jadxOk -and $ffOk)
}
$bundleDir = $null; $allOk = $true
try {
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
    if ($extLower -eq 'xapk') {
        $bundleDir = Join-Path ([IO.Path]::GetTempPath()) ('xapk-' + [guid]::NewGuid().ToString())
        [IO.Compression.ZipFile]::ExtractToDirectory($inputFileAbs,$bundleDir)
        $apks = @(Get-ChildItem -LiteralPath $bundleDir -Recurse -Filter '*.apk' -File | Sort-Object FullName)
        if ($apks.Count -eq 0) { throw 'No APK files found in XAPK.' }
        $manifest = Join-Path $bundleDir 'manifest.json'
        if (Test-Path -LiteralPath $manifest) { Copy-Item -LiteralPath $manifest -Destination (Join-Path $Output 'xapk-manifest.json') -Force }
        $index = 0; $codeApkCount = 0
        foreach ($apk in $apks) {
            $index++
            # Config/resource splits normally have no classes*.dex. Validate
            # each ZIP, but do not call a Java decompiler on resource-only APKs.
            $apkArchive = [IO.Compression.ZipFile]::OpenRead($apk.FullName)
            try {
                $hasDex = @($apkArchive.Entries | Where-Object {
                    $_.FullName -cmatch '^classes[0-9]*\.dex$'
                }).Count -gt 0
            } finally { $apkArchive.Dispose() }
            if (-not $hasDex) {
                Write-Host "Skipping resource-only APK (no top-level classes*.dex): $($apk.Name)"
                continue
            }
            $codeApkCount++
            $apkOutput = Join-Path $Output ("$index-" + $apk.BaseName)
            if (-not (Invoke-DecompileSingle $apk.FullName $apkOutput)) { $allOk = $false }
        }
        if ($codeApkCount -eq 0) { throw 'XAPK contains no code APK with top-level classes*.dex.' }
    } else {
        $allOk = Invoke-DecompileSingle $inputFileAbs $Output
        # Bundled APK wrappers may expose a base.apk in jadx resources.
        $jadxRoot = $Output
        if ($Engine -eq 'both') { $jadxRoot = Join-Path $Output 'jadx' }
        $resources = Join-Path $jadxRoot 'resources'
        if ($extLower -eq 'apk' -and $Engine -ne 'fernflower' -and (Test-Path -LiteralPath $resources)) {
            $innerApks = @(Get-ChildItem -LiteralPath $resources -Recurse -Filter '*.apk' -File)
            $baseApk = $innerApks | Where-Object { $_.Name -eq 'base.apk' } | Select-Object -First 1
            if ($baseApk) {
                foreach ($inner in ($innerApks | Where-Object { $_.Name -notmatch '^split_config\.' })) {
                    if (-not (Invoke-DecompileSingle $inner.FullName (Join-Path $Output $inner.BaseName))) { $allOk = $false }
                }
            }
        }
    }
} catch { Write-Host "Decompilation failed: $_" -ForegroundColor Red; $allOk = $false }
finally { if ($bundleDir -and (Test-Path -LiteralPath $bundleDir)) { Remove-Item -LiteralPath $bundleDir -Recurse -Force } }
if ($allOk) { Write-Host "Decompilation complete: $Output"; exit 0 }
Write-Host "Decompilation incomplete: inspect retained output in $Output" -ForegroundColor Yellow
exit 1
