<#
.SYNOPSIS
Deploy the Glasspane bundle (and optionally the companion APK) to the
connected Android device.

.DESCRIPTION
Default: rebuild glasspane.el from emacs/*.el via WSL Emacs, then adb-push
it to /sdcard/Download/glasspane.el. Termux is not debuggable, so adb cannot
write into /data/data/com.termux directly — pair this with the init.el
bootstrap snippet that adopts a newer staged bundle at Emacs startup:

    ;; Adopt a freshly adb-pushed bundle before loading it.
    (let ((staged "/sdcard/Download/glasspane.el")
          (installed "~/.emacs.d/elisp/glasspane.el"))
      (when (and (file-readable-p staged)
                 (file-newer-than-file-p staged installed))
        (copy-file staged installed t)
        (message "glasspane: adopted new bundle from Downloads")))
    (require 'glasspane)

.PARAMETER Ssh
Push straight into Termux's home (~/.emacs.d/elisp/glasspane.el) over
Termux sshd — a true direct drop, no staging or restart-adopt needed.
One-time setup inside Termux:
    pkg install openssh && passwd && sshd
Optional, for passwordless pushes: append your Windows public key
(~/.ssh/id_ed25519.pub) to ~/.ssh/authorized_keys in Termux.
sshd must be running on the device when you deploy (`sshd` in Termux).

.PARAMETER Apk
Also build and install the companion app (gradlew installDebug).
#>
param(
    [switch]$Ssh,
    [switch]$Apk
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$bundle = Join-Path $repo 'glasspane.el'

# C:\path\to\repo -> /mnt/c/path/to/repo for the WSL build step.
$wslRepo = '/mnt/' + $repo.Substring(0, 1).ToLower() + ($repo.Substring(2) -replace '\\', '/')

Write-Host '-- Rebuilding glasspane.el from emacs/*.el ...'
wsl.exe -d Debian -- emacs --batch -l "$wslRepo/emacs/build-bundle.el"
if ($LASTEXITCODE -ne 0) { throw 'Bundle build failed.' }

Write-Host '-- Checking device ...'
adb get-state | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'No device visible to adb.' }

if ($Ssh) {
    Write-Host '-- Pushing directly into Termux home via sshd (port 8022) ...'
    adb forward tcp:8022 tcp:8022 | Out-Null
    ssh -p 8022 termux@127.0.0.1 'mkdir -p .emacs.d/elisp'
    if ($LASTEXITCODE -ne 0) { throw 'ssh failed - is sshd running in Termux?' }
    scp -P 8022 $bundle termux@127.0.0.1:.emacs.d/elisp/glasspane.el
    if ($LASTEXITCODE -ne 0) { throw 'scp failed.' }
    Write-Host '   Installed to ~/.emacs.d/elisp/glasspane.el - reload or restart Emacs.'
} else {
    Write-Host '-- Staging to /sdcard/Download (adopted by init.el on Emacs restart) ...'
    adb push $bundle /sdcard/Download/glasspane.el
    if ($LASTEXITCODE -ne 0) { throw 'adb push failed.' }
    Write-Host '   Staged. Restart Emacs on the device (or eval the adopt snippet) to pick it up.'
}

if ($Apk) {
    Write-Host '-- Building + installing companion APK ...'
    & (Join-Path $repo 'gradlew.bat') installDebug
    if ($LASTEXITCODE -ne 0) { throw 'APK install failed.' }
}

Write-Host 'Deploy complete.'
