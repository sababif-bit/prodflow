<#
.SYNOPSIS
  Idempotent, ADD-ONLY catch-up of the public client prodflow-web in an EXISTING Keycloak realm so that the Angular application served
  by the backend can sign in and out: adds <AppUrl>/* to the redirect URIs, <AppUrl> to the web origins and <AppUrl>/* to the
  post-logout redirect URIs. Needed because Keycloak imports the realm file only when the realm is created (keycloak/prodflow-realm.json
  already contains the new values for NEW realms).

.DESCRIPTION
  Safe by design (same rules as scripts/provision-demo-realm.ps1):
  - Only ADDS. Existing redirect URIs, web origins, roles, users, other clients and realm settings are never removed or changed.
    When the client has no explicit post-logout list yet, Keycloak uses the redirect URIs for it; the script keeps exactly that
    behavior by starting from the current redirect URIs before it adds the new one.
  - Validates first. A client that is not the expected public PKCE client (confidential, implicit flow, password grant, no S256)
    is reported as a conflict and NOTHING is changed (exit 4).
  - Idempotent: a second run finds everything in place and changes nothing. -DryRun shows the result without writing.
  - Credentials only from environment variables (KC_BOOTSTRAP_ADMIN_USERNAME / KC_BOOTSTRAP_ADMIN_PASSWORD by default), never printed,
    never sent over plain HTTP to a remote host.
  Rollback: remove the three added values again in the admin console (or run the printed "before" values back); the login of the
  application stops working, nothing else is affected.

  Exit codes: 0 = done or already up to date, 2 = unexpected error (re-run is safe), 3 = invalid input/prerequisite (nothing changed),
  4 = conflict found (nothing changed).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $KeycloakUrl,          # base URL of Keycloak as reachable from here, e.g. http://localhost:18180 (SSH tunnel)
    [Parameter(Mandatory)] [string] $AppUrl,               # public base URL of the application = PRODFLOW_APP_URL, e.g. https://app.example.org
    [string] $Realm = 'prodflow',
    [string] $ClientId = 'prodflow-web',
    [string] $AdminUserVariable = 'KC_BOOTSTRAP_ADMIN_USERNAME',
    [string] $AdminPasswordVariable = 'KC_BOOTSTRAP_ADMIN_PASSWORD',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say([string] $Text) { Write-Host $Text }
function Quit([int] $Code, [string] $Text) { if ($Text) { Say $Text }; exit $Code }
function Local-Host([uri] $U) { @('localhost', '127.0.0.1') -contains $U.Host }

# ---------------------------------------------------------------- 1. validate inputs (no network yet)
$problems = New-Object System.Collections.Generic.List[string]
$kc = $null; try { $kc = [uri] $KeycloakUrl } catch { }
if (-not $kc -or -not $kc.IsAbsoluteUri -or @('http', 'https') -notcontains $kc.Scheme) { $problems.Add('KeycloakUrl is not an absolute http(s) URL') }
elseif ($kc.Scheme -ne 'https' -and -not (Local-Host $kc)) { $problems.Add("refusing to send credentials over plain HTTP to '$($kc.Host)' (http is only allowed for localhost / an SSH tunnel)") }
$KeycloakUrl = $KeycloakUrl.TrimEnd('/')

$app = $null
if ($AppUrl -match '\$\{') { $problems.Add('AppUrl is an unresolved placeholder') }
else {
    try { $app = [uri] $AppUrl } catch { }
    if (-not $app -or -not $app.IsAbsoluteUri -or @('http', 'https') -notcontains $app.Scheme -or @('', '/') -notcontains $app.AbsolutePath -or $app.Query -or $app.Fragment) {
        $problems.Add('AppUrl must be an absolute http(s) base URL without path, query or fragment (e.g. https://app.example.org)'); $app = $null
    } elseif ($app.Scheme -ne 'https' -and -not (Local-Host $app)) { $problems.Add('AppUrl must use https (http is only accepted for localhost)'); $app = $null }
}
$adminUser = [Environment]::GetEnvironmentVariable($AdminUserVariable)
$adminPw = [Environment]::GetEnvironmentVariable($AdminPasswordVariable)
if ([string]::IsNullOrWhiteSpace($adminUser)) { $problems.Add("$AdminUserVariable is not set or empty") }
if ([string]::IsNullOrWhiteSpace($adminPw)) { $problems.Add("$AdminPasswordVariable is not set or empty") }
if ($problems.Count -gt 0) { Say 'ABORT: invalid input, nothing was changed:'; $problems | ForEach-Object { Say "  - $_" }; exit 3 }

$Origin = $app.GetLeftPart([System.UriPartial]::Authority)
$AddRedirect = "$Origin/*"; $AddOrigin = $Origin; $AddLogout = "$Origin/*"

# ---------------------------------------------------------------- 2. read
function Admin-Call([string] $Method, [string] $Path, $Body = $null, [string] $Token) {
    $p = @{ Method = $Method; Uri = "$KeycloakUrl$Path"; Headers = @{ Authorization = "Bearer $Token" }; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    Invoke-WebRequest @p
}
try {
    $t = Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" -Body @{
        grant_type = 'password'; client_id = 'admin-cli'; username = $adminUser; password = $adminPw }
    $token = $t.access_token
} catch {
    $code = 0; if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
    Quit 3 "ABORT: admin authentication failed (HTTP $code); check the URL and $AdminUserVariable / $AdminPasswordVariable"
}

try {
    $list = (Admin-Call GET "/admin/realms/$Realm/clients?clientId=$ClientId" $null $token).Content | ConvertFrom-Json
    $match = @($list | Where-Object { $_.clientId -eq $ClientId })
    if ($match.Count -ne 1) { Quit 4 "CONFLICT: client '$ClientId' not found in realm '$Realm' (found $($match.Count)); nothing was changed" }
    $client = (Admin-Call GET "/admin/realms/$Realm/clients/$($match[0].id)" $null $token).Content | ConvertFrom-Json
} catch { Quit 2 "ERROR while reading the client: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 3. validate the client, compute the additions
$conflicts = New-Object System.Collections.Generic.List[string]
if (-not $client.publicClient) { $conflicts.Add('client is not public') }
if (-not $client.standardFlowEnabled) { $conflicts.Add('standard flow (authorization code) is disabled') }
if ($client.implicitFlowEnabled) { $conflicts.Add('implicit flow is enabled') }
if ($client.directAccessGrantsEnabled) { $conflicts.Add('direct access grants (password grant) are enabled') }
if ($client.attributes.'pkce.code.challenge.method' -ne 'S256') { $conflicts.Add('PKCE method is not S256') }
if ($conflicts.Count -gt 0) { Say 'CONFLICT: the client does not match the expected public PKCE client, nothing was changed:'; $conflicts | ForEach-Object { Say "  - $_" }; exit 4 }

$redirects = @($client.redirectUris)
$origins = @($client.webOrigins)
$logoutRaw = $client.attributes.'post.logout.redirect.uris'
$logout = if ($logoutRaw) { @($logoutRaw -split '##') } else { @() }
# "+" (the Keycloak default) or no value means: the redirect URIs apply to the logout as well, so adding the redirect URI is enough
$followsRedirects = ($logout.Count -eq 0) -or ($logout -contains '+')

Say "client '$ClientId' in realm '$Realm' (before):"
Say "  redirectUris:            $($redirects -join ', ')"
Say "  webOrigins:              $($origins -join ', ')"
Say "  post.logout.redirect.uris: $(if ($followsRedirects) { '(follows the redirect URIs)' } else { $logout -join ', ' })"

$newRedirects = @($redirects) + @(@($AddRedirect) | Where-Object { $redirects -notcontains $_ })
$newOrigins = @($origins) + @(@($AddOrigin) | Where-Object { $origins -notcontains $_ })
$newLogout = if ($followsRedirects) { $logout } else { @($logout) + @(@($AddLogout) | Where-Object { $logout -notcontains $_ }) }
$changes = ($newRedirects.Count -ne $redirects.Count) -or ($newOrigins.Count -ne $origins.Count) -or ($newLogout.Count -ne $logout.Count)
if (-not $changes) { Quit 0 'Already up to date: nothing to do.' }

Say "after (added only):"
Say "  redirectUris:            $($newRedirects -join ', ')"
Say "  webOrigins:              $($newOrigins -join ', ')"
Say "  post.logout.redirect.uris: $(if ($followsRedirects) { '(follows the redirect URIs)' } else { $newLogout -join ', ' })"
if ($DryRun) { Quit 0 'DRY RUN: nothing was written.' }

# ---------------------------------------------------------------- 4. write and verify
$client.redirectUris = $newRedirects
$client.webOrigins = $newOrigins
if ($null -eq $client.attributes) { $client | Add-Member -NotePropertyName attributes -NotePropertyValue ([pscustomobject] @{}) }
if (-not $followsRedirects) { $client.attributes | Add-Member -NotePropertyName 'post.logout.redirect.uris' -NotePropertyValue ($newLogout -join '##') -Force }
try {
    Admin-Call PUT "/admin/realms/$Realm/clients/$($client.id)" $client $token | Out-Null
    $after = (Admin-Call GET "/admin/realms/$Realm/clients/$($client.id)" $null $token).Content | ConvertFrom-Json
} catch { Quit 2 "ERROR while writing the client (re-run is safe): $($_.Exception.Message)" }
$ok = (@($after.redirectUris) -contains $AddRedirect) -and (@($after.webOrigins) -contains $AddOrigin) -and
      ($followsRedirects -or (($after.attributes.'post.logout.redirect.uris' -split '##') -contains $AddLogout)) -and
      ($redirects | Where-Object { @($after.redirectUris) -notcontains $_ }).Count -eq 0 -and
      ($origins | Where-Object { @($after.webOrigins) -notcontains $_ }).Count -eq 0
if (-not $ok) { Quit 2 'ERROR: verification after writing failed; inspect the client in the admin console' }
Quit 0 'DONE: the application URL was added to prodflow-web (nothing was removed).'
