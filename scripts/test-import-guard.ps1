<#
.SYNOPSIS
  Disposable regression test for keycloak/import-guard.sh (fail-fast guard in front of the Keycloak realm import, Issue #8 / D-1).

.DESCRIPTION
  - One throwaway postgres:16-alpine container (no published port, no volume) plays the Keycloak database. The real guard script
    runs in short-lived containers that share its network namespace. Never touches the Compose stack, localhost:8180 or any volume.
  - Passwords are generated in memory, passed to Docker by variable NAME only and never printed. The test also asserts that no
    password value appears in the guard's output.
  - Cleanup in a finally block: containers removed, environment variables cleared.
  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-import-guard.ps1
  Exit code: 0 = all passed, 1 = a check failed, 3 = pre-check failed (nothing started).
#>
[CmdletBinding()]
param(
    [string] $DbContainer = 'prodflow-guardcheck-db',
    [string] $Image = 'postgres:16-alpine'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$guard = Join-Path $repo 'keycloak\import-guard.sh'
$script:Failures = 0
$script:Passes = 0
$script:DbPassword = $null

function Report([bool] $ok, [string] $label, [string] $detail = '') {
    if ($ok) { $script:Passes++ } else { $script:Failures++ }
    $text = '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label
    if ($detail) { $text += "  ($detail)" }
    Write-Host $text
}
function New-Secret { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) }
function Native([scriptblock] $Block) { & { $ErrorActionPreference = 'Continue'; & $Block } }
function Remove-Disposable { Native { docker rm -f $DbContainer 2>$null | Out-Null } }

if (-not (Test-Path $guard)) { Write-Host "pre-check failed: $guard missing"; exit 3 }
if ((Get-Content $guard -Raw) -match "`r") { Write-Host 'pre-check failed: import-guard.sh has CRLF line endings (needs LF, see .gitattributes)'; exit 3 }
Native { docker version --format '{{.Server.Version}}' 2>$null | Out-Null }
if ($LASTEXITCODE -ne 0) { Write-Host 'pre-check failed: Docker is not available'; exit 3 }
$existing = Native { docker ps -a --filter "name=^$DbContainer$" --format '{{.Names}}' }
if ($existing) { Write-Host "pre-check failed: container $DbContainer already exists"; exit 3 }

# Runs the guard once. $Vars: hashtable name -> value; $null value = variable NOT passed (unset), '' = passed but empty.
# Returns @{ Code; Output }.
function Invoke-Guard([hashtable] $Vars, [string] $PgPassword = $script:DbPassword, [string] $PgHost = 'localhost', [string] $PgDatabase = 'guarddb') {
    $envNames = @()
    $dockerArgs = @('run', '--rm', '--network', "container:$DbContainer", '-v', "${guard}:/guard/import-guard.sh:ro",
        '-e', "PGHOST=$PgHost", '-e', 'PGUSER=guard', '-e', "PGDATABASE=$PgDatabase", '-e', 'PGPASSWORD')
    $env:PGPASSWORD = $PgPassword; $envNames += 'PGPASSWORD'
    foreach ($k in $Vars.Keys) {
        $v = $Vars[$k]
        if ($null -eq $v) { continue }
        if ($v -eq '') { $dockerArgs += @('-e', "$k="); continue }
        Set-Item -Path "env:$k" -Value $v; $envNames += $k; $dockerArgs += @('-e', $k)
    }
    $dockerArgs += @('--entrypoint', 'sh', $Image, '/guard/import-guard.sh')
    try {
        $out = Native { (& docker @dockerArgs 2>&1) | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
    } finally { foreach ($n in $envNames) { Remove-Item "env:$n" -ErrorAction SilentlyContinue } }
    @{ Code = $code; Output = ($out -join "`n") }
}
function Sql([string] $Statement) {
    $env:PGPASSWORD = $script:DbPassword
    try { Native { docker exec -e PGPASSWORD $DbContainer psql -U guard -d guarddb -v ON_ERROR_STOP=1 -c $Statement 2>&1 | Out-Null } } finally { Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw "SQL failed: $Statement" }
}

$planner = New-Secret; $purchaser = New-Secret; $admin = New-Secret
$good = @{ DEMO_PLANNER_PASSWORD = $planner; DEMO_PURCHASER_PASSWORD = $purchaser; DEMO_ADMIN_PASSWORD = $admin }
function With([hashtable] $Base, [string] $Key, $Value) { $c = @{}; foreach ($k in $Base.Keys) { $c[$k] = $Base[$k] }; $c[$Key] = $Value; $c }
function Rejected([string] $Label, [hashtable] $Vars, [string] $MustMention) {
    $r = Invoke-Guard $Vars
    $leak = $false
    foreach ($v in @($Vars.Values) + @($planner, $purchaser, $admin)) { if ($v -and $v.Length -ge 8 -and $r.Output.Contains($v)) { $leak = $true } }
    Report ($r.Code -eq 1) "$Label -> refused (exit 1)" "exit $($r.Code)"
    Report ($r.Output -match [regex]::Escape($MustMention)) "$Label -> message names $MustMention"
    Report (-not $leak) "$Label -> no password value in output"
}

try {
    $script:DbPassword = New-Secret
    $env:POSTGRES_PASSWORD = $script:DbPassword
    Native { docker run -d --name $DbContainer -e POSTGRES_USER=guard -e POSTGRES_PASSWORD -e POSTGRES_DB=guarddb $Image 2>&1 | Out-Null }
    Remove-Item env:POSTGRES_PASSWORD -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { throw 'could not start the disposable database' }
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
        Start-Sleep -Seconds 1
        Native { docker exec $DbContainer pg_isready -U guard -d guarddb 2>&1 | Out-Null }
        $ready = ($LASTEXITCODE -eq 0)
    }
    if (-not $ready) { throw 'disposable database did not become ready' }
    Start-Sleep -Seconds 2   # the postgres entrypoint restarts the server once after init

    Write-Host '== fresh database (no Keycloak schema yet): every demo password must be valid =='
    $r = Invoke-Guard $good
    Report ($r.Code -eq 0) 'three strong, distinct passwords -> accepted (exit 0)' "exit $($r.Code)"
    Report ($r.Output -match 'not found') 'output says the realm is missing, so the passwords were validated'

    Rejected 'planner unset'           (With $good 'DEMO_PLANNER_PASSWORD' $null) 'DEMO_PLANNER_PASSWORD'
    Rejected 'purchaser unset'         (With $good 'DEMO_PURCHASER_PASSWORD' $null) 'DEMO_PURCHASER_PASSWORD'
    Rejected 'admin unset'             (With $good 'DEMO_ADMIN_PASSWORD' $null) 'DEMO_ADMIN_PASSWORD'
    Rejected 'planner explicitly empty' (With $good 'DEMO_PLANNER_PASSWORD' '') 'DEMO_PLANNER_PASSWORD'
    Rejected 'all three unset'         @{} 'DEMO_PLANNER_PASSWORD'
    Rejected 'unresolved placeholder'  (With $good 'DEMO_PLANNER_PASSWORD' '${DEMO_PLANNER_PASSWORD}') 'DEMO_PLANNER_PASSWORD'
    Rejected 'embedded placeholder'    (With $good 'DEMO_ADMIN_PASSWORD' ('prefix-' + '${X}' + '-suffix-long')) 'DEMO_ADMIN_PASSWORD'
    Rejected '.env.example value'      (With $good 'DEMO_PURCHASER_PASSWORD' 'CHANGE_ME') 'DEMO_PURCHASER_PASSWORD'
    Rejected 'obvious password'        (With $good 'DEMO_PURCHASER_PASSWORD' 'MyPassword12345!') 'DEMO_PURCHASER_PASSWORD'
    Rejected 'too short (11 chars)'    (With $good 'DEMO_ADMIN_PASSWORD' 'aB3$xY7!qW9') 'DEMO_ADMIN_PASSWORD'
    Rejected 'few distinct characters' (With $good 'DEMO_ADMIN_PASSWORD' 'aaaaaaaaaaaaaaaaaaaa') 'DEMO_ADMIN_PASSWORD'
    Rejected 'spaces only'             (With $good 'DEMO_PLANNER_PASSWORD' '                ') 'DEMO_PLANNER_PASSWORD'
    Rejected 'trailing CR (CRLF .env)' (With $good 'DEMO_PLANNER_PASSWORD' ($planner + "`r")) 'DEMO_PLANNER_PASSWORD'
    Rejected 'embedded line break'     (With $good 'DEMO_PLANNER_PASSWORD' ($planner + "`n" + $planner)) 'DEMO_PLANNER_PASSWORD'
    Rejected 'embedded ESC character'  (With $good 'DEMO_PLANNER_PASSWORD' ($planner + [string][char]27 + 'x')) 'DEMO_PLANNER_PASSWORD'
    Rejected 'username, other case'    (With $good 'DEMO_ADMIN_PASSWORD' 'xK9#ADMIN#Qw7!zT') 'admin'
    Rejected 'password contains username' (With $good 'DEMO_PLANNER_PASSWORD' 'xK9#planner#Qw7!zT') 'planner'
    Rejected 'planner == purchaser'    (With $good 'DEMO_PURCHASER_PASSWORD' $planner) 'identical'
    Rejected 'planner == admin'        (With $good 'DEMO_ADMIN_PASSWORD' $planner) 'identical'
    Rejected 'purchaser == admin'      (With $good 'DEMO_ADMIN_PASSWORD' $purchaser) 'identical'

    Write-Host '== Keycloak schema exists but realm prodflow is missing: still a fresh import =='
    Sql 'CREATE TABLE realm (id text PRIMARY KEY, name text NOT NULL)'
    $r = Invoke-Guard @{}
    Report ($r.Code -eq 1) 'empty realm table + unset passwords -> refused' "exit $($r.Code)"
    $r = Invoke-Guard $good
    Report ($r.Code -eq 0) 'empty realm table + valid passwords -> accepted' "exit $($r.Code)"
    Sql "INSERT INTO realm VALUES ('1', 'master')"
    $r = Invoke-Guard @{}
    Report ($r.Code -eq 1) 'only the master realm exists + unset passwords -> refused' "exit $($r.Code)"

    Write-Host '== realm prodflow already imported: routine restart without demo passwords =='
    Sql "INSERT INTO realm VALUES ('2', 'prodflow')"
    $r = Invoke-Guard @{}
    Report ($r.Code -eq 0) 'realm exists + no demo passwords -> accepted (restart keeps working)' "exit $($r.Code)"
    Report ($r.Output -match 'already exists') 'output says the import will be skipped'
    $r = Invoke-Guard (With $good 'DEMO_PLANNER_PASSWORD' '')
    Report ($r.Code -eq 0) 'realm exists + an empty variable -> accepted (nothing is imported)' "exit $($r.Code)"

    Write-Host '== uncertain state: fail closed =='
    # (a wrong password cannot be tested here: the postgres image trusts loopback connections)
    $r = Invoke-Guard $good $script:DbPassword 'localhost' 'no_such_database'
    Report ($r.Code -eq 2) 'database does not exist / cannot be queried -> refused (exit 2)' "exit $($r.Code)"
    $r = Invoke-Guard $good $script:DbPassword 'no-such-host.invalid'
    Report ($r.Code -eq 2) 'database host unreachable -> refused (exit 2)' "exit $($r.Code)"
    Sql 'DROP TABLE realm'
    Sql 'CREATE TABLE realm (id text)'   # schema without the expected column: lookup must fail closed
    $r = Invoke-Guard $good
    Report ($r.Code -eq 2) 'unexpected realm table layout -> refused (exit 2)' "exit $($r.Code)"
}
catch {
    Report $false 'test run aborted' $_.Exception.Message
}
finally {
    Remove-Disposable
    foreach ($n in 'PGPASSWORD', 'POSTGRES_PASSWORD', 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD') { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
}

Write-Host '== cleanup =='
$left = Native { docker ps -a --filter "name=^$DbContainer$" --format '{{.Names}}' }
Report (-not $left) 'disposable database container removed'
Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:Passes, $script:Failures)
if ($script:Failures -gt 0) { exit 1 } else { exit 0 }
