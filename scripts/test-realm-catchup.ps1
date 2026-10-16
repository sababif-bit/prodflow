<#
.SYNOPSIS
  Isolated test of scripts/provision-demo-realm.ps1: a disposable Keycloak 26.4.0 is started from the OLD realm import (read from
  Git, default HEAD), seeded with a pre-existing user, caught up with the script and verified end to end.

.DESCRIPTION
  Covers: input validation (nothing changes on bad input), dry run, the catch-up itself, preservation of pre-existing data,
  idempotency (second run with DIFFERENT passwords must change nothing and reset no password), real Authorization Code + PKCE logins
  with the original passwords, and conflict handling (existing differing client/user -> stop, report, change nothing).
  Never touches the Docker Compose stack or localhost:8180. One disposable container (no volume, --rm, 127.0.0.1 only); all
  passwords are random, in memory only, passed to Docker by name. Cleanup runs in a finally block.
  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-realm-catchup.ps1
  Exit code: 0 = all checks passed, 1 = a check failed, 3 = pre-check failed (nothing was started).
#>
[CmdletBinding()]
param(
    [string] $ContainerName = 'prodflow-kc-catchup',
    [int]    $Port = 8181,
    [string] $Image = 'quay.io/keycloak/keycloak:26.4.0',
    [string] $OldRealmRef = 'HEAD'          # Git ref that still holds the OLD realm file (no prodflow-swagger, no users)
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$base = "http://localhost:$Port"
$AppUrl = 'http://localhost:8080'
$provision = Join-Path $PSScriptRoot 'provision-demo-realm.ps1'
$smoke = Join-Path $PSScriptRoot 'smoke-auth.ps1'
$AppRoles = @('ADMIN', 'PLANNER', 'PURCHASER')
$script:Passes = 0
$script:Failures = 0

function Report([bool] $ok, [string] $label, [string] $detail = '') {
    if ($ok) { $script:Passes++ } else { $script:Failures++ }
    $text = '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label
    if ($detail) { $text += "  ($detail)" }
    Write-Host $text
}
function New-Secret { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) }
function Hash($Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 30 -Compress
    [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '')
}
# Windows PowerShell 5.1 returns JSON arrays as one object: normalize to an array (null -> 0 items, object -> 1 item)
function Items($x) { if ($null -eq $x) { , @() } elseif ($x -is [System.Array]) { , $x } else { , @($x) } }
function Get-AdminHeaders {
    $t = (Invoke-RestMethod -Method Post -Uri "$base/realms/master/protocol/openid-connect/token" -Body @{
            grant_type = 'password'; client_id = 'admin-cli'; username = 'catchup-admin'; password = $env:KC_BOOTSTRAP_ADMIN_PASSWORD }).access_token
    @{ Authorization = "Bearer $t" }
}
function Admin([string] $Method, [string] $Path, $Body = $null) {
    $p = @{ Method = $Method; Uri = "$base/admin/realms/prodflow$Path"; Headers = (Get-AdminHeaders) }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    Invoke-RestMethod @p
}
function AdminList([string] $Path) { Items (Admin GET $Path) }
function Get-AppRoles($UserId) { @((AdminList "/users/$UserId/role-mappings/realm") | ForEach-Object { $_.name } | Where-Object { $AppRoles -contains $_ }) }
function Set-DemoEnv($Planner, $Purchaser, $Admin) {
    foreach ($pair in @(@('DEMO_PLANNER_PASSWORD', $Planner), @('DEMO_PURCHASER_PASSWORD', $Purchaser), @('DEMO_ADMIN_PASSWORD', $Admin))) {
        if ($null -eq $pair[1]) { Remove-Item "env:$($pair[0])" -ErrorAction SilentlyContinue } else { Set-Item "env:$($pair[0])" $pair[1] }
    }
}
function Invoke-Provision([string[]] $Extra = @(), [string] $Url = $base, [string] $App = $AppUrl) {
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $provision -KeycloakUrl $Url -AppUrl $App @Extra | Out-String)
    [pscustomobject] @{ Exit = $LASTEXITCODE; Out = $out }
}
function Show($Result) { ($Result.Out -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    | $_" } }
function Get-Snapshot {
    $clients = AdminList '/clients'
    $legacy = (AdminList '/users?username=legacy.operator&exact=true')[0]
    @{
        Realm   = Hash (Admin GET '')
        Roles   = Hash ((AdminList '/roles') | Sort-Object name)
        Web     = Hash (@($clients | Where-Object { $_.clientId -eq 'prodflow-web' })[0])
        Api     = Hash (@($clients | Where-Object { $_.clientId -eq 'prodflow-api' })[0])
        Legacy  = Hash @($legacy, (AdminList "/users/$($legacy.id)/role-mappings/realm"), (AdminList "/users/$($legacy.id)/credentials"))
        Clients = (@($clients | ForEach-Object { $_.clientId } | Sort-Object) -join ',')
    }
}
function Get-Fingerprint {
    $cl = (AdminList '/clients?clientId=prodflow-swagger')[0]
    $parts = @("client:$($cl.id):$(Hash (Admin GET "/clients/$($cl.id)"))")
    foreach ($n in 'planner', 'purchaser', 'admin') {
        $u = (AdminList "/users?username=$n&exact=true")[0]
        $creds = AdminList "/users/$($u.id)/credentials"
        $parts += "user:${n}:$($u.id):$((@($creds | ForEach-Object { "$($_.id)/$($_.createdDate)" })) -join ',')"
    }
    $parts += "users:$((AdminList '/users?max=100').Count)"
    $parts -join '|'
}
function Test-State([bool] $ClientExists, [bool] $UsersExist) {
    $c = (AdminList '/clients?clientId=prodflow-swagger').Count -gt 0
    $u = (AdminList '/users?username=planner&exact=true').Count -gt 0
    ($c -eq $ClientExists) -and ($u -eq $UsersExist)
}

# ---- pre-checks: abort before starting anything ----
if ($Port -eq 8180) { Write-Host 'ABORT: port 8180 is the local development Keycloak; this test only ever uses a disposable instance'; exit 3 }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { Write-Host "ABORT: port $Port is already in use"; exit 3 }
if (docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}') { Write-Host "ABORT: container $ContainerName already exists"; exit 3 }
$oldJson = (git -C $repo show "${OldRealmRef}:keycloak/prodflow-realm.json") -join "`n"
if (($oldJson -match 'prodflow-swagger') -or ($oldJson -match '"users"')) {
    Write-Host "ABORT: '$OldRealmRef' already contains the new realm (Swagger client/users); pass -OldRealmRef <older ref> to use the old import file"
    exit 3
}
$volumesBefore = (docker volume ls -q | Measure-Object).Count
$oldRealmFile = Join-Path ([IO.Path]::GetTempPath()) ("prodflow-old-realm-" + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($oldRealmFile, $oldJson, (New-Object Text.UTF8Encoding($false)))

$env:KC_BOOTSTRAP_ADMIN_USERNAME = 'catchup-admin'
$env:KC_BOOTSTRAP_ADMIN_PASSWORD = New-Secret
$planner = New-Secret; $purchaser = New-Secret; $adminPw = New-Secret
try {
    docker run -d --rm --name $ContainerName --label prodflow.purpose=importcheck -p "127.0.0.1:${Port}:8080" `
        -e KC_BOOTSTRAP_ADMIN_USERNAME -e KC_BOOTSTRAP_ADMIN_PASSWORD `
        -v "${oldRealmFile}:/opt/keycloak/data/import/prodflow-realm.json:ro" $Image start-dev --import-realm | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 2
        if (-not (docker ps --filter "name=^$ContainerName$" --format '{{.Names}}')) { break }
        try { $ready = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$base/realms/prodflow").StatusCode -eq 200) } catch { }
    }
    if (-not $ready) { throw 'disposable Keycloak did not start' }
    Write-Host "Keycloak ready after ~$($i * 2) s from the OLD realm import ($OldRealmRef)"
    Report (Test-State $false $false) 'starting point: old realm has no prodflow-swagger client and no demo users'

    # pre-existing data that must survive untouched
    Admin POST '/users' @{ username = 'legacy.operator'; enabled = $true; firstName = 'Legacy'; lastName = 'Operator'; email = 'legacy.operator@prodflow.example'
        emailVerified = $true; credentials = @(@{ type = 'password'; value = (New-Secret); temporary = $false }) } | Out-Null
    $legacy = (AdminList '/users?username=legacy.operator&exact=true')[0]
    $purchRole = Admin GET '/roles/PURCHASER'
    Admin POST "/users/$($legacy.id)/role-mappings/realm" @(@{ id = $purchRole.id; name = $purchRole.name }) | Out-Null
    $before = Get-Snapshot
    Report (($before.Clients -split ',') -contains 'prodflow-web' -and ($before.Clients -split ',') -contains 'prodflow-api' -and ($before.Clients -split ',') -notcontains 'prodflow-swagger') 'seeded pre-existing user legacy.operator; snapshot of realm, roles, prodflow-web, prodflow-api taken'
    $expectedClientsAfter = ((@($before.Clients -split ',') + 'prodflow-swagger') | Sort-Object) -join ','

    # ---- 1. unsafe input must be refused and change nothing ----
    Write-Host '--- input validation: nothing may change'
    Set-DemoEnv $planner $null $adminPw
    $r = Invoke-Provision; Report ($r.Exit -eq 3 -and $r.Out -match 'DEMO_PURCHASER_PASSWORD is not set') 'missing password variable is refused' "exit=$($r.Exit)"
    Set-DemoEnv $planner $purchaser '${DEMO_ADMIN_PASSWORD}'
    $r = Invoke-Provision; Report ($r.Exit -eq 3 -and $r.Out -match 'unresolved placeholder') 'unresolved placeholder as password is refused' "exit=$($r.Exit)"
    Set-DemoEnv $planner 'short1' $adminPw
    $r = Invoke-Provision; Report ($r.Exit -eq 3 -and $r.Out -match 'too short') 'too short password is refused' "exit=$($r.Exit)"
    Set-DemoEnv $planner $purchaser $planner
    $r = Invoke-Provision; Report ($r.Exit -eq 3 -and $r.Out -match 'must be different') 'identical passwords are refused' "exit=$($r.Exit)"
    Set-DemoEnv $planner $purchaser $adminPw
    $r = Invoke-Provision -App '${PRODFLOW_APP_URL}'; Report ($r.Exit -eq 3 -and $r.Out -match 'AppUrl is an unresolved placeholder') 'unresolved application URL is refused' "exit=$($r.Exit)"
    $r = Invoke-Provision -App 'http://localhost:8080/some/path'; Report ($r.Exit -eq 3) 'application URL with a path is refused' "exit=$($r.Exit)"
    $r = Invoke-Provision -Url 'http://auth.example.invalid'; Report ($r.Exit -eq 3 -and $r.Out -match 'plain HTTP') 'credentials are not sent over plain HTTP to a remote host' "exit=$($r.Exit)"
    $keepAdminPw = $env:KC_BOOTSTRAP_ADMIN_PASSWORD; Remove-Item env:KC_BOOTSTRAP_ADMIN_PASSWORD
    $r = Invoke-Provision; Report ($r.Exit -eq 3 -and $r.Out -match 'KC_BOOTSTRAP_ADMIN_PASSWORD is not set') 'missing admin password is refused' "exit=$($r.Exit)"
    $env:KC_BOOTSTRAP_ADMIN_PASSWORD = $keepAdminPw
    $r = Invoke-Provision -Extra @('-Realm', 'no-such-realm'); Report ($r.Exit -eq 3 -and $r.Out -match 'not found') 'a realm that does not exist is not created' "exit=$($r.Exit)"
    Report (Test-State $false $false) 'after all refused runs: still no prodflow-swagger client and no demo users'

    # ---- 2. dry run ----
    Write-Host '--- dry run'
    $r = Invoke-Provision -Extra @('-DryRun'); Show $r
    Report ($r.Exit -eq 0 -and $r.Out -match 'would create client prodflow-swagger' -and $r.Out -match 'would create user planner') 'dry run reports the planned additions' "exit=$($r.Exit)"
    Report (Test-State $false $false) 'dry run changed nothing'

    # ---- 3. the catch-up (run 1) ----
    Write-Host '--- run 1'
    $r = Invoke-Provision; Show $r
    Report ($r.Exit -eq 0 -and $r.Out -match 'client prodflow-swagger: created' -and (@([regex]::Matches($r.Out, 'user \w+: created')).Count -eq 3)) 'run 1 creates the client and the three demo users' "exit=$($r.Exit)"

    $cl = (AdminList '/clients?clientId=prodflow-swagger')[0]
    $full = Admin GET "/clients/$($cl.id)"
    Report ([bool]$full.publicClient -and [bool]$full.standardFlowEnabled -and -not $full.implicitFlowEnabled -and -not $full.directAccessGrantsEnabled -and -not $full.serviceAccountsEnabled) 'prodflow-swagger: public, authorization code flow, no implicit/password/service-account flows'
    Report ($full.attributes.'pkce.code.challenge.method' -eq 'S256') 'prodflow-swagger: PKCE S256 required'
    Report ((($full.redirectUris -join '|') -eq "$AppUrl/swagger-ui/oauth2-redirect.html") -and (($full.webOrigins -join '|') -eq $AppUrl)) 'prodflow-swagger: exact redirect URI and web origin'
    Report ($full.attributes.'access.token.lifespan' -eq '1800') 'prodflow-swagger: client token lifetime 1800 s'
    $mappers = @($full.protocolMappers | Where-Object { $_.protocolMapper -eq 'oidc-audience-mapper' })
    Report ($mappers.Count -eq 1 -and $mappers[0].config.'included.client.audience' -eq 'prodflow-api' -and $mappers[0].config.'access.token.claim' -eq 'true') 'prodflow-swagger: exactly one prodflow-api audience mapper'
    Report ((Admin GET '').accessTokenLifespan -eq 300) 'realm-wide token lifetime is still 300 s'
    foreach ($pair in @(@('planner', 'PLANNER'), @('purchaser', 'PURCHASER'), @('admin', 'ADMIN'))) {
        $u = (AdminList "/users?username=$($pair[0])&exact=true")[0]
        $creds = AdminList "/users/$($u.id)/credentials"
        Report ([bool]$u.enabled -and ((Get-AppRoles $u.id) -join ',') -eq $pair[1] -and @($u.requiredActions).Count -eq 0 -and $creds.Count -eq 1 -and $creds[0].type -eq 'password') "user $($pair[0]): enabled, exactly application role $($pair[1]), no required actions, one password"
    }

    # ---- 4. nothing else changed ----
    $after = Get-Snapshot
    Report ($after.Realm -eq $before.Realm) 'realm settings unchanged'
    Report ($after.Roles -eq $before.Roles) 'realm roles unchanged'
    Report ($after.Web -eq $before.Web) 'prodflow-web unchanged'
    Report ($after.Api -eq $before.Api) 'prodflow-api unchanged'
    Report ($after.Legacy -eq $before.Legacy) 'pre-existing user legacy.operator (roles and credential) unchanged'
    Report ($after.Clients -eq $expectedClientsAfter) 'the only new client is prodflow-swagger (all built-in and existing clients still there)'

    # ---- 5. idempotency: second run with DIFFERENT passwords ----
    Write-Host '--- run 2 (idempotency, with different passwords in the environment)'
    $fp1 = Get-Fingerprint
    Set-DemoEnv (New-Secret) (New-Secret) (New-Secret)
    $r = Invoke-Provision; Show $r
    $fp2 = Get-Fingerprint
    Report ($r.Exit -eq 0 -and $r.Out -notmatch '(?m)^(creating|client \S+: created|user \S+: created)' -and $r.Out -match 'result: 0 created, 4 unchanged, 0 conflicts' -and $r.Out -match 'client prodflow-swagger: already up to date' -and (@([regex]::Matches($r.Out, 'user \w+: already up to date')).Count -eq 3)) 'run 2 reports everything already up to date and creates nothing' "exit=$($r.Exit)"
    Report ($fp1 -eq $fp2) 'run 2 changed nothing: same client, same user ids, same credential ids/dates, same number of users (no duplicates, no password reset)'
    Report ((Get-Snapshot).Legacy -eq $before.Legacy) 'run 2 left the pre-existing user untouched'

    # ---- 6. real logins with the ORIGINAL passwords ----
    Write-Host '--- real Authorization Code + PKCE logins with the original passwords'
    Set-DemoEnv $planner $purchaser $adminPw
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File $smoke -KeycloakUrl $base -ClientId 'prodflow-swagger' -RedirectUri "$AppUrl/swagger-ui/oauth2-redirect.html" -ExpectedLifespan 1800 | Out-String); $e1 = $LASTEXITCODE
    ($o -split "`r?`n") | Where-Object { $_ -match '^FAIL|result:' } | ForEach-Object { Write-Host "    | $_" }
    Report ($e1 -eq 0) 'smoke-auth (Swagger client): logins, roles, issuer, audience, 1800 s lifetime, CORS, user switching, PKCE, placeholder guard' "exit=$e1"
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File $smoke -KeycloakUrl $base -ClientId 'prodflow-web' -RedirectUri 'http://localhost:4200/callback' -ExpectedLifespan 300 -Users planner -SkipUserSwitching -SkipPkceNegative | Out-String); $e2 = $LASTEXITCODE
    ($o -split "`r?`n") | Where-Object { $_ -match '^FAIL|result:' } | ForEach-Object { Write-Host "    | $_" }
    Report ($e2 -eq 0) 'prodflow-web still works unchanged (planner login, 300 s lifetime)' "exit=$e2"

    # ---- 7. conflicts: stop, report, change nothing ----
    Write-Host '--- conflict handling'
    $good = @($full.redirectUris)
    $full.redirectUris = @('http://evil.example/cb')
    Admin PUT "/clients/$($cl.id)" $full | Out-Null
    $r = Invoke-Provision; Show $r
    Report ($r.Exit -eq 4 -and $r.Out -match 'CONFLICTS' -and $r.Out -match 'redirectUris' -and $r.Out -match 'nothing was changed') 'differing client: conflict reported, exit 4' "exit=$($r.Exit)"
    Report (((Admin GET "/clients/$($cl.id)").redirectUris -join '|') -eq 'http://evil.example/cb') 'differing client was NOT overwritten'
    $full.redirectUris = $good
    Admin PUT "/clients/$($cl.id)" $full | Out-Null

    $pl = (AdminList '/users?username=planner&exact=true')[0]
    $plCreds = Hash (AdminList "/users/$($pl.id)/credentials")
    $plannerRole = Admin GET '/roles/PLANNER'; $adminRole = Admin GET '/roles/ADMIN'
    Admin DELETE "/users/$($pl.id)/role-mappings/realm" @(@{ id = $plannerRole.id; name = $plannerRole.name }) | Out-Null
    Admin POST "/users/$($pl.id)/role-mappings/realm" @(@{ id = $adminRole.id; name = $adminRole.name }) | Out-Null
    $r = Invoke-Provision; Show $r
    Report ($r.Exit -eq 4 -and $r.Out -match 'user planner: application roles' -and $r.Out -match 'nothing was changed') 'differing user: conflict reported, exit 4' "exit=$($r.Exit)"
    Report ((((Get-AppRoles $pl.id) -join ',') -eq 'ADMIN') -and ((Hash (AdminList "/users/$($pl.id)/credentials")) -eq $plCreds)) 'differing user was NOT overwritten (roles and password untouched)'
}
catch {
    Report $false 'harness' $_.Exception.Message
}
finally {
    docker rm -f $ContainerName 2>&1 | Out-Null
    Remove-Item $oldRealmFile -ErrorAction SilentlyContinue
    foreach ($v in 'KC_BOOTSTRAP_ADMIN_USERNAME', 'KC_BOOTSTRAP_ADMIN_PASSWORD', 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD') {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }
    $planner = $null; $purchaser = $null; $adminPw = $null
}

Write-Host '--- cleanup'
Start-Sleep -Seconds 2
Report (-not [bool](docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}')) 'disposable container removed'
Report ((docker volume ls -q | Measure-Object).Count -eq $volumesBefore) 'no Docker volume left behind' "before=$volumesBefore"
Report (-not [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) "port $Port released"
Report (-not (Test-Path $oldRealmFile)) 'temporary copy of the old realm file removed'
Write-Host ("test-realm-catchup result: {0} PASS, {1} FAIL" -f $script:Passes, $script:Failures)
if ($script:Failures -eq 0) { exit 0 } else { exit 1 }
