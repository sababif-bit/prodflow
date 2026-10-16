<#
.SYNOPSIS
  Real Authorization Code + PKCE (S256) login check against Keycloak for the three ProdFlow demo users.

.DESCRIPTION
  Does what a browser does, step by step: authorization request -> Keycloak login form -> form POST -> redirect with
  code -> code exchange with code_verifier. No Direct Access Grants (password grant) is used.
  Reusable against any environment (local, disposable test instance, AWS).

  Security: passwords are read only from the process environment (DEMO_PLANNER_PASSWORD, DEMO_PURCHASER_PASSWORD,
  DEMO_ADMIN_PASSWORD), kept in memory and never printed. Tokens, cookies and redirect URLs (they contain the
  authorization code) are never printed or written to disk; only selected claim values and PASS/FAIL lines are.
  Exit code: 0 = all checks passed, 1 = at least one check failed, 2 = the script itself aborted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $KeycloakUrl,      # public base URL, e.g. http://localhost:8181 or https://auth.<name>.duckdns.org
    [string] $Realm = 'prodflow',
    [string] $ClientId = 'prodflow-swagger',
    [Parameter(Mandatory)] [string] $RedirectUri,      # a redirect URI registered for the client
    [int]    $ExpectedLifespan = 1800,                 # expected access token lifetime in seconds (exp - iat)
    [string[]] $Users = @('planner', 'purchaser', 'admin'),
    [switch] $SkipUserSwitching,
    [switch] $SkipPkceNegative
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

$KeycloakUrl = $KeycloakUrl.TrimEnd('/')
# Credentials are posted to Keycloak, so never over plain HTTP to a remote host (plain HTTP is only fine for localhost)
$kcUri = [uri] $KeycloakUrl
if (($kcUri.Scheme -ne 'https') -and (@('localhost', '127.0.0.1') -notcontains $kcUri.Host)) {
    Write-Host "ABORT: refusing to send credentials over plain HTTP to '$($kcUri.Host)'; use an https:// URL (http is only allowed for localhost)"
    exit 2
}
$AppRoles = @('ADMIN', 'PLANNER', 'PURCHASER')
$Demo = @{
    planner   = @{ Role = 'PLANNER';   PasswordVar = 'DEMO_PLANNER_PASSWORD' }
    purchaser = @{ Role = 'PURCHASER'; PasswordVar = 'DEMO_PURCHASER_PASSWORD' }
    admin     = @{ Role = 'ADMIN';     PasswordVar = 'DEMO_ADMIN_PASSWORD' }
}
$script:Failures = 0
$script:Passes = 0
$script:AppOrigin = ([uri] $RedirectUri).GetLeftPart([System.UriPartial]::Authority)

function Report([bool] $ok, [string] $label, [string] $detail = '') {
    if ($ok) { $script:Passes++ } else { $script:Failures++ }
    $text = '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label
    if ($detail) { $text += "  ($detail)" }
    Write-Host $text
}

function Get-Pw([string] $User) { [Environment]::GetEnvironmentVariable($Demo[$User].PasswordVar) }

# ---- HTTP (manual cookie jar: Keycloak sets Secure cookies, which .NET would not send back over http://localhost) ----
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromSeconds(30)

function Send([string] $Method, [string] $Url, [hashtable] $Jar, [hashtable] $Form, [hashtable] $Headers = $null) {
    if ($Url.StartsWith('/')) { $Url = $KeycloakUrl + $Url }
    $verb = if ($Method -eq 'POST') { [System.Net.Http.HttpMethod]::Post } else { [System.Net.Http.HttpMethod]::Get }
    $req = New-Object System.Net.Http.HttpRequestMessage($verb, $Url)
    if ($Headers) { foreach ($h in $Headers.Keys) { [void] $req.Headers.TryAddWithoutValidation($h, [string] $Headers[$h]) } }
    if ($Jar -and $Jar.Count -gt 0) {
        $cookie = ($Jar.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; '
        [void] $req.Headers.TryAddWithoutValidation('Cookie', $cookie)
    }
    if ($Form) {
        $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        foreach ($k in $Form.Keys) { $dict[$k] = [string] $Form[$k] }
        $req.Content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $dict)
    }
    $resp = $http.SendAsync($req).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($Jar) {
        $values = $null
        if ($resp.Headers.TryGetValues('Set-Cookie', [ref] $values)) {
            foreach ($c in $values) {
                $pair = ($c -split ';')[0]
                $eq = $pair.IndexOf('=')
                if ($eq -lt 1) { continue }
                $name = $pair.Substring(0, $eq).Trim()
                $val = $pair.Substring($eq + 1).Trim()
                if ($val -eq '' -or $c -match '(?i)max-age=0|expires=[^;]*1970') { $Jar.Remove($name) } else { $Jar[$name] = $val }
            }
        }
    }
    $location = ''
    if ($resp.Headers.Location) { $location = $resp.Headers.Location.OriginalString }
    $allowOrigin = ''
    $originValues = $null
    if ($resp.Headers.TryGetValues('Access-Control-Allow-Origin', [ref] $originValues)) { $allowOrigin = [string] ($originValues | Select-Object -First 1) }
    [pscustomobject] @{ Status = [int] $resp.StatusCode; Location = $location; Body = $body; AllowOrigin = $allowOrigin }
}

# Follows redirects, but only inside Keycloak; never to the application's redirect URI (it would receive the code)
function Follow-Redirects($Response, [hashtable] $Jar, [int] $Max = 6) {
    $r = $Response
    for ($i = 0; $i -lt $Max; $i++) {
        if (($r.Status -lt 300) -or ($r.Status -ge 400) -or -not $r.Location) { break }
        $url = if ($r.Location -match '^https?://') { $r.Location } else { $KeycloakUrl + $r.Location }
        if (-not $url.StartsWith($KeycloakUrl)) { break }
        $r = Send 'GET' $url $Jar $null
    }
    $r
}

# ---- PKCE / OAuth helpers ----
function New-Random([int] $Bytes) {
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-Pkce {
    $verifier = New-Random 32
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    @{ Verifier = $verifier; Challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
}

function Get-AuthUrl($Pkce, [string] $State, [bool] $PromptLogin, [bool] $WithChallenge = $true) {
    $q = @(
        ('client_id=' + [uri]::EscapeDataString($ClientId)),
        'response_type=code',
        ('redirect_uri=' + [uri]::EscapeDataString($RedirectUri)),
        ('state=' + $State)
    )
    if ($WithChallenge) { $q += 'code_challenge=' + $Pkce.Challenge; $q += 'code_challenge_method=S256' }
    if ($PromptLogin) { $q += 'prompt=login' }
    "$KeycloakUrl/realms/$Realm/protocol/openid-connect/auth?" + ($q -join '&')
}

function Get-FormIds([string] $Html) {
    $ids = [regex]::Matches($Html, '<form\b[^>]*\bid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    if ($ids) { ($ids -join ',') } else { 'none' }
}

# Keycloak's own error message (e.g. "Invalid parameter: redirect_uri"); contains no secrets
function Get-ErrorText([string] $Html) {
    $m = [regex]::Match($Html, 'kc-feedback-text[^>]*>([^<]+)<')
    if (-not $m.Success) { $m = [regex]::Match($Html, 'id="kc-error-message"[\s\S]*?<p[^>]*>([^<]+)<') }
    if (-not $m.Success) { return '' }
    $t = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
    $t.Substring(0, [Math]::Min(120, $t.Length))
}

# -Verbose only: page structure for troubleshooting (form ids, input names, link ids + paths). Never queries, values or tokens.
function Write-Structure([string] $Label, $Response) {
    $anchors = [regex]::Matches($Response.Body, '<a\b([^>]*)>') | ForEach-Object {
        $id = [regex]::Match($_.Groups[1].Value, '\bid="([^"]*)"').Groups[1].Value
        $href = [regex]::Match($_.Groups[1].Value, '\bhref="([^"]*)"').Groups[1].Value
        $path = ([System.Net.WebUtility]::HtmlDecode($href) -split '[?#]')[0] -replace '^https?://[^/]+', ''
        if ($id -or $path) { "id=$id path=$path" }
    }
    $inputs = [regex]::Matches($Response.Body, '<input\b[^>]*\bname="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $actions = [regex]::Matches($Response.Body, '<form\b[^>]*\baction="([^"]*)"') | ForEach-Object { ([System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) -split '[?#]')[0] -replace '^https?://[^/]+', '' }
    Write-Verbose ("{0}: HTTP {1}; forms={2}; form actions={3}; inputs={4}; links=[{5}]" -f $Label, $Response.Status, (Get-FormIds $Response.Body), ($actions -join ','), ($inputs -join ','), ($anchors -join ' | '))
}

function Get-LoginAction([string] $Html) {
    $tag = [regex]::Match($Html, '<form\b[^>]*\bid="kc-form-login"[^>]*>')
    if (-not $tag.Success) { return $null }
    $action = [regex]::Match($tag.Value, '\baction="([^"]*)"')
    if (-not $action.Success) { return $null }
    [System.Net.WebUtility]::HtmlDecode($action.Groups[1].Value)
}

function Test-UsernameField([string] $Html) { [bool]([regex]::IsMatch($Html, '<input\b[^>]*\bname="username"')) }

function Get-QueryValue([string] $Url, [string] $Name) {
    $q = $Url.Substring($Url.IndexOf('?') + 1)
    [System.Web.HttpUtility]::ParseQueryString($q)[$Name]
}

function Decode-Jwt([string] $Jwt) {
    $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

# One complete browser-style login (authorization request with prompt=login, like Swagger UI sends it).
function Invoke-PkceLogin([string] $User, [string] $Password, [hashtable] $Jar) {
    $pkce = New-Pkce
    $state = New-Random 16
    $r = Send 'GET' (Get-AuthUrl $pkce $state $true) $Jar $null
    if ($r.Status -ne 200) { return @{ Ok = $false; Why = "authorization endpoint answered HTTP $($r.Status) instead of the login page: $(Get-ErrorText $r.Body)" } }
    $action = Get-LoginAction $r.Body
    if (-not $action) { return @{ Ok = $false; Why = "no login form found (forms on page: $(Get-FormIds $r.Body))" } }

    $post = Send 'POST' $action $Jar @{ username = $User; password = $Password }
    if ($post.Status -ne 302) {
        return @{ Ok = $false; Why = "login did not complete: HTTP $($post.Status), forms on page: $(Get-FormIds $post.Body), message: $(Get-ErrorText $post.Body)" }
    }
    $target = ($post.Location -split '\?')[0]
    if ($target -ne $RedirectUri) {
        return @{ Ok = $false; Why = "login was redirected to an unexpected page: $(($target -replace '^https?://[^/]+', ''))" }
    }
    $err = Get-QueryValue $post.Location 'error'
    if ($err) { return @{ Ok = $false; Why = "authorization error: $err" } }
    if ((Get-QueryValue $post.Location 'state') -ne $state) { return @{ Ok = $false; Why = 'state parameter mismatch' } }
    $code = Get-QueryValue $post.Location 'code'
    if (-not $code) { return @{ Ok = $false; Why = 'redirect carried no authorization code' } }

    # Swagger UI calls the token endpoint from the browser (cross-origin), so the request carries the app's Origin header
    $tokenResp = Send 'POST' "$KeycloakUrl/realms/$Realm/protocol/openid-connect/token" $null @{
        grant_type = 'authorization_code'; client_id = $ClientId; code = $code; redirect_uri = $RedirectUri; code_verifier = $pkce.Verifier } @{ Origin = $script:AppOrigin }
    if ($tokenResp.Status -ne 200) {
        $e = ''
        try { $e = ($tokenResp.Body | ConvertFrom-Json).error } catch { }
        return @{ Ok = $false; Why = "token endpoint answered HTTP $($tokenResp.Status) $e" }
    }
    $claims = Decode-Jwt (($tokenResp.Body | ConvertFrom-Json).access_token)
    @{ Ok = $true; Claims = $claims; AllowOrigin = $tokenResp.AllowOrigin }
}

# Ends the Keycloak SSO session like the "Logout" page does; true when a prompt-less login request shows the login form again
function Invoke-KeycloakLogout([hashtable] $Jar) {
    $page = Send 'GET' "$KeycloakUrl/realms/$Realm/protocol/openid-connect/logout?client_id=$([uri]::EscapeDataString($ClientId))" $Jar $null
    $page = Follow-Redirects $page $Jar
    Write-Structure 'logout page' $page
    if ($page.Status -eq 200) {
        $form = [regex]::Match($page.Body, '<form\b[^>]*\baction="([^"]+)"')
        if ($form.Success) {
            $fields = @{ confirmLogout = 'Logout' }
            $code = [regex]::Match($page.Body, 'name="session_code"\s+value="([^"]*)"')
            if ($code.Success) { $fields['session_code'] = [System.Net.WebUtility]::HtmlDecode($code.Groups[1].Value) }
            $done = Send 'POST' ([System.Net.WebUtility]::HtmlDecode($form.Groups[1].Value)) $Jar $fields
            [void](Follow-Redirects $done $Jar)
        }
    }
    $probe = Send 'GET' (Get-AuthUrl (New-Pkce) (New-Random 16) $false) $Jar $null
    ($probe.Status -eq 200) -and [bool](Get-LoginAction $probe.Body)
}

function Test-Claims([string] $User, $Claims) {
    $expectedRole = $Demo[$User].Role
    Report ($Claims.preferred_username -eq $User) "$User token: preferred_username" "actual=$($Claims.preferred_username)"
    Report ($Claims.azp -eq $ClientId) "$User token: issued to client $ClientId" "azp=$($Claims.azp)"
    Report ($Claims.iss -eq "$KeycloakUrl/realms/$Realm") "$User token: issuer" "iss=$($Claims.iss)"
    Report (@($Claims.aud) -contains 'prodflow-api') "$User token: audience contains prodflow-api" "aud=$(@($Claims.aud) -join ',')"
    $roles = @()
    if ($Claims.PSObject.Properties['realm_access']) { $roles = @($Claims.realm_access.roles | Where-Object { $AppRoles -contains $_ }) }
    Report (($roles -join ',') -eq $expectedRole) "$User token: exactly application role $expectedRole" "roles=$($roles -join ',')"
    $life = [int] $Claims.exp - [int] $Claims.iat
    Report ($life -eq $ExpectedLifespan) "$User token: lifetime exp-iat = $ExpectedLifespan s" "actual=$life"
}

function Test-SwitchedToPurchaser([string] $Method, $Result) {
    Report $Result.Ok "switching ($Method): logs in as purchaser" $(if (-not $Result.Ok) { $Result.Why })
    if ($Result.Ok) {
        $r = @($Result.Claims.realm_access.roles | Where-Object { $AppRoles -contains $_ })
        Report (($Result.Claims.preferred_username -eq 'purchaser') -and (($r -join ',') -eq 'PURCHASER')) "switching ($Method): new token belongs to purchaser with only PURCHASER" "user=$($Result.Claims.preferred_username) roles=$($r -join ',')"
    }
}

function New-PlannerSession {
    $jar = @{}
    $login = Invoke-PkceLogin 'planner' (Get-Pw 'planner') $jar
    @{ Jar = $jar; Login = $login }
}

try {
    Write-Host "smoke-auth: realm=$Realm client=$ClientId keycloak=$KeycloakUrl"

    # 1) Real login per demo user, each with a fresh cookie jar
    foreach ($user in $Users) {
        $pw = Get-Pw $user
        if ([string]::IsNullOrEmpty($pw)) { Report $false "$user login" "environment variable $($Demo[$user].PasswordVar) is not set"; continue }
        $result = Invoke-PkceLogin $user $pw @{}
        Report $result.Ok "${user}: Authorization Code + PKCE login without interruption" $(if (-not $result.Ok) { $result.Why })
        if ($result.Ok) {
            Test-Claims $user $result.Claims
            Report ($result.AllowOrigin -eq $script:AppOrigin) "${user}: browser CORS - the token endpoint allows the app origin" "Access-Control-Allow-Origin=$($result.AllowOrigin)"
        }
        # Guard: when a password variable is unset at realm import, Keycloak 26.4 imports silently and stores the placeholder text
        # itself as the password (verified). That would be a publicly known password, so the literal text must be rejected.
        $literal = Invoke-PkceLogin $user ('${' + $Demo[$user].PasswordVar + '}') @{}
        Report (-not $literal.Ok) "${user}: the literal placeholder text is not accepted as a password" $(if ($literal.Ok) { 'SECURITY: variable was unset at realm import; Keycloak stored the placeholder text as the password' })
        $pw = $null
    }

    # 2) User switching. Verified empirically against Keycloak 26.4: with an active SSO session, prompt=login shows a
    #    re-authentication page (password only, username locked to the current user, no "restart login" link), so it can NOT
    #    be used to log in as a different user. Two methods work: B) log out of Keycloak first, C) a second/private window.
    if (-not $SkipUserSwitching -and ($Users -contains 'planner') -and ($Users -contains 'purchaser')) {
        $s = New-PlannerSession
        if (-not $s.Login.Ok) {
            Report $false 'switching: initial planner login' $s.Login.Why
        } else {
            $sso = Send 'GET' (Get-AuthUrl (New-Pkce) (New-Random 16) $false) $s.Jar $null
            Report (($sso.Status -eq 302) -and ($sso.Location -match '[?&]code=')) 'switching: without prompt=login the active SSO session logs in silently' "HTTP $($sso.Status)"
            $forced = Send 'GET' (Get-AuthUrl (New-Pkce) (New-Random 16) $true) $s.Jar $null
            Write-Structure 'prompt=login page with active SSO session' $forced
            $reauth = ($forced.Status -eq 200) -and [bool](Get-LoginAction $forced.Body)
            Report ($reauth -and -not (Test-UsernameField $forced.Body)) 'switching: prompt=login re-asks the password despite the active SSO session, but the username is locked (no user switch possible this way)' "re-authentication page, username field editable=$(Test-UsernameField $forced.Body)"
        }

        # Method B: log out of Keycloak, then authorize again
        $s = New-PlannerSession
        if ($s.Login.Ok) {
            $loggedOut = Invoke-KeycloakLogout $s.Jar
            Report $loggedOut 'switching (B): Keycloak logout ends the SSO session (login form is shown again)'
            if ($loggedOut) { Test-SwitchedToPurchaser 'B: Keycloak logout first' (Invoke-PkceLogin 'purchaser' (Get-Pw 'purchaser') $s.Jar) }
        } else { Report $false 'switching (B): planner session' $s.Login.Why }

        # Method C: second browser window (separate cookies); both sessions stay active independently
        $s = New-PlannerSession
        if ($s.Login.Ok) {
            Test-SwitchedToPurchaser 'C: second/private browser window' (Invoke-PkceLogin 'purchaser' (Get-Pw 'purchaser') @{})
            $still = Send 'GET' (Get-AuthUrl (New-Pkce) (New-Random 16) $false) $s.Jar $null
            Report (($still.Status -eq 302) -and ($still.Location -match '[?&]code=')) 'switching (C): the planner window keeps its own session' "HTTP $($still.Status)"
        } else { Report $false 'switching (C): planner session' $s.Login.Why }
    }

    # 3) PKCE is enforced: an authorization request without code_challenge must be rejected because of PKCE
    if (-not $SkipPkceNegative) {
        $r = Send 'GET' (Get-AuthUrl (New-Pkce) (New-Random 16) $true $false) @{} $null
        $errText = Get-ErrorText $r.Body
        $why = "HTTP $($r.Status)"
        if ($r.Location -match '[?&]error=([^&]+)') { $why += ", error=$($Matches[1])" }
        if ($errText) { $why += ", message=$errText" }
        # Only a rejection that is really about PKCE counts; a generic 400 (e.g. invalid redirect_uri) proves nothing
        $rejectedForPkce = (($r.Status -eq 302) -and ($r.Location -match '[?&]error=')) -or ($errText -match '(?i)code_challenge|pkce')
        Report $rejectedForPkce 'PKCE enforced: request without code_challenge is rejected because of PKCE' $why
    }
}
catch {
    Write-Host "ERROR  smoke-auth aborted: $($_.Exception.Message)"
    $http.Dispose()
    exit 2
}
finally {
    foreach ($v in 'pw', 's', 'result') { Remove-Variable -Name $v -ErrorAction SilentlyContinue }
}
$http.Dispose()
Write-Host ("smoke-auth result: {0} PASS, {1} FAIL" -f $script:Passes, $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
exit 0
