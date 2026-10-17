<#
.SYNOPSIS
  Idempotent catch-up of an EXISTING Keycloak realm to the Swagger demo configuration (Issue #8): adds the public client
  prodflow-swagger and the demo users planner/purchaser/admin. Needed because Keycloak imports realm files only when a realm
  is created, so a realm created from the old import file never gets the new client and users.

.DESCRIPTION
  Safe by design:
  - Only ADDS. Never deletes or replaces the realm, clients, roles or users; prodflow-web, prodflow-api, realm settings (incl. the
    realm-wide 300 s token lifetime) are not touched.
  - Reads and validates everything first. If an existing client or user conflicts with the desired state, it reports every conflict
    and stops WITHOUT changing anything (exit 4). It never overwrites.
  - Idempotent: a second run finds everything in place and changes nothing. Existing users keep their passwords (never reset).
  - Fails safely when the passwords or the application URL are missing, empty, too short or unresolved placeholders (exit 3).
  - Secrets: demo passwords and admin credentials come only from environment variables, travel only in HTTPS/HTTP request bodies
    (never in URLs or command-line arguments) and are never printed. Credentials are never sent over plain HTTP to a remote host.

  Environment: DEMO_PLANNER_PASSWORD, DEMO_PURCHASER_PASSWORD, DEMO_ADMIN_PASSWORD (min. 12 characters, all different) and the
  admin login (KC_BOOTSTRAP_ADMIN_USERNAME / KC_BOOTSTRAP_ADMIN_PASSWORD by default; names can be changed with the parameters).
  Exit codes: 0 = done or already up to date, 2 = unexpected error (re-run is safe), 3 = invalid input/prerequisite (nothing changed),
  4 = conflicts found (nothing changed).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $KeycloakUrl,          # base URL of the Keycloak server, e.g. http://localhost:8180
    [Parameter(Mandatory)] [string] $AppUrl,               # public base URL of the app = PRODFLOW_APP_URL, e.g. http://localhost:8080
    [string] $Realm = 'prodflow',
    [string] $AdminUserVariable = 'KC_BOOTSTRAP_ADMIN_USERNAME',
    [string] $AdminPasswordVariable = 'KC_BOOTSTRAP_ADMIN_PASSWORD',
    [switch] $DryRun                                       # validate and show what would happen, change nothing
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppRoles = @('ADMIN', 'PLANNER', 'PURCHASER')
$SwaggerClientId = 'prodflow-swagger'
$ApiClientId = 'prodflow-api'
$DemoUsers = @(
    @{ Name = 'planner';   Role = 'PLANNER';   Var = 'DEMO_PLANNER_PASSWORD' },
    @{ Name = 'purchaser'; Role = 'PURCHASER'; Var = 'DEMO_PURCHASER_PASSWORD' },
    @{ Name = 'admin';     Role = 'ADMIN';     Var = 'DEMO_ADMIN_PASSWORD' }
)

function Say([string] $Text) { Write-Host $Text }
function Quit([int] $Code, [string] $Text) { if ($Text) { Say $Text }; exit $Code }
function Same-Set($A, $B) { ((@($A) | Sort-Object) -join '|') -eq ((@($B) | Sort-Object) -join '|') }

# ---------------------------------------------------------------- 1. validate inputs (no network yet)
$problems = New-Object System.Collections.Generic.List[string]

$kc = $null
try { $kc = [uri] $KeycloakUrl } catch { }
if (-not $kc -or -not $kc.IsAbsoluteUri -or @('http', 'https') -notcontains $kc.Scheme) {
    $problems.Add('KeycloakUrl is not an absolute http(s) URL')
} elseif (($kc.Scheme -ne 'https') -and (@('localhost', '127.0.0.1') -notcontains $kc.Host)) {
    $problems.Add("refusing to send credentials over plain HTTP to '$($kc.Host)'; use https:// (http is only allowed for localhost)")
}
$KeycloakUrl = $KeycloakUrl.TrimEnd('/')

$app = $null
if ($AppUrl -match '\$\{') {
    $problems.Add('AppUrl is an unresolved placeholder')
} else {
    try { $app = [uri] $AppUrl } catch { }
    if (-not $app -or -not $app.IsAbsoluteUri -or @('http', 'https') -notcontains $app.Scheme -or
        (@('', '/') -notcontains $app.AbsolutePath) -or $app.Query -or $app.Fragment) {
        $problems.Add('AppUrl must be an absolute http(s) base URL without path, query or fragment (e.g. http://localhost:8080)')
        $app = $null
    }
}

$passwords = @{}
foreach ($u in $DemoUsers) {
    $value = [Environment]::GetEnvironmentVariable($u.Var)
    if ([string]::IsNullOrWhiteSpace($value)) { $problems.Add("$($u.Var) is not set or empty") }
    elseif ($value -match '\$\{') { $problems.Add("$($u.Var) is an unresolved placeholder") }
    elseif ($value.Length -lt 12) { $problems.Add("$($u.Var) is too short (minimum 12 characters)") }
    else { $passwords[$u.Name] = $value }
}
if ($passwords.Count -eq 3 -and (@($passwords.Values | Sort-Object -Unique).Count -ne 3)) { $problems.Add('the three demo passwords must be different') }

$adminUser = [Environment]::GetEnvironmentVariable($AdminUserVariable)
$adminPw = [Environment]::GetEnvironmentVariable($AdminPasswordVariable)
if ([string]::IsNullOrWhiteSpace($adminUser)) { $problems.Add("$AdminUserVariable is not set or empty") }
if ([string]::IsNullOrWhiteSpace($adminPw)) { $problems.Add("$AdminPasswordVariable is not set or empty") }

if ($problems.Count -gt 0) {
    Say 'ABORT: invalid input, nothing was changed:'
    $problems | ForEach-Object { Say "  - $_" }
    exit 3
}
$AppOrigin = $app.GetLeftPart([System.UriPartial]::Authority)
$RedirectUri = "$AppOrigin/swagger-ui/oauth2-redirect.html"

# ---------------------------------------------------------------- Keycloak Admin REST helpers
$script:Token = $null
function Connect-Admin {
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
            grant_type = 'password'; client_id = 'admin-cli'; username = $adminUser; password = $adminPw }
        $script:Token = $r.access_token
    } catch {
        $code = 0; if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
        Quit 3 "ABORT: admin authentication failed (HTTP $code); check the URL and $AdminUserVariable / $AdminPasswordVariable"
    }
}

# Windows PowerShell 5.1 returns a JSON array from ConvertFrom-Json as ONE object (so "[]" looks like one item). Normalize to an
# array of items: [] -> 0 items, [a,b] -> 2 items, {a} -> 1 item.
function ConvertTo-Items([string] $Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { return , @() }
    $parsed = ConvertFrom-Json -InputObject $Json
    if ($null -eq $parsed) { return , @() }
    if ($parsed -is [System.Array]) { return , $parsed }
    return , @($parsed)
}

# Returns Status, Items (always an array) and Data (first item). Retries once after re-authentication (admin tokens are short-lived).
function Invoke-Kc([string] $Method, [string] $Path, $Body = $null) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $p = @{ Method = $Method; Uri = "$KeycloakUrl/admin/realms/$Realm$Path"; Headers = @{ Authorization = "Bearer $script:Token" }; UseBasicParsing = $true }
        if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
        try {
            $r = Invoke-WebRequest @p
            $items = ConvertTo-Items $r.Content
            $loc = ''
            if ($r.Headers['Location']) { $loc = [string] $r.Headers['Location'] }
            $first = $null
            if ($items.Count -ge 1) { $first = $items[0] }
            return [pscustomobject] @{ Status = [int] $r.StatusCode; Items = $items; Data = $first; Location = $loc }
        } catch {
            $code = 0; if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
            if ($code -eq 401 -and $attempt -eq 0) { Connect-Admin; continue }
            return [pscustomobject] @{ Status = $code; Items = @(); Data = $null; Location = '' }
        }
    }
}

# ---------------------------------------------------------------- desired state
function New-SwaggerClient {
    @{
        clientId = $SwaggerClientId; name = 'ProdFlow Swagger UI (demo client)'; enabled = $true; protocol = 'openid-connect'
        publicClient = $true; standardFlowEnabled = $true; implicitFlowEnabled = $false
        directAccessGrantsEnabled = $false; serviceAccountsEnabled = $false
        redirectUris = @($RedirectUri); webOrigins = @($AppOrigin)
        attributes = @{ 'pkce.code.challenge.method' = 'S256'; 'access.token.lifespan' = '1800' }
        protocolMappers = @(@{
                name = 'prodflow-api-audience'; protocol = 'openid-connect'; protocolMapper = 'oidc-audience-mapper'; consentRequired = $false
                config = @{ 'included.client.audience' = $ApiClientId; 'access.token.claim' = 'true'; 'id.token.claim' = 'false' } })
    }
}

# Every difference between an existing client and the desired state (extra settings Keycloak adds by default are fine)
function Get-ClientProblems($c) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(@('enabled', $true), @('publicClient', $true), @('standardFlowEnabled', $true), @('implicitFlowEnabled', $false),
            @('directAccessGrantsEnabled', $false), @('serviceAccountsEnabled', $false))) {
        if ([bool] $c.($pair[0]) -ne $pair[1]) { $p.Add("$($pair[0]) is $($c.($pair[0])), expected $($pair[1])") }
    }
    if (-not (Same-Set $c.redirectUris @($RedirectUri))) { $p.Add("redirectUris are [$(@($c.redirectUris) -join ', ')], expected [$RedirectUri]") }
    if (-not (Same-Set $c.webOrigins @($AppOrigin))) { $p.Add("webOrigins are [$(@($c.webOrigins) -join ', ')], expected [$AppOrigin]") }
    if ($c.attributes.'pkce.code.challenge.method' -ne 'S256') { $p.Add("pkce.code.challenge.method is '$($c.attributes.'pkce.code.challenge.method')', expected 'S256'") }
    if ($c.attributes.'access.token.lifespan' -ne '1800') { $p.Add("access.token.lifespan is '$($c.attributes.'access.token.lifespan')', expected '1800'") }
    $mappers = @(@($c.protocolMappers) | Where-Object { $_.protocolMapper -eq 'oidc-audience-mapper' })
    if ($mappers.Count -ne 1) { $p.Add("expected exactly one audience mapper, found $($mappers.Count)") }
    elseif (($mappers[0].config.'included.client.audience' -ne $ApiClientId) -or ($mappers[0].config.'access.token.claim' -ne 'true')) {
        $p.Add("the audience mapper does not add $ApiClientId to the access token")
    }
    $p.ToArray()
}

function Get-UserProblems($u, [string] $role) {
    $p = New-Object System.Collections.Generic.List[string]
    if (-not $u.enabled) { $p.Add('user is disabled') }
    if (@($u.requiredActions).Count -gt 0) { $p.Add("user has required actions ($(@($u.requiredActions) -join ', ')) that would interrupt the login") }
    $mapped = @((Invoke-Kc GET "/users/$($u.id)/role-mappings/realm").Items | ForEach-Object { $_.name })
    $app = @($mapped | Where-Object { $AppRoles -contains $_ })
    if (-not (Same-Set $app @($role))) { $p.Add("application roles are [$($app -join ', ')], expected exactly [$role]") }
    $creds = @((Invoke-Kc GET "/users/$($u.id)/credentials").Items | Where-Object { $_.type -eq 'password' })
    if ($creds.Count -eq 0) { $p.Add('user has no password credential (the script never sets passwords of existing users)') }
    $p.ToArray()
}

# ---------------------------------------------------------------- 2. read phase: current state and conflicts (no changes)
try {
    Say "provision-demo-realm: realm=$Realm keycloak=$KeycloakUrl app=$AppOrigin$(if ($DryRun) { ' (dry run)' })"
    $script:AdminUser = $adminUser
    Connect-Admin

    if ((Invoke-Kc GET '').Status -ne 200) { Quit 3 "ABORT: realm '$Realm' not found or not readable; this script only updates an existing realm" }
    $missing = @($AppRoles | Where-Object { (Invoke-Kc GET "/roles/$_").Status -ne 200 })
    if ($missing.Count -gt 0) { Quit 3 "ABORT: realm roles missing ($($missing -join ', ')); this script does not create roles" }
    if (@((Invoke-Kc GET "/clients?clientId=$ApiClientId").Items).Count -eq 0) { Quit 3 "ABORT: client $ApiClientId not found; the audience mapper would point to nothing" }

    $conflicts = New-Object System.Collections.Generic.List[string]
    $createClient = $false
    $found = @((Invoke-Kc GET "/clients?clientId=$SwaggerClientId").Items)
    if ($found.Count -eq 0) { $createClient = $true }
    else {
        $existing = (Invoke-Kc GET "/clients/$($found[0].id)").Data
        foreach ($c in (Get-ClientProblems $existing)) { $conflicts.Add("client ${SwaggerClientId}: $c") }
    }

    $createUsers = New-Object System.Collections.Generic.List[object]
    foreach ($u in $DemoUsers) {
        $hit = @((Invoke-Kc GET "/users?username=$($u.Name)&exact=true").Items)
        if ($hit.Count -eq 0) { $createUsers.Add($u) }
        else { foreach ($c in (Get-UserProblems $hit[0] $u.Role)) { $conflicts.Add("user $($u.Name): $c") } }
    }

    if ($conflicts.Count -gt 0) {
        Say "CONFLICTS: existing configuration differs from the desired state; nothing was changed ($($conflicts.Count)):"
        $conflicts | ForEach-Object { Say "  - $_" }
        Say 'Resolve them manually (or remove the conflicting object) and run again; the script never overwrites.'
        exit 4
    }

    # ------------------------------------------------------------ 3. apply phase (only additions)
    if ($createClient) { Say "$(if ($DryRun) { 'would create' } else { 'creating' }) client $SwaggerClientId" } else { Say "client ${SwaggerClientId}: already up to date" }
    foreach ($u in $DemoUsers) {
        if ($createUsers -contains $u) { Say "$(if ($DryRun) { 'would create' } else { 'creating' }) user $($u.Name) with role $($u.Role)" } else { Say "user $($u.Name): already up to date" }
    }
    if ($DryRun) { Say 'dry run: nothing was changed'; exit 0 }

    $created = 0
    if ($createClient) {
        $r = Invoke-Kc POST '/clients' (New-SwaggerClient)
        if ($r.Status -ne 201) { Quit 2 "ERROR: creating client $SwaggerClientId failed (HTTP $($r.Status)); nothing else was changed, re-running is safe" }
        $verify = (Invoke-Kc GET "/clients/$(($r.Location -split '/')[-1])").Data
        $bad = @(Get-ClientProblems $verify)
        if ($bad.Count -gt 0) { Quit 2 "ERROR: client $SwaggerClientId differs after creation: $($bad -join '; ')" }
        Say "client ${SwaggerClientId}: created"
        $created++
    }
    foreach ($u in $createUsers) {
        $body = @{
            username = $u.Name; enabled = $true; firstName = 'Demo'; lastName = (Get-Culture).TextInfo.ToTitleCase($u.Name)
            email = "$($u.Name)@prodflow.example"; emailVerified = $true
            credentials = @(@{ type = 'password'; value = $passwords[$u.Name]; temporary = $false })
        }
        $r = Invoke-Kc POST '/users' $body
        $body = $null
        if ($r.Status -ne 201) { Quit 2 "ERROR: creating user $($u.Name) failed (HTTP $($r.Status)); re-running is safe" }
        $id = ($r.Location -split '/')[-1]
        $role = (Invoke-Kc GET "/roles/$($u.Role)").Data
        $m = Invoke-Kc POST "/users/$id/role-mappings/realm" @(@{ id = $role.id; name = $role.name })
        if ($m.Status -ne 204) { Quit 2 "ERROR: assigning role $($u.Role) to $($u.Name) failed (HTTP $($m.Status)); the user exists without the role - re-running reports it as a conflict" }
        $bad = @(Get-UserProblems (Invoke-Kc GET "/users/$id").Data $u.Role)
        if ($bad.Count -gt 0) { Quit 2 "ERROR: user $($u.Name) differs after creation: $($bad -join '; ')" }
        Say "user $($u.Name): created with role $($u.Role)"
        $created++
    }
    Say "result: $created created, $(1 + $DemoUsers.Count - $created) unchanged, 0 conflicts"
    exit 0
}
catch {
    Say "ERROR: unexpected failure: $($_.Exception.Message)"
    exit 2
}
finally {
    $passwords = $null; $adminPw = $null; $script:Token = $null
}
