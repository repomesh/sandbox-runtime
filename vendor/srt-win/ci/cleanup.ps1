<#
  Best-effort teardown of any state smoke.ps1 may have left behind.
  Intended for `if: always()` in CI; safe to run locally too.

  Usage:
    pwsh vendor/srt-win/ci/cleanup.ps1 <path-to-srt-win.exe> [group-name]

  Reads $env:SRT_ALT_GUID (written by smoke.ps1 under CI) to also
  clean the alternate sublayer.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Exe,
  [string]$GroupName = 'srt-ci-test'
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path $Exe)) {
  Write-Host "cleanup: $Exe not found; nothing to do"
  exit 0
}

if ($env:SRT_ALT_GUID) {
  & $Exe wfp uninstall --all --sublayer-guid $env:SRT_ALT_GUID
}
& $Exe wfp uninstall --all
& $Exe group delete --name $GroupName
exit 0
