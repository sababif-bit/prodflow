<#
.SYNOPSIS
  Disposable end-to-end check that the Compose wiring of keycloak-import-guard really blocks a bad first import and keeps routine
  restarts working (Issue #8 / D-1).

.DESCRIPTION
  - Runs a COPY of the compose file as a separate Compose project (default "prodflow-guardcheck": own containers, own volumes,
    Keycloak on 127.0.0.1:8182). Never touches the real "prodflow" project, its volumes, localhost:8180 or the repository's .env
    (the copy lives in a temp directory without a .env; every value is passed through the process environment).
  - Scenarios: (A) fresh DB + no demo passwords -> Keycloak must NOT start and nothing must be imported; (B) fresh DB + a placeholder
    value -> same; (C) fresh DB + valid passwords -> import works and the three users can log in (smoke-auth, PKCE);
    (D) restart and force-recreate WITHOUT any demo password -> Keycloak comes back, realm and password unchanged.
  - Secrets: generated in memory, never printed. Cleanup in a finally block (down -v for the test project only, temp dir removed).
  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-compose-guard.ps1 [-ComposeFile <path>]
  Exit code: 0 = all passed, 1 = a check failed, 3 = pre-check failed (nothing started).
#>
[CmdletBinding()]
param(
    [string] $ComposeFile = '',
    [string] $Project = 'prodflow-guardcheck',
    [int]    $Port = 8182
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $ComposeFile) { $ComposeFile = Join-Path $repo 'docker-compose.yml' }
$script:Failures = 0
$script:Passes = 0
$base = "http://localhost:$Port"
$AppUrl = 'http://localhost:8080'
$work = Join-Path ([IO.Path]::GetTempPath()) ("prodflow-guardcheck-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$managed = 'KEYCLOAK_DB_NAME', 'KEYCLOAK_DB_USER', 'KEYCLOAK_DB_PASSWORD', 'KC_BOOTSTRAP_ADMIN_USERNAME', 'KC_BOOTSTRAP_ADMIN_PASSWORD',
           'PRODFLOW_DB_PASSWORD', 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD', 'PRODFLOW_APP_URL'

function Report([bool] $ok, [string] $label, [string] $detail = '') {
    if ($ok) { $script:Passes++ } else { $script:Failures++ }
    $text = '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label
    if ($detail) { $text += "  ($detail)" }
    Write-Host $text
}
function New-Secret { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) }
function Native([scriptblock] $Block) { & { $ErrorActionPreference = 'Continue'; & $Block } }
function Clear-Env { foreach ($n in $managed) { Remove-Item "env:$n" -ErrorAction SilentlyContinue } }
function Compose { param([Parameter(ValueFromRemainingArguments)] $CliArgs)
    $out = Native { (& docker compose -p $Project -f (Join-Path $work 'docker-compose.yml') @CliArgs 2>&1) | ForEach-Object { "$_" } }
    @{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
}
function Service-State([string] $Service) {
    $s = Native { docker ps -a --filter "label=com.docker.compose.project=$Project" --filter "label=com.docker.compose.service=$Service" --format '{{.State}}' }
    if ($s) { "$s".Trim() } else { 'absent' }
}
function Guard-ExitCode { Native { docker ps -a --filter "label=com.docker.compose.project=$Project" --filter 'label=com.docker.compose.service=keycloak-import-guard' --format '{{.Status}}' } }
function Wait-Realm([int] $Seconds = 150) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-RestMethod -Uri "$base/realms/prodflow/.well-known/openid-configuration" -TimeoutSec 3 | Out-Null; return $true } catch { Start-Sleep -Seconds 2 }
    }
    $false
}
function Realm-Table-Absent {
    $env:PGPASSWORD = $env:KEYCLOAK_DB_PASSWORD
    try { $r = Native { docker exec -e PGPASSWORD (Native { docker ps -a --filter "label=com.docker.compose.project=$Project" --filter 'label=com.docker.compose.service=keycloak-db' --format '{{.Names}}' }) psql -U $env:KEYCLOAK_DB_USER -d $env:KEYCLOAK_DB_NAME -At -c "SELECT to_regclass('public.realm') IS NULL" 2>&1 } }
    finally { Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue }
    ("$r".Trim() -eq 't')
}
function Smoke([string[]] $Users) {
    $out = & (Join-Path $PSScriptRoot 'smoke-auth.ps1') -KeycloakUrl $base -ClientId 'prodflow-swagger' -RedirectUri "$AppUrl/swagger-ui/oauth2-redirect.html" -ExpectedLifespan 1800 -Users $Users -SkipUserSwitching -SkipPkceNegative 6>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($l in ($out -split "`r?`n")) { if ($l -match '^\s*FAIL') { Write-Host "    smoke-auth: $l" } }
    @{ Code = $code; Output = $out }
}
function Existing-Stack { (Native { docker ps -a --filter 'label=com.docker.compose.project=prodflow' --format '{{.ID}} {{.Names}}' } | Sort-Object) -join ';' }

# ---- pre-checks ----
if ($Project -eq 'prodflow') { Write-Host 'pre-check failed: refusing to use the real Compose project name'; exit 3 }
if ($Port -eq 8180 -or $Port -eq 8080) { Write-Host 'pre-check failed: port collides with the real stack'; exit 3 }
if (-not (Test-Path $ComposeFile)) { Write-Host "pre-check failed: $ComposeFile missing"; exit 3 }
if (-not (Test-Path (Join-Path $repo 'keycloak\import-guard.sh'))) { Write-Host 'pre-check failed: keycloak\import-guard.sh missing'; exit 3 }
Native { docker version --format '{{.Server.Version}}' 2>$null | Out-Null }
if ($LASTEXITCODE -ne 0) { Write-Host 'pre-check failed: Docker is not available'; exit 3 }
if (Native { docker ps -a -q --filter "label=com.docker.compose.project=$Project" }) { Write-Host "pre-check failed: project $Project already has containers"; exit 3 }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { Write-Host "pre-check failed: port $Port is busy"; exit 3 }
$compose = Get-Content $ComposeFile -Raw
if ($compose -notmatch '127\.0\.0\.1:8180:8080') { Write-Host 'pre-check failed: compose file has no 127.0.0.1:8180:8080 mapping to rewrite'; exit 3 }

$stackBefore = Existing-Stack
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $work 'backend') | Out-Null   # build context of the (never started) backend service
    New-Item -ItemType Directory -Path (Join-Path $work 'keycloak') | Out-Null
    Copy-Item (Join-Path $repo 'keycloak\prodflow-realm.json') (Join-Path $work 'keycloak')
    Copy-Item (Join-Path $repo 'keycloak\import-guard.sh') (Join-Path $work 'keycloak')
    # the copy must not advertise the real stack's URL: published port AND KC_HOSTNAME point at the test port
    $rewritten = $compose -replace '127\.0\.0\.1:8180:8080', "127.0.0.1:${Port}:8080" -replace 'KC_HOSTNAME: http://localhost:8180', "KC_HOSTNAME: http://localhost:$Port"
    if ($rewritten -match 'localhost:8180') { throw 'compose copy still references localhost:8180' }
    $rewritten | Set-Content -Path (Join-Path $work 'docker-compose.yml') -Encoding ASCII

    Clear-Env
    $env:KEYCLOAK_DB_NAME = 'keycloak'; $env:KEYCLOAK_DB_USER = 'keycloak'; $env:KEYCLOAK_DB_PASSWORD = New-Secret
    $env:KC_BOOTSTRAP_ADMIN_USERNAME = 'importcheck'; $env:KC_BOOTSTRAP_ADMIN_PASSWORD = New-Secret
    $env:PRODFLOW_DB_PASSWORD = New-Secret   # interpolation only; the db/backend services are never started

    Write-Host '== A: fresh database, no demo passwords at all =='
    $r = Compose 'up' '-d' 'keycloak'
    Report ($r.Code -ne 0) 'compose up refuses to start' "exit $($r.Code)"
    Report ((Service-State 'keycloak') -ne 'running') 'keycloak container is not running' "state=$(Service-State 'keycloak')"
    Report ((Guard-ExitCode) -match 'Exited \(1\)') 'guard exited with code 1' "$(Guard-ExitCode)"
    $logs = (Compose 'logs' 'keycloak-import-guard').Output
    Report ($logs -match 'DEMO_PLANNER_PASSWORD is not set|DEMO_PLANNER_PASSWORD is empty') 'guard log names the missing variable'
    Report (Realm-Table-Absent) 'nothing was imported: Keycloak database has no schema yet'
    Compose 'down' | Out-Null

    Write-Host '== B: fresh database, one demo password is the .env.example placeholder =='
    $env:DEMO_PLANNER_PASSWORD = 'CHANGE_ME'; $env:DEMO_PURCHASER_PASSWORD = New-Secret; $env:DEMO_ADMIN_PASSWORD = New-Secret
    $r = Compose 'up' '-d' 'keycloak'
    Report ($r.Code -ne 0) 'compose up refuses to start' "exit $($r.Code)"
    Report ((Service-State 'keycloak') -ne 'running') 'keycloak container is not running' "state=$(Service-State 'keycloak')"
    Report (Realm-Table-Absent) 'nothing was imported'
    Compose 'down' | Out-Null

    Write-Host '== C: fresh database, valid passwords -> import works =='
    $planner = New-Secret
    $env:DEMO_PLANNER_PASSWORD = $planner; $env:DEMO_PURCHASER_PASSWORD = New-Secret; $env:DEMO_ADMIN_PASSWORD = New-Secret
    $r = Compose 'up' '-d' 'keycloak'
    Report ($r.Code -eq 0) 'compose up succeeds' "exit $($r.Code)"
    Report (Wait-Realm) 'realm prodflow is served by Keycloak'
    Report ((Guard-ExitCode) -match 'Exited \(0\)') 'guard exited with code 0'
    $s = Smoke @('planner', 'purchaser', 'admin')
    Report ($s.Code -eq 0) 'real PKCE login works for planner, purchaser, admin' "smoke-auth exit $($s.Code)"
    $smokeKeep = @{ Planner = $env:DEMO_PLANNER_PASSWORD; Purchaser = $env:DEMO_PURCHASER_PASSWORD; Admin = $env:DEMO_ADMIN_PASSWORD }

    Write-Host '== D: routine restart / recreate WITHOUT demo passwords =='
    foreach ($n in 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD') { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
    $r = Compose 'stop' 'keycloak'
    $r = Compose 'up' '-d' 'keycloak'
    Report ($r.Code -eq 0) 'stop + up -d succeeds without demo passwords' "exit $($r.Code)"
    Report (Wait-Realm) 'realm still served after restart'
    $r = Compose 'up' '-d' '--force-recreate' 'keycloak'
    Report ($r.Code -eq 0) 'force-recreate succeeds without demo passwords' "exit $($r.Code)"
    Report (Wait-Realm) 'realm still served after recreate'
    $guardLogs = (Compose 'logs' 'keycloak-import-guard').Output
    Report ($guardLogs -match 'already exists') 'guard saw the existing realm and skipped validation'
    # the password from step C must still be the one in the database (a restart must not re-import or reset anything)
    $env:DEMO_PLANNER_PASSWORD = $smokeKeep.Planner; $env:DEMO_PURCHASER_PASSWORD = $smokeKeep.Purchaser; $env:DEMO_ADMIN_PASSWORD = $smokeKeep.Admin
    $s = Smoke @('planner', 'purchaser', 'admin')
    Report ($s.Code -eq 0) 'the original demo passwords still work after restart and recreate' "smoke-auth exit $($s.Code)"
    $leak = ($r.Output + $guardLogs + (Compose 'logs' 'keycloak').Output)
    $leaked = $false
    foreach ($v in $smokeKeep.Values) { if ($leak.Contains($v)) { $leaked = $true } }
    Report (-not $leaked) 'no demo password appears in compose output or container logs'
}
catch {
    Report $false 'test run aborted' $_.Exception.Message
}
finally {
    Clear-Env
    # tear down ONLY the test project (its own containers, network and volumes)
    $env:KEYCLOAK_DB_NAME = 'x'; $env:KEYCLOAK_DB_USER = 'x'; $env:KEYCLOAK_DB_PASSWORD = 'x'; $env:KC_BOOTSTRAP_ADMIN_USERNAME = 'x'; $env:KC_BOOTSTRAP_ADMIN_PASSWORD = 'x'; $env:PRODFLOW_DB_PASSWORD = 'x'
    if (Test-Path (Join-Path $work 'docker-compose.yml')) { Compose 'down' '-v' '--remove-orphans' | Out-Null }
    Clear-Env
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
}

Write-Host '== cleanup =='
Report (-not (Native { docker ps -a -q --filter "label=com.docker.compose.project=$Project" })) 'no test containers left'
Report (-not (Native { docker volume ls -q --filter "label=com.docker.compose.project=$Project" })) 'no test volumes left'
Report (-not (Test-Path $work)) 'temp directory removed'
Report (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) "port $Port released"
Report ((Existing-Stack) -eq $stackBefore) 'real prodflow Compose containers unchanged (same IDs)'
Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:Passes, $script:Failures)
if ($script:Failures -gt 0) { exit 1 } else { exit 0 }
