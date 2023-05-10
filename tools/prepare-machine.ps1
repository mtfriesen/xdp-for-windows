<#

.SYNOPSIS
This prepares a machine for running XDP.

.PARAMETER ForBuild
    Installs all the build-time dependencies.

.PARAMETER ForEbpfBuild
    Installs all the eBPF build-time dependencies.

.PARAMETER ForTest
    Installs all the run-time dependencies.

.PARAMETER ForFunctionalTest
    Installs all the run-time dependencies and configures machine for
    functional tests.

.PARAMETER ForSpinxskTest
    Installs all the run-time dependencies and configures machine for
    spinxsk tests.

.PARAMETER ForLogging
    Installs all the logging dependencies.

.PARAMETER NoReboot
    Does not reboot the machine.

.PARAMETER Force
    Forces the installation of the latest dependencies.

#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$ForBuild = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ForEbpfBuild = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ForTest = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ForFunctionalTest = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ForSpinxskTest = $false,

    [Parameter(Mandatory = $false)]
    [switch]$ForLogging = $false,

    [Parameter(Mandatory = $false)]
    [switch]$NoReboot = $false,

    [Parameter(Mandatory = $false)]
    [switch]$Force = $false,

    [Parameter(Mandatory = $false)]
    [switch]$Cleanup = $false
)

Set-StrictMode -Version 'Latest'
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

$RootDir = Split-Path $PSScriptRoot -Parent
. $RootDir\tools\common.ps1

if (!$ForBuild -and !$ForEbpfBuild -and !$ForTest -and !$ForFunctionalTest -and !$ForSpinxskTest -and !$ForLogging) {
    Write-Error 'Must one of -ForBuild, -ForTest, -ForFunctionalTest, -ForSpinxskTest, or -ForLogging'
}

$EbpfNugetVersion = "eBPF-for-Windows.0.9.0"
$EbpfNugetBuild = ""
$EbpfNuget = "$EbpfNugetVersion$EbpfNugetBuild.nupkg"
$EbpfNugetUrl = "https://github.com/microsoft/ebpf-for-windows/releases/download/v0.9.0/$EbpfNugetVersion$EbpfNugetBuild.nupkg"
$EbpfNugetRestoreDir = "$RootDir/packages/$EbpfNugetVersion"

# Flag that indicates something required a reboot.
$Reboot = $false

function Download-CoreNet-Deps {
    # Download and extract https://github.com/microsoft/corenet-ci.
    if (!(Test-Path "artifacts")) { mkdir artifacts }
    if ($Force -and (Test-Path "artifacts/corenet-ci-main")) {
        Remove-Item -Recurse -Force "artifacts/corenet-ci-main"
    }
    if (!(Test-Path "artifacts/corenet-ci-main")) {
        Invoke-WebRequest-WithRetry -Uri "https://github.com/microsoft/corenet-ci/archive/refs/heads/main.zip" -OutFile "artifacts\corenet-ci.zip"
        Expand-Archive -Path "artifacts\corenet-ci.zip" -DestinationPath "artifacts" -Force
        Remove-Item -Path "artifacts\corenet-ci.zip"
    }
}

function Download-eBpf-Nuget {
    # Download and extract private eBPF Nuget package.
    $NugetDir = "$RootDir/artifacts/nuget"
    if ($Force -and (Test-Path $NugetDir)) {
        Remove-Item -Recurse -Force $NugetDir
    }
    if (!(Test-Path $NugetDir)) {
        mkdir $NugetDir | Write-Verbose
    }

    if (!(Test-Path $NugetDir/$EbpfNuget)) {
        # Remove any old builds of the package.
        if (Test-Path $EbpfNugetRestoreDir) {
            Remove-Item -Recurse -Force $EbpfNugetRestoreDir
        }
        Remove-Item -Force $NugetDir/$EbpfNugetVersion*

        Invoke-WebRequest-WithRetry -Uri $EbpfNugetUrl -OutFile $NugetDir/$EbpfNuget
    }
}

function Download-Ebpf-Msi {
    # Download and extract private eBPF installer MSI package.
    $EbpfMsiUrl = Get-EbpfMsiUrl
    $EbpfMsiFullPath = Get-EbpfMsiFullPath

    if (!(Test-Path $EbpfMsiFullPath)) {
        $EbpfMsiDir = Split-Path $EbpfMsiFullPath
        if (!(Test-Path $EbpfMsiDir)) {
            mkdir $EbpfMsiDir | Write-Verbose
        }

        Invoke-WebRequest-WithRetry -Uri $EbpfMsiUrl -OutFile $EbpfMsiFullPath
    }
}

function Setup-TestSigning {
    # Check to see if test signing is enabled.
    $HasTestSigning = $false
    try { $HasTestSigning = ("$(bcdedit)" | Select-String -Pattern "testsigning\s+Yes").Matches.Success } catch { }

    # Enable test signing as necessary.
    if (!$HasTestSigning) {
        # Enable test signing.
        Write-Host "Enabling Test Signing. Reboot required!"
        bcdedit /set testsigning on | Write-Verbose
        if ($NoReboot) {
            Write-Warning "Enabling Test Signing requires reboot, but -NoReboot option specified."
        } else {
            $Script:Reboot = $true
        }
    }
}

# Installs the XDP certificates.
function Install-Certs {
    $CodeSignCertPath = "artifacts\CoreNetSignRoot.cer"
    if (!(Test-Path $CodeSignCertPath)) {
        Write-Error "$CodeSignCertPath does not exist!"
    }
    CertUtil.exe -f -addstore Root $CodeSignCertPath | Write-Verbose
    CertUtil.exe -f -addstore trustedpublisher $CodeSignCertPath | Write-Verbose
}

# Uninstalls the XDP certificates.
function Uninstall-Certs {
    try { CertUtil.exe -delstore Root "CoreNetTestSigning" } catch { }
    try { CertUtil.exe -delstore trustedpublisher "CoreNetTestSigning" } catch { }
}

function Setup-VcRuntime {
    $Installed = $false
    try { $Installed = Get-ChildItem -Path Registry::HKEY_CLASSES_ROOT\Installer\Dependencies | Where-Object { $_.Name -like "*VC,redist*" } } catch {}

    if (!$Installed -or $Force) {
        Write-Host "Installing VC++ runtime"

        if (!(Test-Path "artifacts")) { mkdir artifacts }
        Remove-Item -Force "artifacts\vc_redist.x64.exe" -ErrorAction Ignore

        # Download and install.
        Invoke-WebRequest-WithRetry -Uri "https://aka.ms/vs/16/release/vc_redist.x64.exe" -OutFile "artifacts\vc_redist.x64.exe"
        Invoke-Expression -Command "artifacts\vc_redist.x64.exe /install /passive"
    }
}

function Setup-VsTest {
    if (!(Get-VsTestPath) -or $Force) {
        Write-Host "Installing VsTest"

        if (!(Test-Path "artifacts")) { mkdir artifacts }
        Remove-Item -Recurse -Force "artifacts\Microsoft.TestPlatform" -ErrorAction Ignore

        # Download and extract.
        Invoke-WebRequest-WithRetry -Uri "https://www.nuget.org/api/v2/package/Microsoft.TestPlatform/16.11.0" -OutFile "artifacts\Microsoft.TestPlatform.zip"
        Expand-Archive -Path "artifacts\Microsoft.TestPlatform.zip" -DestinationPath "artifacts\Microsoft.TestPlatform" -Force
        Remove-Item -Path "artifacts\Microsoft.TestPlatform.zip"

        # Add to PATH.
        $RootDir = Split-Path $PSScriptRoot -Parent
        $Path = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $Path += ";$(Get-VsTestPath)"
        [Environment]::SetEnvironmentVariable("Path", $Path, "Machine")
        $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    }
}

if ($Cleanup) {
    if ($ForTest) {
        Uninstall-Certs
    }
} else {
    if ($ForBuild) {
        Download-CoreNet-Deps
        Download-eBpf-Nuget
        Copy-Item artifacts\corenet-ci-main\vm-setup\CoreNetSignRoot.cer artifacts\CoreNetSignRoot.cer
        Copy-Item artifacts\corenet-ci-main\vm-setup\CoreNetSign.pfx artifacts\CoreNetSign.pfx
    }

    if ($ForEbpfBuild) {
        if (!(Get-Command clang.exe)) {
            Write-Error "clang.exe is not detected"
        }

        if (!(cmd /c "clang --version 2>&1" | Select-String "clang version 11.")) {
            Write-Error "Compiling eBPF programs on Windows requires clang version 11"
        }

        $EbpfExportProgram = "$EbpfNugetRestoreDir/build/native/bin/export_program_info.exe"

        if (!(Test-Path $EbpfExportProgram)) {
            Write-Error "Missing eBPF helper export_program_info.exe. Is the NuGet package installed?"
        }

        Write-Verbose $EbpfExportProgram
        & $EbpfExportProgram | Write-Verbose
    }

    if ($ForFunctionalTest) {
        $ForTest = $true
        # Verifier configuration: standard flags on all XDP components, and NDIS.
        # The NDIS verifier is required, otherwise allocations NDIS makes on
        # behalf of XDP components (e.g. NBLs) will not be verified.
        Write-Verbose "verifier.exe /standard /driver xdp.sys xdpfnmp.sys xdpfnlwf.sys ndis.sys ebpfcore.sys"
        verifier.exe /standard /driver xdp.sys xdpfnmp.sys xdpfnlwf.sys ndis.sys ebpfcore.sys | Write-Verbose
        if (!$?) {
            $Reboot = $true
        }

        if ((Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl).CrashDumpEnabled -ne 1) {
            # Enable complete (kernel + user) system crash dumps
            Write-Verbose "reg.exe add HKLM\System\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /d 1 /t REG_DWORD /f"
            reg.exe add HKLM\System\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /d 1 /t REG_DWORD /f
            $Reboot = $true
        }
    }

    if ($ForSpinxskTest) {
        $ForTest = $true
        # Verifier configuration: standard flags with low resources simulation.
        # 599 - Failure probability (599/10000 = 5.99%)
        #       N.B. If left to the default value, roughly every 5 minutes verifier
        #       will fail all allocations within a 10 second interval. This behavior
        #       complicates the spinxsk socket setup statistics. Setting it to a
        #       non-default value disables this behavior.
        # ""  - Pool tag filter
        # ""  - Application filter
        # 1   - Delay (in minutes) after boot until simulation engages
        #       This is the lowest value configurable via verifier.exe.
        # WARNING: xdp.sys itself may fail to load due to low resources simulation.
        Write-Verbose "verifier.exe /standard /faults 599 `"`" `"`" 1  /driver xdp.sys ebpfcore.sys"
        verifier.exe /standard /faults 599 `"`" `"`" 1  /driver xdp.sys ebpfcore.sys | Write-Verbose
        if (!$?) {
            $Reboot = $true
        }

        if ((Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl).CrashDumpEnabled -ne 1) {
            # Enable complete (kernel + user) system crash dumps
            Write-Verbose "reg.exe add HKLM\System\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /d 1 /t REG_DWORD /f"
            reg.exe add HKLM\System\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /d 1 /t REG_DWORD /f
            $Reboot = $true
        }
    }

    if ($ForTest) {
        Setup-TestSigning
        Download-CoreNet-Deps
        Download-Ebpf-Msi
        Copy-Item artifacts\corenet-ci-main\vm-setup\CoreNetSignRoot.cer artifacts\CoreNetSignRoot.cer
        Copy-Item artifacts\corenet-ci-main\vm-setup\CoreNetSign.pfx artifacts\CoreNetSign.pfx
        Copy-Item artifacts\corenet-ci-main\vm-setup\devcon.exe C:\devcon.exe
        Copy-Item artifacts\corenet-ci-main\vm-setup\dswdevice.exe C:\dswdevice.exe
        Copy-Item artifacts\corenet-ci-main\vm-setup\kd.exe C:\kd.exe
        Copy-Item artifacts\corenet-ci-main\vm-setup\livekd64.exe C:\livekd64.exe
        Copy-Item artifacts\corenet-ci-main\vm-setup\notmyfault64.exe C:\notmyfault64.exe
        Copy-Item artifacts\corenet-ci-main\vm-setup\wsario.exe C:\wsario.exe
        Install-Certs
        Setup-VcRuntime
        Setup-VsTest
    }

    if ($ForLogging) {
        Download-CoreNet-Deps
    }
}

if ($Reboot -and !$NoReboot) {
    # Reboot the machine.
    Write-Host "Rebooting..."
    shutdown.exe /f /r /t 0
} elseif ($Reboot) {
    Write-Host "Reboot required."
}
