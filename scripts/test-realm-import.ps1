<#
.SYNOPSIS
  Disposable end-to-end check of keycloak/prodflow-realm.json: imports it into a throwaway Keycloak 26.4.0, verifies the
  imported configuration through the admin API and runs the real PKCE login check (smoke-auth.ps1).

.DESCRIPTION
  - One disposable container (no volume), bound to 127.0.0.1 only. Never touches the Docker Compose stack or localhost:8180.
  - All passwords are generated in memory for this run, passed to Docker by variable NAME only, and never printed or stored.
  - Cleanup runs in a finally block: container removed, environment variables cleared, port/volume state verified.
  - -Scope EmptyVariable runs only the empty-password-variable control (see Invoke-EmptyVariableControl).
  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-realm-import.ps1 [-Scope All|EmptyVariable]
  Exit code: 0 = everything passed, 1 = a check failed, 3 = pre-check failed (nothing was started).
#>
[CmdletBinding()]
param(
    [string] $ContainerName = 'prodflow-kc-importcheck',
    [int]    $Port = 8181,
    [string] $Image = 'quay.io/keycloak/keycloak:26.4.0',
    [ValidateSet('All', 'EmptyVariable')] [string] $Scope = 'All'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web
$repo = Split-Path -Parent $PSScriptRoot
$realmFile = Join-Path $repo 'keycloak\prodflow-realm.json'
$base = "http://localhost:$Port"
$AppUrl = 'http://localhost:8080'
$script:Failures = 0
$script:Passes = 0

function Report([bool] $ok, [string] $label, [string] $detail = '') {
    if ($ok) { $script:Passes++ } else { $script:Failures++ }
    $text = '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label
    if ($detail) { $text += "  ($detail)" }
    Write-Host $text
}
function New-Secret { $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b) }
function Items($x) { , @($x | ForEach-Object { $_ }) }
function Get-Admin([string] $Path) { Items (Invoke-RestMethod -Headers $script:AdminHeaders "$base/admin/realms/prodflow$Path") }
# Removes the disposable container if it exists. `docker rm -f` on a missing container writes to stderr, which Windows PowerShell 5.1
# turns into a terminating error under ErrorActionPreference=Stop, so the call is wrapped.
function Remove-Disposable { & { $ErrorActionPreference = 'Continue'; docker rm -f $ContainerName 2>$null | Out-Null } }
function Connect-Admin {
    $t = (Invoke-RestMethod -Method Post -Uri "$base/realms/master/protocol/openid-connect/token" -Body @{
            grant_type = 'password'; client_id = 'admin-cli'; username = 'importcheck'; password = $env:KC_BOOTSTRAP_ADMIN_PASSWORD }).access_token
    $script:AdminHeaders = @{ Authorization = "Bearer $t" }
}

# ---- minimal browser-style login probe: "is this exact password accepted?" (Authorization Code + PKCE S256, no password grant).
#      Returns 'accepted' | 'rejected' | 'error: ...'. Used only to judge Keycloak's behaviour; never prints credentials. ----
function Send-Probe($Http, [string] $Method, [string] $Url, [hashtable] $Jar, [hashtable] $Form) {
    $verb = if ($Method -eq 'POST') { [System.Net.Http.HttpMethod]::Post } else { [System.Net.Http.HttpMethod]::Get }
    $req = New-Object System.Net.Http.HttpRequestMessage($verb, $Url)
    if ($Jar.Count -gt 0) { [void] $req.Headers.TryAddWithoutValidation('Cookie', (($Jar.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')) }
    if ($Form) {
        $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        foreach ($k in $Form.Keys) { $dict[$k] = [string] $Form[$k] }
        $req.Content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $dict)
    }
    $resp = $Http.SendAsync($req).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $values = $null
    if ($resp.Headers.TryGetValues('Set-Cookie', [ref] $values)) {
        foreach ($c in $values) {
            $pair = ($c -split ';')[0]; $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $pair.Substring(0, $eq).Trim(); $val = $pair.Substring($eq + 1).Trim()
            if ($val -eq '' -or $c -match '(?i)max-age=0|expires=[^;]*1970') { $Jar.Remove($name) } else { $Jar[$name] = $val }
        }
    }
    $loc = ''; if ($resp.Headers.Location) { $loc = $resp.Headers.Location.OriginalString }
    [pscustomobject] @{ Status = [int] $resp.StatusCode; Location = $loc; Body = $body }
}

function Test-KeycloakLogin([string] $User, [AllowEmptyString()] [string] $Password, [string] $ClientId, [string] $RedirectUri) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
    $http = New-Object System.Net.Http.HttpClient($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $verifier = ([Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 } | ForEach-Object { [byte] $_ }))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $challenge = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $url = "$base/realms/prodflow/protocol/openid-connect/auth?client_id=$ClientId&response_type=code&redirect_uri=$([uri]::EscapeDataString($RedirectUri))&state=probe&code_challenge=$challenge&code_challenge_method=S256"
        $jar = @{}
        $page = Send-Probe $http 'GET' $url $jar $null
        $tag = [regex]::Match($page.Body, '<form\b[^>]*\bid="kc-form-login"[^>]*>')
        if ($page.Status -ne 200 -or -not $tag.Success) { return "error: no login form (HTTP $($page.Status))" }
        $action = [System.Net.WebUtility]::HtmlDecode([regex]::Match($tag.Value, '\baction="([^"]*)"').Groups[1].Value)
        $post = Send-Probe $http 'POST' $action $jar @{ username = $User; password = $Password }
        if (($post.Status -eq 302) -and ($post.Location.StartsWith($RedirectUri)) -and ($post.Location -match '[?&]code=')) { return 'accepted' }
        if (($post.Status -eq 200) -and ($post.Body -match 'id="kc-form-login"')) { return 'rejected' }
        $msg = ''
        $m = [regex]::Match($post.Body, 'kc-feedback-text[^>]*>([^<]+)<')
        if (-not $m.Success) { $m = [regex]::Match($post.Body, 'id="kc-error-message"[\s\S]*?<p[^>]*>([^<]+)<') }
        if ($m.Success) { $msg = ': ' + ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()) }
        return "error: unexpected answer (HTTP $($post.Status))$msg"
    }
    catch { return "error: $($_.Exception.Message)" }
    finally { $http.Dispose() }
}

# ---- full import check (imports the real realm file, verifies it, runs smoke-auth, rotation, unset-variable control) ----
function Invoke-FullImportCheck {
    docker run -d --rm --name $ContainerName --label prodflow.purpose=importcheck -p "127.0.0.1:${Port}:8080" `
        -e KC_BOOTSTRAP_ADMIN_USERNAME -e KC_BOOTSTRAP_ADMIN_PASSWORD -e DEMO_PLANNER_PASSWORD -e DEMO_PURCHASER_PASSWORD -e DEMO_ADMIN_PASSWORD -e PRODFLOW_APP_URL `
        -v "${realmFile}:/opt/keycloak/data/import/prodflow-realm.json:ro" $Image start-dev --import-realm | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 90 -and -not $ready; $i++) {
        Start-Sleep -Seconds 2
        try { $ready = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$base/realms/prodflow").StatusCode -eq 200) } catch { }
    }
    if (-not $ready) { throw 'Keycloak did not become ready in time' }
    Write-Host "Keycloak $Image ready after ~$($i * 2) s on $base"

    # ---- import verification through the admin API (no secrets, no full exports) ----
    $logs = (docker logs $ContainerName 2>&1 | Out-String) -split "`n"
    Report ([bool]($logs | Where-Object { $_ -match "Realm 'prodflow' imported" })) "realm import reported success in the log"
    Report (@($logs | Where-Object { $_ -match ' (WARN|ERROR) ' }).Count -eq 0) 'no WARN/ERROR lines during startup'

    Connect-Admin
    $realm = Invoke-RestMethod -Headers $script:AdminHeaders "$base/admin/realms/prodflow"
    Report ($realm.accessTokenLifespan -eq 300) 'realm default access token lifespan is 300 s' "actual=$($realm.accessTokenLifespan)"

    $clients = Get-Admin '/clients'
    $web = @($clients | Where-Object { $_.clientId -eq 'prodflow-web' })[0]
    $swagger = @($clients | Where-Object { $_.clientId -eq 'prodflow-swagger' })[0]
    Report ([bool]$swagger -and $swagger.attributes.'access.token.lifespan' -eq '1800') 'prodflow-swagger has client-specific lifespan 1800 s'
    Report (([bool]$web) -and -not $web.attributes.'access.token.lifespan' -and (($web.redirectUris -join '|') -eq 'http://localhost:4200/*')) 'prodflow-web unchanged (Angular only, no custom lifespan)'
    Report ((($swagger.redirectUris -join '|') -eq "$AppUrl/swagger-ui/oauth2-redirect.html") -and (($swagger.webOrigins -join '|') -eq $AppUrl)) 'prodflow-swagger redirect URI and web origin resolved from PRODFLOW_APP_URL'

    $users = foreach ($n in 'planner', 'purchaser', 'admin') { (Get-Admin "/users?username=$n&exact=true")[0] }
    Report (@($users | Where-Object { @($_.requiredActions).Count -gt 0 }).Count -eq 0) 'no demo user has required actions (no profile/password update screen)'

    # application-specific placeholders only (Keycloak's own ${client_...} keys are expected and ignored)
    $scan = (@($realm) + $clients + $users) | ConvertTo-Json -Depth 30 -Compress
    $leftover = ([regex]::Matches($scan, '\$\{(DEMO_|PRODFLOW_)')).Count
    Report ($leftover -eq 0) 'no unresolved application placeholders (${DEMO_*}, ${PRODFLOW_*}) in realm, clients, users' "occurrences=$leftover"

    # ---- real Authorization Code + PKCE logins ----
    Write-Host '--- smoke-auth: Swagger client (1800 s)'
    & (Join-Path $PSScriptRoot 'smoke-auth.ps1') -KeycloakUrl $base -ClientId 'prodflow-swagger' -RedirectUri "$AppUrl/swagger-ui/oauth2-redirect.html" -ExpectedLifespan 1800
    $swaggerExit = $LASTEXITCODE
    Report ($swaggerExit -eq 0) 'smoke-auth for prodflow-swagger finished without failures' "exit=$swaggerExit"
    Write-Host '--- smoke-auth: web client keeps the realm default (300 s)'
    & (Join-Path $PSScriptRoot 'smoke-auth.ps1') -KeycloakUrl $base -ClientId 'prodflow-web' -RedirectUri 'http://localhost:4200/callback' -ExpectedLifespan 300 -Users planner -SkipUserSwitching -SkipPkceNegative
    $webExit = $LASTEXITCODE
    Report ($webExit -eq 0) 'smoke-auth for prodflow-web finished without failures' "exit=$webExit"

    # ---- password rotation without a rebuild (the documented procedure): kcadm in the container, secrets only via environment ----
    Write-Host '--- password rotation with kcadm (purchaser), then login with the new password'
    $env:KC_CLI_PASSWORD = $env:KC_BOOTSTRAP_ADMIN_PASSWORD
    # kcadm reports progress on stderr; in Windows PowerShell 5.1 that would abort the script under ErrorActionPreference=Stop
    & { $ErrorActionPreference = 'Continue'; docker exec -e KC_CLI_PASSWORD $ContainerName /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user importcheck 2>$null | Out-Null }
    $loginOk = ($LASTEXITCODE -eq 0)
    $rotated = $false
    if ($loginOk) {
        $newPassword = New-Secret
        $env:KC_CLI_PASSWORD = $newPassword
        & { $ErrorActionPreference = 'Continue'; docker exec -e KC_CLI_PASSWORD $ContainerName /opt/keycloak/bin/kcadm.sh set-password -r prodflow --username purchaser 2>$null | Out-Null }
        $rotated = ($LASTEXITCODE -eq 0)
    }
    Report ($loginOk -and $rotated) 'kcadm: authenticate as admin and set a new purchaser password (values only via environment variables)'
    if ($rotated) {
        $env:DEMO_PURCHASER_PASSWORD = $newPassword
        & (Join-Path $PSScriptRoot 'smoke-auth.ps1') -KeycloakUrl $base -ClientId 'prodflow-swagger' -RedirectUri "$AppUrl/swagger-ui/oauth2-redirect.html" -ExpectedLifespan 1800 -Users purchaser -SkipUserSwitching -SkipPkceNegative
        Report ($LASTEXITCODE -eq 0) 'purchaser logs in with the rotated password' "exit=$LASTEXITCODE"
    }
    $newPassword = $null

    # ---- negative control: an import with UNSET password variables must be flagged. Keycloak does not fail closed for these:
    #      it stores the placeholder text itself as the password, so smoke-auth must report that as a failure. ----
    Write-Host '--- negative control: realm imported with unset password variables must be flagged'
    Remove-Disposable
    foreach ($v in 'KC_CLI_PASSWORD', 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    docker run -d --rm --name $ContainerName --label prodflow.purpose=importcheck -p "127.0.0.1:${Port}:8080" `
        -e KC_BOOTSTRAP_ADMIN_USERNAME -e KC_BOOTSTRAP_ADMIN_PASSWORD -e PRODFLOW_APP_URL `
        -v "${realmFile}:/opt/keycloak/data/import/prodflow-realm.json:ro" $Image start-dev --import-realm | Out-Null
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 2
        if (-not (docker ps --filter "name=^$ContainerName$" --format '{{.Names}}')) { break }
        try { $ready = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$base/realms/prodflow").StatusCode -eq 200) } catch { }
    }
    Report $ready 'negative control: Keycloak started without the password variables (the unsafe configuration)'
    if ($ready) {
        $env:DEMO_PLANNER_PASSWORD = '${DEMO_PLANNER_PASSWORD}'   # what an operator who forgot the variable would "know"
        $guardOut = (& (Join-Path $PSScriptRoot 'smoke-auth.ps1') -KeycloakUrl $base -ClientId 'prodflow-web' -RedirectUri 'http://localhost:4200/callback' -ExpectedLifespan 300 -Users planner -SkipUserSwitching -SkipPkceNegative 6>&1 | Out-String)
        $guardExit = $LASTEXITCODE
        Report (($guardExit -eq 1) -and ($guardOut -match 'FAIL\s+planner: the literal placeholder text is not accepted')) 'guard works: smoke-auth flags the unset-variable import as a failure' "exit=$guardExit"
    }
}

# ---- empty-variable control. DEMO_PLANNER_PASSWORD is present but EMPTY at import (docker run -e NAME=), which is different from
#      "unset" (covered above: Keycloak imports silently and stores the placeholder text). Question: does Keycloak refuse the import,
#      create a user without a usable password, or store something that logs in (empty text or the literal placeholder)?
#      Safe outcomes: refused to start, or started and neither the empty text nor the placeholder text is accepted.
#      The probe is validated first: the purchaser (valid password) must be accepted and a random wrong password rejected. ----
function Invoke-EmptyVariableControl {
    Write-Host '--- empty-variable control: DEMO_PLANNER_PASSWORD is set but EMPTY at import (not unset)'
    Remove-Disposable
    Start-Sleep -Seconds 2
    $purchaserPw = New-Secret
    $env:DEMO_PURCHASER_PASSWORD = $purchaserPw
    $env:DEMO_ADMIN_PASSWORD = New-Secret
    Remove-Item env:DEMO_PLANNER_PASSWORD -ErrorAction SilentlyContinue   # PowerShell cannot hold an empty env var; Docker gets it explicitly below
    # No --rm: if Keycloak refuses to start, its log must survive to classify the outcome.
    docker run -d --name $ContainerName --label prodflow.purpose=importcheck -p "127.0.0.1:${Port}:8080" `
        -e KC_BOOTSTRAP_ADMIN_USERNAME -e KC_BOOTSTRAP_ADMIN_PASSWORD -e PRODFLOW_APP_URL -e DEMO_PURCHASER_PASSWORD -e DEMO_ADMIN_PASSWORD -e DEMO_PLANNER_PASSWORD= `
        -v "${realmFile}:/opt/keycloak/data/import/prodflow-realm.json:ro" $Image start-dev --import-realm | Out-Null

    $envLines = (docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $ContainerName) -split "`r?`n"
    $plannerEmpty = [bool]($envLines | Where-Object { $_ -eq 'DEMO_PLANNER_PASSWORD=' })
    $othersSet = [bool]($envLines | Where-Object { $_ -match '^DEMO_PURCHASER_PASSWORD=.+' }) -and [bool]($envLines | Where-Object { $_ -match '^DEMO_ADMIN_PASSWORD=.+' })
    $envLines = $null
    Report ($plannerEmpty -and $othersSet) 'test setup: DEMO_PLANNER_PASSWORD is present but empty (not unset); the other two are set'

    $state = ''; $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 2
        $state = (docker inspect -f '{{.State.Status}}' $ContainerName)
        if ($state -ne 'running') { break }
        try { $ready = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$base/realms/prodflow").StatusCode -eq 200) } catch { }
    }

    if (-not $ready) {
        $exitCode = docker inspect -f '{{.State.ExitCode}}' $ContainerName
        $logs = (docker logs $ContainerName 2>&1 | Out-String) -split "`r?`n"
        $reasons = @($logs | Where-Object { $_ -match 'ERROR' -and $_ -notmatch 'For more details' } | ForEach-Object { (($_ -replace '^\S+\s+\S+\s+', '').Trim() -replace '[A-Za-z0-9+/=]{24,}', '<hidden>') } | Select-Object -First 2)
        Write-Host "    | outcome: REFUSED  (container state=$state, exit code $exitCode)"
        $reasons | ForEach-Object { Write-Host ("    | reason: " + $_.Substring(0, [Math]::Min(200, $_.Length))) }
        Report ($state -ne 'running') 'empty variable: Keycloak refused to start with an empty password variable (fail-closed)' "container state=$state"
        return
    }

    Write-Host '    | outcome: STARTED (Keycloak did not refuse the import); probing what was stored'
    Connect-Admin
    $planner = (Get-Admin '/users?username=planner&exact=true')
    $created = $planner.Count -gt 0
    $credCount = 0
    if ($created) { $credCount = (Get-Admin "/users/$($planner[0].id)/credentials").Count }
    Write-Host "    | planner user created: $created; password credentials stored: $credCount"
    # non-secret credential metadata only (property names and the hashing algorithm; never the secret data)
    foreach ($n in 'planner', 'purchaser') {
        $u = (Get-Admin "/users?username=$n&exact=true")
        if ($u.Count -eq 0) { continue }
        $c = (Get-Admin "/users/$($u[0].id)/credentials") | Select-Object -First 1
        $meta = $null; if ($c -and $c.credentialData) { try { $meta = $c.credentialData | ConvertFrom-Json } catch { } }
        $keys = if ($meta) { ($meta.PSObject.Properties.Name -join ',') } else { '(none)' }
        $algo = if ($meta -and $meta.algorithm) { $meta.algorithm } else { '(none)' }
        Write-Host "    | $n credential: type=$($c.type); credentialData keys=$keys; algorithm=$algo"
    }

    $client = 'prodflow-swagger'; $redirect = "$AppUrl/swagger-ui/oauth2-redirect.html"
    $positive = Test-KeycloakLogin 'purchaser' $purchaserPw $client $redirect
    Report ($positive -eq 'accepted') 'probe validity: the purchaser (valid password) is accepted' $positive
    Start-Sleep -Milliseconds 1500
    $wrong = Test-KeycloakLogin 'admin' (New-Secret) $client $redirect   # random wrong password on a healthy user: the probe must be able to say "rejected"
    Report ($wrong -eq 'rejected') 'probe validity: a random wrong password is rejected (healthy user)' $wrong
    Start-Sleep -Milliseconds 1500
    $literal = Test-KeycloakLogin 'planner' '${DEMO_PLANNER_PASSWORD}' $client $redirect
    Report ($literal -ne 'accepted') 'SECURITY: with an empty variable the literal placeholder text is NOT accepted as planner password' $literal
    Start-Sleep -Milliseconds 1500
    $other = Test-KeycloakLogin 'planner' (New-Secret) $client $redirect   # any other non-empty password, to see how planner behaves normally
    Report ($other -ne 'accepted') 'SECURITY: with an empty variable no other password is accepted for planner' $other
    Start-Sleep -Milliseconds 1500
    $empty = Test-KeycloakLogin 'planner' '' $client $redirect
    Report ($empty -ne 'accepted') 'SECURITY: with an empty variable an EMPTY password is NOT accepted for planner' $empty

    $classification = if ($literal -eq 'accepted') { 'IMPORTED_LITERALLY (vulnerable: the placeholder text is the password)' }
    elseif ($empty -eq 'accepted') { 'EMPTY_PASSWORD_USABLE (vulnerable: the user can log in with an empty password)' }
    elseif ($other -eq 'rejected' -and $literal -eq 'rejected') { 'CREDENTIAL_STORED_BUT_NOT_GUESSABLE (normal rejection of every tested password)' }
    else { 'UNUSABLE_CREDENTIAL (planner cannot log in; Keycloak answers non-empty passwords with an error instead of a normal rejection)' }
    Write-Host "    | classification: $classification"
    Write-Host "    | outcomes: literal=$literal | other non-empty=$other | empty=$empty"

    # server-side evidence for the abnormal answers (first line of each ERROR/WARN record, long tokens masked)
    $serverLines = ((docker logs $ContainerName 2>&1 | Out-String) -split "`r?`n") | Where-Object { $_ -match ' (ERROR|WARN) ' } |
        ForEach-Object { (($_ -replace '^\S+\s+\S+\s+', '').Trim() -replace '[A-Za-z0-9+/=]{24,}', '<hidden>') } | Select-Object -Unique -First 4
    foreach ($l in $serverLines) { Write-Host ('    | server log: ' + $l.Substring(0, [Math]::Min(220, $l.Length))) }
}

# ---- pre-checks: abort before starting anything ----
if ($Port -eq 8180) { Write-Host 'ABORT: port 8180 is the local development Keycloak; this test only ever uses a disposable instance'; exit 3 }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { Write-Host "ABORT: port $Port is already in use"; exit 3 }
if (docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}') { Write-Host "ABORT: container $ContainerName already exists"; exit 3 }
if (-not (Test-Path $realmFile)) { Write-Host "ABORT: realm file not found"; exit 3 }
$volumesBefore = (docker volume ls -q | Measure-Object).Count

$env:KC_BOOTSTRAP_ADMIN_USERNAME = 'importcheck'
$env:KC_BOOTSTRAP_ADMIN_PASSWORD = New-Secret
$env:DEMO_PLANNER_PASSWORD = New-Secret
$env:DEMO_PURCHASER_PASSWORD = New-Secret
$env:DEMO_ADMIN_PASSWORD = New-Secret
$env:PRODFLOW_APP_URL = $AppUrl
try {
    if ($Scope -eq 'All') { Invoke-FullImportCheck }
    Invoke-EmptyVariableControl
}
catch {
    Report $false 'harness' $_.Exception.Message
}
finally {
    Remove-Disposable
    foreach ($v in 'KC_BOOTSTRAP_ADMIN_USERNAME', 'KC_BOOTSTRAP_ADMIN_PASSWORD', 'KC_CLI_PASSWORD', 'DEMO_PLANNER_PASSWORD', 'DEMO_PURCHASER_PASSWORD', 'DEMO_ADMIN_PASSWORD', 'PRODFLOW_APP_URL') {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }
    $script:AdminHeaders = $null
}

Write-Host '--- cleanup'
Start-Sleep -Seconds 2
$leftContainer = [bool](docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}')
$volumesAfter = (docker volume ls -q | Measure-Object).Count
$portBusy = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
Report (-not $leftContainer) 'disposable container removed'
Report ($volumesAfter -eq $volumesBefore) 'no Docker volume left behind' "before=$volumesBefore after=$volumesAfter"
Report (-not $portBusy) "port $Port released"
Write-Host ("test-realm-import result: {0} PASS, {1} FAIL" -f $script:Passes, $script:Failures)
if ($script:Failures -eq 0) { exit 0 } else { exit 1 }
