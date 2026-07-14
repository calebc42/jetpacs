<#
.SYNOPSIS
Deploy the jetpacs foundation bundle — and any Tier-1 app bundles — to
the connected Android device.

.DESCRIPTION
Default: rebuild jetpacs-core.el from emacs/core/*.el via WSL Emacs, then
adb-push it (plus every path in -Bundles) to /sdcard/Documents/jetpacs/.
Termux is not debuggable, so adb cannot write into /data/data/com.termux
directly — the starter init (docs/starter-init.el) adopts newer staged
bundles from /sdcard/Documents/jetpacs (the shared onboarding + deploy
slot) at Emacs startup, newest copy wins.

App bundles are not built here — each app repo builds its own. Pass the
built file:

    # foundation only
    .\deploy.ps1

    # foundation + the Glasspane app bundle (from its own repo checkout)
    .\deploy.ps1 -Bundles ..\glasspane\glasspane.el
    .\deploy.ps1 -Bundles \\wsl.localhost\Debian\home\me\pkb\projects\Glasspane\glasspane.el

    # foundation + the hello demo app
    .\deploy.ps1 -Bundles emacs\apps\jetpacs-hello.el

.PARAMETER Bundles
Extra single-file elisp bundles to push alongside jetpacs-core.el, each
staged under its own basename.

.PARAMETER Ssh
Push straight into Termux's home (~/.emacs.d/elisp/) over Termux sshd —
a true direct drop, no staging or restart-adopt needed. One-time setup
inside Termux:
    pkg install openssh && passwd && sshd
Optional, for passwordless pushes: append your Windows public key
(~/.ssh/id_ed25519.pub) to ~/.ssh/authorized_keys in Termux.
sshd must be running on the device when you deploy (`sshd` in Termux).

.PARAMETER Apk
Also build and install the companion app (gradlew installDebug).
#>
param(
    [string[]]$Bundles = @(),
    [switch]$Ssh,
    [switch]$Apk
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

# C:\path\to\repo -> /mnt/c/path/to/repo for the WSL build step.
$wslRepo = '/mnt/' + $repo.Substring(0, 1).ToLower() + ($repo.Substring(2) -replace '\\', '/')

Write-Host '-- Rebuilding jetpacs-core.el from emacs/core/*.el ...'
wsl.exe -d Debian -- emacs --batch -l "$wslRepo/emacs/build-bundle.el"
if ($LASTEXITCODE -ne 0) { throw 'Bundle build failed.' }

# The push set: the foundation bundle plus whatever apps were passed in.
$files = @(Join-Path $repo 'jetpacs-core.el')
foreach ($b in $Bundles) {
    $resolved = (Resolve-Path $b -ErrorAction SilentlyContinue)
    if (-not $resolved) { throw "Bundle not found: $b" }
    $files += $resolved.Path
}

Write-Host '-- Checking device ...'
adb get-state | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'No device visible to adb.' }

if ($Ssh) {
    Write-Host '-- Pushing directly into Termux home via sshd (port 8022) ...'
    adb forward tcp:8022 tcp:8022 | Out-Null
    ssh -p 8022 termux@127.0.0.1 'mkdir -p .emacs.d/elisp'
    if ($LASTEXITCODE -ne 0) { throw 'ssh failed - is sshd running in Termux?' }
    foreach ($f in $files) {
        $name = Split-Path $f -Leaf
        scp -P 8022 $f "termux@127.0.0.1:.emacs.d/elisp/$name"
        if ($LASTEXITCODE -ne 0) { throw "scp failed: $name" }
        Write-Host "   Installed ~/.emacs.d/elisp/$name"
    }
    Write-Host '   Reload or restart Emacs to pick the bundles up.'
} else {
    Write-Host '-- Staging to /sdcard/Documents/jetpacs (adopted by init.el on Emacs restart) ...'
    adb shell mkdir -p /sdcard/Documents/jetpacs
    foreach ($f in $files) {
        $name = Split-Path $f -Leaf
        adb push $f "/sdcard/Documents/jetpacs/$name"
        if ($LASTEXITCODE -ne 0) { throw "adb push failed: $name" }
    }
    Write-Host '   Staged. Restart Emacs on the device (or eval the adopt snippet) to pick them up.'
}

if ($Apk) {
    Write-Host '-- Building + installing companion APK ...'
    & (Join-Path $repo 'gradlew.bat') installDebug
    if ($LASTEXITCODE -ne 0) { throw 'APK install failed.' }
}

Write-Host 'Deploy complete.'
