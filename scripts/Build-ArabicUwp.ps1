[CmdletBinding()]
param(
    [string]$WorkRoot = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'wwhd-arabic-build' } else { Join-Path ([IO.Path]::GetTempPath()) 'wwhd-arabic-build' }),
    [string]$OutputDirectory = $(if ($env:GITHUB_WORKSPACE) { Join-Path $env:GITHUB_WORKSPACE 'dist' } else { Join-Path (Get-Location) 'dist' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$reportPath = Join-Path $repoRoot 'build-report.txt'

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    Write-Host ("> $FilePath " + ($Arguments -join ' '))
    & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_.ToString() }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$FilePath failed with exit code $code"
    }
}

function Reset-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path`: expected $Expected, got $actual"
    }
    Write-Host "Verified SHA-256 $actual  $Path"
}

function Get-SourceArchive {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$DownloadDirectory
    )
    $name = [IO.Path]::GetFileName($Url)
    $archive = Join-Path $DownloadDirectory $name
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $archive
    Assert-Sha256 -Path $archive -Expected $Sha256
    $extract = Join-Path $DownloadDirectory ([IO.Path]::GetFileNameWithoutExtension($name) + '-extract')
    Reset-Directory $extract
    Invoke-Native 'tar.exe' '-xzf' $archive '-C' $extract
    $top = @(Get-ChildItem $extract -Directory)
    if ($top.Count -ne 1) {
        throw "Expected one source directory in $archive, found $($top.Count)"
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }
    Move-Item $top[0].FullName $Destination
}

function Import-VisualStudioEnvironment {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere not found at $vswhere"
    }
    $install = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    if (-not $install) {
        $install = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
    }
    if (-not $install) {
        throw 'No Visual Studio installation with C++ build tools was found'
    }
    $devCmd = Join-Path $install 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $devCmd)) {
        throw "VsDevCmd.bat not found at $devCmd"
    }
    Write-Host "Importing Visual Studio environment from $devCmd"
    $command = 'call "{0}" -arch=x64 -host_arch=x64 && set' -f $devCmd
    $lines = & cmd.exe /d /c $command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $lines | ForEach-Object { Write-Host $_.ToString() }
        throw "VsDevCmd failed with exit code $code"
    }
    foreach ($line in $lines) {
        $text = $line.ToString()
        if ($text -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    Write-Host "VCToolsInstallDir=$env:VCToolsInstallDir"
    Write-Host "WindowsSdkDir=$env:WindowsSdkDir"
}

function New-ImportLibrary {
    param(
        [Parameter(Mandatory)][string]$Dll,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$ReadObj,
        [Parameter(Mandatory)][string]$LibTool,
        [string[]]$DataExports = @()
    )
    $exportText = & $ReadObj '--coff-exports' $Dll 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $exportText | ForEach-Object { Write-Host $_.ToString() }
        throw "Could not read exports from $Dll"
    }
    $names = @($exportText | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '^\s*Name:\s*(\S+)\s*$') {
            $matches[1]
        }
    } | Sort-Object -Unique)
    if ($names.Count -eq 0) {
        throw "No exports found in $Dll"
    }
    $def = [IO.Path]::ChangeExtension($Output, '.def')
    $lines = @("LIBRARY $([IO.Path]::GetFileName($Dll))", 'EXPORTS')
    foreach ($name in $names) {
        if ($DataExports -contains $name) {
            $lines += "    $name DATA"
        } else {
            $lines += "    $name"
        }
    }
    $parent = Split-Path -Parent $Output
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllLines($def, $lines, [Text.Encoding]::ASCII)
    Invoke-Native $LibTool '/nologo' "/def:$def" '/machine:x64' "/out:$Output"
    if (-not (Test-Path $Output)) {
        throw "Import library was not created: $Output"
    }
    Write-Host "Generated $Output from $($names.Count) exports"
}

function Copy-RobocopyTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    & robocopy.exe $Source $Destination /E /XD .git /NFL /NDL /NJH /NJS /NP | ForEach-Object { Write-Host $_.ToString() }
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "robocopy failed with exit code $code"
    }
}

$exitCode = 0
Start-Transcript -Path $reportPath -Force | Out-Null
try {
    Write-Host "Repository: $repoRoot"
    Write-Host "Work directory: $WorkRoot"
    Write-Host "Output directory: $OutputDirectory"
    Reset-Directory $WorkRoot
    Reset-Directory $OutputDirectory
    $downloads = Join-Path $WorkRoot 'downloads'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null

    $baseCommit = 'f10b56621ed13e0053e7cf8190e740834377e45a'
    $uwpTag = 'v0.1.4'
    $originalSha256 = 'dc2855025e85d8019ba072621b63175e6f5b800f1c6f617f98cee00b13974dbb'
    $rtlSha256 = '49197efc35d296a45727ce584ed2e703e4c61b14303b551cc5ec1b3fc97917ea'
    $rtlTestSha256 = 'a8365cf017e8d09c378402de66b3b574d994746590f3da5196661b081c966738'

    Write-Host '=== Fetch and combine the pinned source trees ==='
    $source = Join-Path $WorkRoot 'source'
    $overlay = Join-Path $WorkRoot 'uwp-overlay'
    Invoke-Native 'git.exe' 'init' $source
    Invoke-Native 'git.exe' '-C' $source 'config' 'core.autocrlf' 'false'
    Invoke-Native 'git.exe' '-C' $source 'remote' 'add' 'origin' 'https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp.git'
    Invoke-Native 'git.exe' '-C' $source 'fetch' '--depth' '1' 'origin' $baseCommit
    Invoke-Native 'git.exe' '-C' $source 'checkout' '--detach' 'FETCH_HEAD'
    Invoke-Native 'git.exe' '-c' 'core.autocrlf=false' 'clone' '--depth' '1' '--branch' $uwpTag 'https://github.com/JYRS20/WWHD-UWP.git' $overlay
    Copy-RobocopyTree -Source $overlay -Destination $source
    Copy-Item -Path (Join-Path $repoRoot 'patch\*') -Destination $source -Recurse -Force
    Assert-Sha256 -Path (Join-Path $source 'runtime\src\rtl_text.cpp') -Expected $rtlSha256
    Assert-Sha256 -Path (Join-Path $source 'runtime\tools\rtl_text_test.cpp') -Expected $rtlTestSha256

    Write-Host '=== Download and unpack the original signed release ==='
    $originalZip = Join-Path $downloads 'wwhd-uwp-0.1.4-x64.zip'
    Invoke-WebRequest -Uri 'https://github.com/JYRS20/WWHD-UWP/releases/download/v0.1.4/wwhd-uwp-0.1.4-x64.zip' -OutFile $originalZip
    Assert-Sha256 -Path $originalZip -Expected $originalSha256
    $originalRelease = Join-Path $WorkRoot 'original-release'
    Expand-Archive -Path $originalZip -DestinationPath $originalRelease
    $originalAppx = Get-ChildItem $originalRelease -Recurse -Filter 'wwhd-uwp-*.appx' | Select-Object -First 1
    if (-not $originalAppx) {
        throw 'The original game APPX was not found'
    }
    $layout = Join-Path $WorkRoot 'appx-layout'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($originalAppx.FullName, $layout)
    $originalExeHash = (Get-FileHash -Algorithm SHA256 (Join-Path $layout 'wwhd-uwp-game.exe')).Hash.ToLowerInvariant()
    Write-Host "Original executable SHA-256: $originalExeHash"

    Write-Host '=== Initialize the Windows C++ toolchain ==='
    Import-VisualStudioEnvironment
    $llvmBin = 'C:\Program Files\LLVM\bin'
    $clangCl = Join-Path $llvmBin 'clang-cl.exe'
    $readObj = Join-Path $llvmBin 'llvm-readobj.exe'
    $libTool = (Get-Command 'lib.exe' -ErrorAction Stop).Source
    foreach ($tool in @($clangCl, $readObj, $libTool)) {
        if (-not (Test-Path $tool)) {
            throw "Required tool not found: $tool"
        }
    }
    Invoke-Native $clangCl '--version'

    Write-Host '=== Generate import libraries for the unchanged packaged DLLs ==='
    $sdlBuild = Join-Path $WorkRoot 'imports\sdl'
    $clangBuild = Join-Path $WorkRoot 'imports\clang'
    $pythonBuild = Join-Path $WorkRoot 'imports\python'
    New-Item -ItemType Directory -Path $sdlBuild, (Join-Path $clangBuild 'lib'), (Join-Path $clangBuild 'bin'), $pythonBuild -Force | Out-Null
    New-ImportLibrary -Dll (Join-Path $layout 'SDL3.dll') -Output (Join-Path $sdlBuild 'SDL3.lib') -ReadObj $readObj -LibTool $libTool
    New-ImportLibrary -Dll (Join-Path $layout 'wwhd-clang-bridge.dll') -Output (Join-Path $clangBuild 'lib\wwhd-clang-bridge.lib') -ReadObj $readObj -LibTool $libTool
    New-ImportLibrary -Dll (Join-Path $layout 'wwhd-python.dll') -Output (Join-Path $pythonBuild 'python311.lib') -ReadObj $readObj -LibTool $libTool -DataExports @('_Py_NoneStruct')
    Copy-Item (Join-Path $layout 'SDL3.dll') (Join-Path $sdlBuild 'SDL3.dll')
    Copy-Item (Join-Path $layout 'wwhd-clang-bridge.dll') (Join-Path $clangBuild 'bin\wwhd-clang-bridge.dll')
    Copy-Item (Join-Path $layout 'wwhd-python.dll') (Join-Path $pythonBuild 'wwhd-python.dll')

    Write-Host '=== Fetch the pinned public build dependencies ==='
    $deps = Join-Path $WorkRoot 'deps'
    $sdlSource = Join-Path $deps 'SDL'
    $vulkanSource = Join-Path $deps 'Vulkan-Headers'
    Get-SourceArchive -Url 'https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz' -Sha256 '9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3' -Destination $sdlSource -DownloadDirectory $downloads
    Get-SourceArchive -Url 'https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.363.tar.gz' -Sha256 'cbaf687d3c59b9666fe080e7f8396b6b4f4d344a768ee6b337c59852f4526b68' -Destination $vulkanSource -DownloadDirectory $downloads
    $hostDeps = Join-Path $source '.local\host-tools\_deps'
    Get-SourceArchive -Url 'https://github.com/KhronosGroup/glslang/archive/refs/tags/16.0.0.tar.gz' -Sha256 '172385478520335147d3b03a1587424af0935398184095f24beab128a254ecc7' -Destination (Join-Path $hostDeps 'glslang-src') -DownloadDirectory $downloads
    Get-SourceArchive -Url 'https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz' -Sha256 '17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c' -Destination (Join-Path $hostDeps 'zlib-src') -DownloadDirectory $downloads

    Write-Host '=== Build the embedded Python host against the original Python DLL ==='
    $pythonSource = Join-Path $deps 'cpython'
    Invoke-Native 'git.exe' '-c' 'core.autocrlf=false' 'clone' '--depth' '1' '--branch' 'v3.11.17' 'https://github.com/python/cpython.git' $pythonSource
    Invoke-Native 'git.exe' '-C' $pythonSource 'apply' (Join-Path $source 'platforms\uwp-python\patches\cpython-3.11.17-uwp.patch')
    $pythonHostObj = Join-Path $pythonBuild 'python_host.obj'
    $pythonHostLib = Join-Path $pythonBuild 'wwhd-python-host.lib'
    $pythonCompile = @(
        '/c', '/EHsc', '/W2', '/MD', '/std:c++17',
        '/DWIN32', '/DWINVER=0x0A00', '/D_WIN32_WINNT=0x0A00',
        '/DNTDDI_VERSION=0x0A000008', '/DWINAPI_FAMILY=WINAPI_FAMILY_APP', '/D_CRT_APP',
        "/I$(Join-Path $source 'platforms\uwp-python')",
        "/I$(Join-Path $pythonSource 'Include')",
        "/I$(Join-Path $pythonSource 'PC')",
        "/Fo$pythonHostObj",
        (Join-Path $source 'platforms\uwp-python\python_host.cpp')
    )
    Invoke-Native $clangCl @pythonCompile
    Invoke-Native $libTool '/nologo' "/out:$pythonHostLib" $pythonHostObj

    Write-Host '=== Compile and run the patched RTL regression test ==='
    $testExe = Join-Path $WorkRoot 'rtl_text_test.exe'
    Invoke-Native $clangCl '/std:c++17' '/EHsc' '/W4' '/UNDEBUG' "/I$(Join-Path $source 'runtime\src')" (Join-Path $source 'runtime\tools\rtl_text_test.cpp') (Join-Path $source 'runtime\src\rtl_text.cpp') "/Fe$testExe"
    Invoke-Native $testExe

    Write-Host '=== Configure and compile the patched UWP runtime ==='
    $build = Join-Path $WorkRoot 'build'
    $cmake = (Get-Command 'cmake.exe' -ErrorAction Stop).Source
    $configure = @(
        '-S', (Join-Path $source 'platforms\uwp-game'), '-B', $build, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_C_COMPILER=$clangCl",
        "-DCMAKE_CXX_COMPILER=$clangCl",
        "-DWWHD_SDL_SOURCE=$sdlSource",
        "-DWWHD_SDL_BUILD=$sdlBuild",
        "-DWWHD_VULKAN_HEADERS=$(Join-Path $vulkanSource 'include')",
        '-DWWHD_DYNAMIC_GAMECODE=ON',
        '-DWWHD_UNIFIED_PREPARATION=ON',
        "-DWWHD_CLANG_BUILD=$clangBuild",
        "-DWWHD_PYTHON_BUILD=$pythonBuild"
    )
    Invoke-Native $cmake @configure
    Invoke-Native $cmake '--build' $build '--target' 'wwhd-uwp-game' '--parallel' '4'
    $builtExe = Join-Path $build 'wwhd-uwp-game.exe'
    if (-not (Test-Path $builtExe)) {
        throw "Built executable not found: $builtExe"
    }
    $builtExeHash = (Get-FileHash -Algorithm SHA256 $builtExe).Hash.ToLowerInvariant()
    if ($builtExeHash -eq $originalExeHash) {
        throw 'The rebuilt executable is unexpectedly identical to the original'
    }
    Write-Host "Patched executable SHA-256: $builtExeHash"

    Write-Host '=== Repack the APPX with the patched executable ==='
    Copy-Item $builtExe (Join-Path $layout 'wwhd-uwp-game.exe') -Force
    foreach ($metadata in @('[Content_Types].xml', 'AppxBlockMap.xml', 'AppxSignature.p7x', 'AppxMetadata')) {
        $path = Join-Path $layout $metadata
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force
        }
    }
    $manifestPath = Join-Path $layout 'AppxManifest.xml'
    $manifest = [IO.File]::ReadAllText($manifestPath)
    if (-not $manifest.Contains('Version="0.1.4.0"')) {
        throw 'The original APPX manifest version was not 0.1.4.0'
    }
    $manifest = $manifest.Replace('Version="0.1.4.0"', 'Version="0.1.4.1"')
    $manifest = $manifest.Replace('<DisplayName>WWHD UWP</DisplayName>', '<DisplayName>WWHD UWP Arabic Fix</DisplayName>')
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
    $packageDir = Join-Path $OutputDirectory 'package'
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    $appxOut = Join-Path $packageDir 'wwhd-uwp-0.1.4.1-arabic-fix-x64.appx'
    $sdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $sdk = Get-ChildItem $sdkRoot -Directory | Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $sdk) {
        throw 'No Windows SDK packaging tools were found'
    }
    $makeAppx = Join-Path $sdk.FullName 'x64\makeappx.exe'
    $signTool = Join-Path $sdk.FullName 'x64\signtool.exe'
    Invoke-Native $makeAppx 'pack' '/o' '/d' $layout '/p' $appxOut

    Write-Host '=== Sign and verify the fixed APPX ==='
    $cert = $null
    $pfx = Join-Path $WorkRoot 'signing-temporary.pfx'
    $cer = Join-Path $packageDir 'WWHD-Arabic-Fix.cer'
    try {
        $cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=WWHDRecompDevelopment' -FriendlyName 'WWHD Arabic Fix Build' -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3') -NotAfter (Get-Date).AddYears(2)
        $passwordText = [Guid]::NewGuid().ToString('N')
        $password = ConvertTo-SecureString $passwordText -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $password | Out-Null
        Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
        & $signTool 'sign' '/fd' 'SHA256' '/f' $pfx '/p' $passwordText '/v' $appxOut 2>&1 | ForEach-Object { Write-Host $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw 'SignTool could not sign the APPX'
        }
        Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
        Invoke-Native $signTool 'verify' '/pa' '/v' $appxOut
    } finally {
        if (Test-Path $pfx) {
            Remove-Item $pfx -Force
        }
        if ($cert) {
            Remove-Item (Join-Path 'Cert:\CurrentUser\My' $cert.Thumbprint) -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path 'Cert:\CurrentUser\Root' $cert.Thumbprint) -Force -ErrorAction SilentlyContinue
        }
        $passwordText = $null
        $password = $null
    }

    Write-Host '=== Assemble the downloadable ZIP ==='
    $vclibs = Get-ChildItem $originalRelease -Recurse -Filter 'Microsoft.VCLibs.x64.14.00.appx' | Select-Object -First 1
    if (-not $vclibs) {
        throw 'The original VCLibs package was not found'
    }
    Copy-Item $vclibs.FullName (Join-Path $packageDir $vclibs.Name)
    Copy-Item (Join-Path $repoRoot 'ARABIC_FIX_NOTES.md') (Join-Path $packageDir 'ARABIC_FIX_NOTES.md')
    $readme = @'
# WWHD UWP 0.1.4 Arabic Fix

This package contains a newly compiled x64 UWP runtime using JYRS20/WWHD-UWP v0.1.4 and the supplied Arabic shaping fix.

## Install

1. Install `Microsoft.VCLibs.x64.14.00.appx` if your Xbox does not already have this dependency.
2. If Device Portal requests the signing certificate, install `WWHD-Arabic-Fix.cer` as a trusted developer/root certificate. This build uses a new self-signed certificate; it is not signed by the original author.
3. Install `wwhd-uwp-0.1.4.1-arabic-fix-x64.appx` through Xbox Device Portal and set the application type to **Game** in Dev Home.
4. If the device refuses to update the original v0.1.4 package because its signature changed, back up any needed local data, uninstall the old package, and install this one.

Only the unmodified original USA game release is supported, matching the upstream v0.1.4 requirements. No game files or keys are included.

## Validation

- The patched RTL/shaping regression test passed on Windows.
- The UWP runtime was compiled from source with Clang and the Windows SDK.
- The APPX was packed with MakeAppx and its signature was verified with SignTool.
- Xbox/in-game rendering has not been tested by this build pipeline. The active game font must contain the contextual Arabic glyphs.

See `ARABIC_FIX_NOTES.md`, `BUILD-INFO.txt`, and `SHA256SUMS.txt` for details.
'@
    [IO.File]::WriteAllText((Join-Path $packageDir 'README.md'), $readme, [Text.UTF8Encoding]::new($false))
    $appxHash = (Get-FileHash -Algorithm SHA256 $appxOut).Hash.ToLowerInvariant()
    $buildInfo = @(
        'WWHD UWP 0.1.4 Arabic Fix - build provenance',
        '',
        "Built UTC: $([DateTime]::UtcNow.ToString('o'))",
        "Workflow run: $env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID",
        "Base source: https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp/commit/$baseCommit",
        "UWP overlay: https://github.com/JYRS20/WWHD-UWP/releases/tag/$uwpTag",
        "Original release ZIP SHA-256: $originalSha256",
        "Patched rtl_text.cpp SHA-256: $rtlSha256",
        "Patched rtl_text_test.cpp SHA-256: $rtlTestSha256",
        "Original wwhd-uwp-game.exe SHA-256: $originalExeHash",
        "Rebuilt wwhd-uwp-game.exe SHA-256: $builtExeHash",
        "Signed APPX SHA-256: $appxHash",
        "Signing certificate SHA-256 thumbprint: $($cert.Thumbprint)",
        '',
        'The unchanged SDL3, Clang bridge, Python, Mesa Dozen, DXIL, assets, tools and VCLibs payloads came from the verified original v0.1.4 release. The main runtime executable and Python host static library were rebuilt.'
    )
    [IO.File]::WriteAllLines((Join-Path $packageDir 'BUILD-INFO.txt'), $buildInfo, [Text.Encoding]::UTF8)
    $checksumFiles = Get-ChildItem $packageDir -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name
    $checksumLines = $checksumFiles | ForEach-Object { "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant(), $_.Name }
    [IO.File]::WriteAllLines((Join-Path $packageDir 'SHA256SUMS.txt'), $checksumLines, [Text.Encoding]::ASCII)
    $zipOut = Join-Path $OutputDirectory 'wwhd-uwp-0.1.4-arabic-fix-x64.zip'
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipOut -CompressionLevel Optimal
    if (-not (Test-Path $zipOut)) {
        throw 'The final ZIP was not created'
    }
    Write-Host "BUILD_OUTPUT=$zipOut"
    Write-Host "BUILD_APPX_SHA256=$appxHash"
    Write-Host "BUILD_ZIP_SHA256=$((Get-FileHash -Algorithm SHA256 $zipOut).Hash.ToLowerInvariant())"
} catch {
    Write-Host ('BUILD FAILED: ' + $_.Exception.ToString())
    Write-Host ($_.ScriptStackTrace | Out-String)
    $exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
