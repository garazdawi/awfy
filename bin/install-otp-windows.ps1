# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

# Install OTP on the Windows benchmark runner.
#
# Two modes:
#   1. Release tag (e.g. "OTP-28.0", "v28.0") — fetched from the
#      erlang/otp GitHub Releases as `otp_win64_<version>.exe`.
#   2. master / arbitrary SHA — fetched from the upstream OTP CI
#      master-build artifact ($OtpMasterInstallerUrl). The artifact
#      URL is configurable via the env var below or the -InstallerUrl
#      parameter, since the upstream URL pattern may shift.
#
# Usage (CI):
#   ./bin/install-otp-windows.ps1 -OtpRef master -InstallerUrl <url>
#   ./bin/install-otp-windows.ps1 -OtpRef OTP-28.0
#
# The script writes the install prefix path to stdout on success so
# callers can capture and add it to PATH.

param(
    [Parameter(Mandatory=$true)]
    [string]$OtpRef,
    [string]$InstallerUrl = $env:OTP_WIN_INSTALLER_URL,
    [string]$InstallRoot = "$env:USERPROFILE\.local\otp"
)

$ErrorActionPreference = "Stop"

function Resolve-InstallerUrl {
    param([string]$Ref, [string]$Url)

    if ($Url) { return $Url }

    # Treat refs that look like release tags as Releases lookups.
    if ($Ref -match "^(OTP-|v)\d") {
        $tag = $Ref -replace "^v", "OTP-"
        $version = $tag -replace "^OTP-", ""
        return "https://github.com/erlang/otp/releases/download/$tag/otp_win64_$version.exe"
    }

    throw "OtpRef '$Ref' is not a release tag — pass -InstallerUrl explicitly or set OTP_WIN_INSTALLER_URL"
}

$installerUrl = Resolve-InstallerUrl -Ref $OtpRef -Url $InstallerUrl
$prefix = Join-Path $InstallRoot $OtpRef
$installer = Join-Path $env:TEMP "otp_win64_installer.exe"

if (Test-Path (Join-Path $prefix "bin\erl.exe")) {
    Write-Host "OTP $OtpRef already installed at $prefix"
    Write-Output $prefix
    exit 0
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

Write-Host "Downloading $installerUrl"
Invoke-WebRequest -Uri $installerUrl -OutFile $installer -UseBasicParsing

Write-Host "Installing to $prefix"
# /S = silent, /D=<path> = install dir (NSIS convention; must be last and unquoted)
$proc = Start-Process -FilePath $installer `
    -ArgumentList "/S", "/D=$prefix" `
    -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0) {
    throw "Installer exited $($proc.ExitCode)"
}

# Confirm both emulator flavors are usable.
$erl = Join-Path $prefix "bin\erl.exe"
& $erl -emu_flavor jit -noshell -eval 'io:format("jit ok~n"),halt()'
& $erl -emu_flavor emu -noshell -eval 'io:format("emu ok~n"),halt()'

Remove-Item $installer -ErrorAction SilentlyContinue
Write-Output $prefix
