<#
.SYNOPSIS
  Bootstrap a Post Quantum Leap installation on Windows.

.DESCRIPTION
  ROAD-24. This does NOT replace the container runtime and does not pretend to:
  it automates the steps a Windows operator would otherwise copy out of
  INSTALLATION.md — check prerequisites, fetch the compose file, generate real
  secrets into .env, start the stack, print where to go.

  It writes the SAME .env and runs the SAME compose file a Linux operator uses.
  That is deliberate: one supported deployment shape, not a Windows-shaped
  variant that drifts away from it.

  Works with Docker or Podman. Podman Desktop is free for commercial use, which
  is the usual reason a Windows customer is reading this at all.

.EXAMPLE
  .\install-windows.ps1
  .\install-windows.ps1 -Runtime podman -InstallDir C:\pql
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'docker', 'podman')]
    [string]$Runtime = 'auto',
    [string]$InstallDir = "$PWD\postquantumleap",
    [string]$Branch = 'main'
)

# Stop on real errors, but never on a native command writing to stderr — plenty
# of healthy tools do, and treating that as failure paints a successful install
# red. (Learned the hard way on this project's scanner installer.)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }

# A 32-byte urlsafe-base64 value — the shape a Fernet key must have. Anything
# shorter or differently encoded is rejected by the application at boot.
function New-FernetKey {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
}

function New-Password {
    param([int]$Length = 28)
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    # Base64 minus the characters that need quoting in a DSN or an env file.
    ([Convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, $Length)
}

Write-Step 'Checking the container runtime'
$candidates = if ($Runtime -eq 'auto') { @('docker', 'podman') } else { @($Runtime) }
$engine = $null
foreach ($c in $candidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) {
        # Present on PATH is not the same as running — Docker Desktop can be
        # installed and stopped, and the failure then looks like a network error.
        & $c info *> $null
        if ($LASTEXITCODE -eq 0) { $engine = $c; break }
        Write-Warn "$c is installed but not running"
    }
}
if (-not $engine) {
    Write-Host ''
    Write-Host 'No running container runtime found.' -ForegroundColor Red
    Write-Host '  Podman Desktop  https://podman-desktop.io   (free for commercial use)'
    Write-Host '  Docker Desktop  https://docker.com          (paid above a company-size threshold)'
    Write-Host ''
    Write-Host 'Install one, start it, then run this script again.'
    return    # not `exit`: in the ISE and in `iex` pipelines, exit closes the host
}
Write-Ok "using $engine"

# ⟳ WHERE THIS ACTUALLY LANDS, said out loud. Security review, 2026-08-24.
#
# The default is `$PWD\postquantumleap`, and this script needs a container
# runtime — so it is commonly run from an ELEVATED PowerShell, where elevation
# has already reset the working directory to `C:\Windows\System32`. The install
# therefore lands in `C:\Windows\System32\postquantumleap` without the operator
# choosing that, and without noticing until they go looking for their `.env`.
#
# The DACL below makes that safe rather than merely visible. This warning is so
# the operator can put it somewhere they meant.
$resolvedParent = Split-Path -Parent $InstallDir
if ($resolvedParent -and ($resolvedParent -match '(?i)\\Windows\\System32/?$' -or
                          $resolvedParent -match '^[A-Za-z]:\\?$')) {
    Write-Warn "Installing into $InstallDir"
    Write-Warn 'That is under a system directory — elevation resets the working'
    Write-Warn 'directory, so this is probably not where you meant. Consider:'
    Write-Warn '  -InstallDir C:\ProgramData\PostQuantumLeap'
}

Write-Step "Preparing $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# ── LOCK THE DIRECTORY BEFORE ANYTHING SECRET IS WRITTEN INTO IT ─────────────
#
# ⟳ Security review, 2026-08-24. `.env` here holds EVERY secret the stack has —
# the Postgres passwords, SESSION_SECRET_KEY, SETTINGS_ENC_KEY and the initial
# admin password — and it was written with no permission handling at all, into a
# directory created with inheritance ON.
#
# That matters because of where this lands. The script needs a container runtime,
# so it is commonly run from an ELEVATED PowerShell — and elevation resets the
# working directory to `C:\Windows\System32`, making the default
# `$PWD\postquantumleap` resolve to `C:\Windows\System32\postquantumleap`. The
# documented alternative is `C:\pql`. Both parents carry the stock inheritable
# ACE granting BUILTIN\Users Read & Execute, so the child inherited it and every
# unprivileged local account could read the file.
#
# Inheritance is stripped and an explicit DACL applied: SYSTEM, the local
# Administrators group, and the installing user. Then it is VERIFIED — a failure
# to apply an ACL must not be discovered by an auditor later, so it aborts here
# rather than continuing to write secrets into a readable directory.
try {
    $acl = Get-Acl -Path $InstallDir
    # $true = protect from inheritance, $false = do NOT copy the inherited rules
    # down first. Copying them would keep the very ACE this exists to remove.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($who in @(
        'NT AUTHORITY\SYSTEM',
        'BUILTIN\Administrators',
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    )) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -Path $InstallDir -AclObject $acl

    # Verified, not assumed. `Set-Acl` can succeed and still leave a rule behind
    # if a principal failed to resolve.
    $stillReadable = (Get-Acl -Path $InstallDir).Access | Where-Object {
        $_.IdentityReference -match 'BUILTIN\\Users|Everyone|Authenticated Users'
    }
    if ($stillReadable) {
        Write-Host ''
        Write-Host "ERROR: $InstallDir is still readable by ordinary local users." -ForegroundColor Red
        Write-Host '       .env would hold every secret this stack has. Refusing to write it.' -ForegroundColor Red
        Write-Host '       Choose a directory you control, e.g. -InstallDir C:\ProgramData\PostQuantumLeap' -ForegroundColor Red
        return
    }
    Write-Ok 'install directory locked to SYSTEM, Administrators and you'
} catch {
    Write-Host ''
    Write-Host "ERROR: could not secure $InstallDir ($($_.Exception.Message))." -ForegroundColor Red
    Write-Host '       Refusing to write secrets into a directory whose permissions are unknown.' -ForegroundColor Red
    return
}

Set-Location $InstallDir

Write-Step 'Fetching the compose file'
# ⚠ THE PUBLIC DEPLOY REPOSITORY, NOT THE PRODUCT REPOSITORY.
#
# This pointed at ChristianJucker/PostQuantumLeap, which is PRIVATE: every
# anonymous fetch of it returns 404, so this script worked only for someone
# holding credentials — i.e. everyone except the customers it is written for.
# Measured 2026-08-25 before publishing the script: the private raw URL answers
# 404 and the public one answers 200.
#
# The public repo is also where docker-compose.yml is PUBLISHED to, by
# scripts/sync-deploy-repo.sh, so this fetches the same bytes the rest of the
# customer documentation tells people to use.
$base = "https://raw.githubusercontent.com/ChristianJucker/PostQuantumLeap-deploy/$Branch"
Invoke-WebRequest -Uri "$base/docker-compose.yml" -OutFile 'docker-compose.yml' -UseBasicParsing
Write-Ok 'docker-compose.yml'

if (Test-Path '.env') {
    Write-Warn '.env already exists — keeping it, secrets not regenerated'
    Write-Warn 'Regenerating SESSION_SECRET_KEY or SETTINGS_ENC_KEY would sign every'
    Write-Warn 'user out and orphan every stored SSO secret. Delete it deliberately if'
    Write-Warn 'that is what you want.'
} else {
    Write-Step 'Generating secrets'
    $adminPassword = New-Password -Length 20
    @(
        "POSTGRES_PASSWORD=$(New-Password)"
        "APP_DB_PASSWORD=$(New-Password)"
        "SESSION_SECRET_KEY=$(New-Password -Length 48)"
        "SETTINGS_ENC_KEY=$(New-FernetKey)"
        "INITIAL_ADMIN_USERNAME=admin@example.invalid"
        "INITIAL_ADMIN_PASSWORD=$adminPassword"
        "ENV=production"
    ) | Set-Content -Path '.env' -Encoding ascii
    # The directory's DACL is inherited by this file, and the directory is
    # already verified above. Stated rather than assumed, because a reader
    # checking whether the secrets are protected should not have to infer it.
    Write-Ok '.env written with freshly generated values (inherits the locked DACL)'
}

Write-Step "Starting the stack ($engine compose up -d)"
& $engine compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "compose failed (exit $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "Logs:  $engine compose logs"
    if ($engine -eq 'podman') {
        Write-Host ''
        Write-Host 'If this failed binding port 80 or 443, that is rootless Podman refusing'
        Write-Host 'a privileged port. INSTALLATION.md section 4 has both fixes.'
    }
    return
}

Write-Host ''
Write-Ok 'Post Quantum Leap is starting.'
Write-Host '    Open      https://localhost'
Write-Host '    Sign in   admin@example.invalid  /  the INITIAL_ADMIN_PASSWORD in .env'
Write-Host '    Logs      ' -NoNewline; Write-Host "$engine compose logs -f"
Write-Host ''
Write-Warn 'The browser will warn about the certificate until you configure TLS'
Write-Warn 'properly — INSTALLATION.md section 9 covers the four supported modes.'
