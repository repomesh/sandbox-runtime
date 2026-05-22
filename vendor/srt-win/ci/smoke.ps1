<#
  srt-win end-to-end smoke test.

  Exercises the full group + WFP lifecycle against a built srt-win.exe.
  Throws on any assertion failure. Requires elevation (NetLocalGroup*
  and Fwpm* both need admin).

  Usage (local dev machine):
    pwsh vendor/srt-win/ci/smoke.ps1 .\target\release\srt-win.exe

  Usage (CI — workflow passes the path):
    pwsh vendor/srt-win/ci/smoke.ps1 vendor\srt-win\target\release\srt-win.exe

  When running under GitHub Actions, the alt-sublayer GUID is also
  written to $env:GITHUB_ENV so the always()-gated cleanup step can
  remove those filters even if this script throws midway.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Exe,
  [string]$GroupName = 'srt-ci-test'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
  throw "srt-win.exe not found at '$Exe'"
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Host "srt-win smoke: exe=$Exe group=$GroupName user_sid=$me"

function Run([string[]]$argv) {
  & $Exe @argv
  if ($LASTEXITCODE -ne 0) {
    throw "srt-win $($argv -join ' ') exited $LASTEXITCODE"
  }
}
function J([string[]]$argv) { Run $argv | ConvertFrom-Json }
function MustFail([string[]]$argv, [string]$why) {
  & $Exe @argv 2>$null
  if ($LASTEXITCODE -eq 0) {
    throw "expected non-zero ($why): srt-win $($argv -join ' ')"
  }
}

# ── group create (idempotent) ────────────────────────────────────────
Run @('group', 'create', '--name', $GroupName)
Run @('group', 'create', '--name', $GroupName)   # second call must succeed

$gs = J @('group', 'status', '--name', $GroupName)
Write-Host "group status (--name): $($gs | ConvertTo-Json -Compress)"
# In CI there's no logout, so the new group SID is not yet on the
# runner's token: `created-not-on-token` is expected. On a dev box
# that already has the group from a prior run, `ready` is fine too.
if ($gs.state -notin 'created-not-on-token', 'ready') {
  throw "unexpected group state: $($gs.state)"
}
if (-not $gs.sid -or -not $gs.sid.StartsWith('S-1-')) {
  throw "group status did not return a SID"
}

# --group-sid path returns the same SID.
$gs2 = J @('group', 'status', '--group-sid', $gs.sid)
if ($gs2.sid -ne $gs.sid) {
  throw "--group-sid status sid mismatch: $($gs2.sid) vs $($gs.sid)"
}
# Unmapped SID via --group-sid reports absent (not created-not-on-token).
$gsBad = J @('group', 'status', '--group-sid', 'S-1-5-21-1-2-3-9999999')
if ($gsBad.state -ne 'absent') {
  throw "unmapped --group-sid expected absent, got $($gsBad.state)"
}

# ── negative input: invalid SIDs fail fast with a clear error ───────
MustFail @('wfp', 'install', '--group-sid', 'not-a-sid')           'invalid --group-sid'
MustFail @('wfp', 'install', '--name', $GroupName, '--user-sid', 'not-a-sid') 'invalid --user-sid'

# ── wfp: pre-install absent ──────────────────────────────────────────
$pre = J @('wfp', 'status')
if ($pre.state -ne 'absent') {
  throw "pre-install wfp status expected absent, got $($pre.state)"
}

# First install via --name + explicit --user-sid.
Run @('wfp', 'install', '--name', $GroupName, '--user-sid', $me)
$ws = J @('wfp', 'status', '--user-sid', $me)
Write-Host "wfp status: $($ws | ConvertTo-Json -Compress)"
if ($ws.state -ne 'installed') { throw "expected installed, got $($ws.state)" }
if ($ws.filters -lt 6)         { throw "expected >=6 filters, got $($ws.filters)" }

# Idempotency: second install via --group-sid path leaves the same
# filter count.
Run @('wfp', 'install', '--group-sid', $gs.sid)
$ws2 = J @('wfp', 'status')
if ($ws2.filters -ne $ws.filters) {
  throw "idempotency: filter count changed $($ws.filters) -> $($ws2.filters)"
}

# ── --sublayer-guid isolation ────────────────────────────────────────
# Persist the alt GUID so an always()-gated cleanup step can remove
# its filters even if this script throws midway.
$altGuid = [guid]::NewGuid().ToString()
if ($env:GITHUB_ENV) {
  Add-Content $env:GITHUB_ENV "SRT_ALT_GUID=$altGuid"
}
Run @('wfp', 'install', '--name', $GroupName, '--sublayer-guid', $altGuid)
$alt = J @('wfp', 'status', '--sublayer-guid', $altGuid)
if ($alt.state -ne 'installed') {
  throw "alt sublayer expected installed, got $($alt.state)"
}
# Default sublayer is still its own thing.
$stillDefault = J @('wfp', 'status')
if ($stillDefault.filters -ne $ws.filters) {
  throw "default sublayer perturbed by alt install"
}
Run @('wfp', 'uninstall', '--all', '--sublayer-guid', $altGuid)
$altGone = J @('wfp', 'status', '--sublayer-guid', $altGuid)
if ($altGone.state -ne 'absent') {
  throw "alt sublayer expected absent after uninstall, got $($altGone.state)"
}

# ── teardown: per-user uninstall on default sublayer ────────────────
Run @('wfp', 'uninstall')
$post = J @('wfp', 'status')
if ($post.state -ne 'absent') {
  throw "post-uninstall expected absent, got $($post.state)"
}
# Idempotent no-op: second uninstall must also exit 0.
Run @('wfp', 'uninstall')

Run @('group', 'delete', '--name', $GroupName)
$gd = J @('group', 'status', '--name', $GroupName)
if ($gd.state -ne 'absent') {
  throw "post-delete group expected absent, got $($gd.state)"
}
# Idempotent no-op: second delete must also exit 0.
Run @('group', 'delete', '--name', $GroupName)

Write-Host 'srt-win smoke: OK'
