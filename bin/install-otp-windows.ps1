# SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
# SPDX-License-Identifier: Apache-2.0

# Install OTP on the Windows benchmark runner.
#
# Three modes (selected automatically by `-OtpRef`):
#   1. Release tag (e.g. "OTP-28.0", "v28.0") — fetched from the
#      erlang/otp GitHub Releases as `otp_win64_<version>.exe`.
#   2. Branch / SHA (e.g. "master", "d900a834d0…") — resolved against
#      erlang/otp's `Build and check Erlang/OTP` workflow, downloading
#      the `otp_win32_installer` artifact from the most recent
#      successful run on that ref. (Despite the artifact name, the
#      file inside is the 64-bit installer.)
#   3. Manual override — pass `-InstallerUrl` or set
#      `OTP_WIN_INSTALLER_URL` to a stable URL pointing at an .exe.
#
# Modes 2 + 3 require `gh` CLI on PATH and a token with
# `actions:read` on erlang/otp (the standard `GITHUB_TOKEN` GHA
# provides is fine on public repos).
#
# Usage:
#   ./bin/install-otp-windows.ps1 -OtpRef OTP-28.0
#   ./bin/install-otp-windows.ps1 -OtpRef master
#   ./bin/install-otp-windows.ps1 -OtpRef <sha>
#   ./bin/install-otp-windows.ps1 -OtpRef foo -InstallerUrl <url>
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

$prefix = Join-Path $InstallRoot $OtpRef
$installer = Join-Path $env:TEMP "otp_win64_installer.exe"

if (Test-Path (Join-Path $prefix "bin\erl.exe")) {
    Write-Host "OTP $OtpRef already installed at $prefix"
    Write-Output $prefix
    exit 0
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

# Download the installer into $installer using whichever resolution
# strategy fits the ref.
function Fetch-FromUrl {
    param([string]$Url)
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $installer -UseBasicParsing
}

function Fetch-FromTag {
    param([string]$Ref)
    $tag = $Ref -replace "^v", "OTP-"
    $version = $tag -replace "^OTP-", ""

    # Two upstream homes for Windows installers, with disjoint coverage:
    #   * github.com/erlang/otp/releases/download/<tag>/...
    #     — every release from OTP-21.0 onwards.
    #   * erlang.org/download/...
    #     — every function release back to OTP-17.0, including all of
    #       OTP-20.x (which github releases is missing entirely).
    # Probe both before declaring an installer missing. Some patch
    # releases (e.g. OTP-25.1.2.1, an emergency security backport)
    # don't have an installer on either host — emit a `skipped=true`
    # GH Actions output and exit 0 so the workflow leaves a clean
    # hole in the dashboard instead of substituting a different
    # patch's binary.
    $urls = @(
        "https://github.com/erlang/otp/releases/download/$tag/otp_win64_$version.exe"
        "https://erlang.org/download/otp_win64_$version.exe"
    )

    $url = $null
    foreach ($candidate in $urls) {
        try {
            Invoke-WebRequest -Uri $candidate -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null
            $url = $candidate
            break
        } catch {
            $code = $null
            try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
            if ($code -ne 404) { throw }
            # 404 → fall through to the next candidate.
        }
    }

    if (-not $url) {
        Write-Host "::warning::No Windows installer published for $tag — skipping measure-windows leg"
        if ($env:GITHUB_OUTPUT) {
            "skipped=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
        exit 0
    }

    Fetch-FromUrl $url
}

function Fetch-FromCiArtifact {
    param([string]$Ref)

    # Find the most recent run of the build workflow on this ref that
    # actually produced an `otp_win32_installer` artifact. Two cases
    # leave a run on the list without the artifact:
    #
    #   * Run failed before the installer build step.
    #   * Upstream skips the installer build when a master push contains
    #     no C-level changes (the Windows installer takes a long time to
    #     build and isn't worth recutting for a pure-Erlang change).
    #
    # We can't tell which from the run's status alone, so we just check
    # the artifacts list of each candidate and walk back until one has
    # the file. Using a slightly older Windows binary is fine for
    # benchmarking purposes — the C runtime hasn't changed.
    #
    # Paginate because `?branch=master` interleaves runs from all
    # workflows on master; the "Build and check Erlang/OTP" runs can
    # be sparse and a quiet stretch pushes the artifact past page 1.
    #
    # TODO: drop most of this once the upstream PR enabling installer
    # builds on every push lands — the simple latest-run lookup will
    # then suffice.
    Write-Host "Locating erlang/otp build run for ref '$Ref' …"
    $runFilter = '[.workflow_runs[] | select(.name == "Build and check Erlang/OTP")][] | {id, head_sha, status, conclusion}'

    function Find-RunWithInstaller {
        param([string]$QueryParam, [string]$Value)
        for ($page = 1; $page -le 5; $page++) {
            $candidates = gh api "repos/erlang/otp/actions/runs?$QueryParam=$Value&per_page=100&page=$page" --jq $runFilter
            if (-not $candidates) { continue }
            foreach ($line in ($candidates -split "`n")) {
                if (-not $line) { continue }
                $r = $line | ConvertFrom-Json
                $hasArtifact = gh api "repos/erlang/otp/actions/runs/$($r.id)/artifacts" --jq '[.artifacts[] | select(.name == "otp_win32_installer")] | length'
                if ([int]$hasArtifact -gt 0) { return $r }
            }
        }
        return $null
    }

    $run = Find-RunWithInstaller "branch" $Ref
    if (-not $run) {
        # Fall back to head_sha lookup in case Ref is a SHA, not a branch.
        $run = Find-RunWithInstaller "head_sha" $Ref
    }

    if (-not $run) {
        # erlang/otp's installer build is skipped on master commits
        # that touch no C code (otp-ideas #34) — the Erlang-only
        # change wouldn't change the .exe, so upstream doesn't recut
        # one. Same `skipped=true` mechanism as Fetch-FromTag's
        # "no installer published" path: leave a clean hole in the
        # dashboard instead of failing the leg. The next master
        # merge that touches C code will produce an installer and
        # the run gets measured opportunistically.
        Write-Host "::warning::No 'Build and check Erlang/OTP' run with otp_win32_installer artifact found for ref '$Ref' — skipping measure-windows leg"
        if ($env:GITHUB_OUTPUT) {
            "skipped=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
        exit 0
    }
    Write-Host "Found run id=$($run.id) sha=$($run.head_sha) status=$($run.status) conclusion=$($run.conclusion)"

    # Pull the otp_win32_installer artifact (which is the 64-bit
    # installer despite the name — see header comment).
    $tmpDir = Join-Path $env:TEMP "otp_win_artifact"
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    gh run download $run.id --repo erlang/otp --name otp_win32_installer --dir $tmpDir
    if ($LASTEXITCODE -ne 0) {
        throw "gh run download failed (exit $LASTEXITCODE)"
    }

    $exe = Get-ChildItem -Path $tmpDir -Filter "otp_win64_*.exe" `
        | Select-Object -First 1
    if (-not $exe) {
        throw "no otp_win64_*.exe found inside artifact"
    }

    Move-Item -Force $exe.FullName $installer
}

if ($InstallerUrl) {
    Fetch-FromUrl $InstallerUrl
} elseif ($OtpRef -match "^(OTP-|v)\d") {
    Fetch-FromTag $OtpRef
} else {
    Fetch-FromCiArtifact $OtpRef
}

Write-Host "Installing to $prefix"
# /S = silent, /D=<path> = install dir (NSIS convention; must be last and unquoted)
$proc = Start-Process -FilePath $installer `
    -ArgumentList "/S", "/D=$prefix" `
    -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0) {
    throw "Installer exited $($proc.ExitCode)"
}

# Confirm erl runs. We don't try `-emu_flavor jit/emu` — flavor names
# changed across OTP versions (26/27: `smp`; 28+: `jit`/`emu`). The
# benchmark child sets ERL_FLAGS per-version when emu is requested.
#
# Pipe to `Out-Host` so the verification line goes to the host stream,
# not stdout — callers do `$prefix = ./install-otp-windows.ps1 ...` and
# would otherwise capture both the "erl ok" line and the prefix path,
# producing a corrupt PATH entry.
$erl = Join-Path $prefix "bin\erl.exe"
& $erl -noshell -eval 'io:format("erl ok ~s~n",[erlang:system_info(otp_release)]),halt()' | Out-Host

Remove-Item $installer -ErrorAction SilentlyContinue
Write-Output $prefix
