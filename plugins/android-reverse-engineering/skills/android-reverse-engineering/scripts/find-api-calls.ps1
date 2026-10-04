# Search Java/Kotlin source for network and authentication signals.
param(
    [Parameter(Position=0)][string]$SourceDir,
    [switch]$Retrofit, [switch]$OkHttp, [switch]$Ktor, [switch]$Apollo,
    [switch]$Volley, [switch]$Urls, [switch]$Paths, [switch]$Auth,
    [switch]$All, [Alias('h')][switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Host 'Usage: find-api-calls.ps1 SOURCE [-Retrofit|-OkHttp|-Ktor|-Apollo|-Volley|-Urls|-Paths|-Auth|-All]'
    Write-Host 'Default: all sections. Results are investigation candidates, not confirmed API ownership or credentials.'
    exit 0
}
if (-not $SourceDir -or -not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Write-Host 'Error: specify an existing source directory.' -ForegroundColor Red; exit 1
}
$searchAll = $All -or -not ($Retrofit -or $OkHttp -or $Ktor -or $Apollo -or $Volley -or $Urls -or $Paths -or $Auth)
$sourceFiles = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File | Where-Object { $_.Extension -in @('.java','.kt') })
function Write-Section { param([string]$Title) Write-Host "`n==== $Title ====`n" }
function Search-Sources {
    param([string]$Pattern)
    $sourceFiles | Select-String -Pattern $Pattern -CaseSensitive | ForEach-Object {
        "$($_.Path):$($_.LineNumber):$($_.Line.Trim())"
    }
}
if ($searchAll -or $Retrofit) {
    Write-Section 'Retrofit Annotations'
    Search-Sources '@(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|HTTP)\s*\('
    Write-Section 'Retrofit Headers & Parameters'
    Search-Sources '@(Headers|Header|Query|QueryMap|Path|Body|Field|FieldMap|Part|PartMap|Url)\s*\('
    Write-Section 'Retrofit Base URL'
    Search-Sources '(baseUrl|base_url)\s*\('
}
if ($searchAll -or $OkHttp) {
    Write-Section 'OkHttp Request Building'
    Search-Sources '(Request\.Builder|HttpUrl|\.newCall|\.enqueue|addInterceptor|addNetworkInterceptor)'
    Write-Section 'OkHttp URL Construction'
    Search-Sources '(\.url\s*\(|\.addQueryParameter|\.addPathSegment|\.scheme\s*\(|\.host\s*\()'
}
if ($searchAll -or $Ktor) {
    Write-Section 'Ktor Client Calls'
    Search-Sources '\b(client|httpClient|HttpClient)\.(get|post|put|delete|patch|head|request)\s*[<(]'
    Write-Section 'Ktor Request Building / Default Request'
    Search-Sources '(HttpRequestBuilder|defaultRequest\s*\{|\burl\s*\(\s*"|URLBuilder|URLProtocol)'
    Write-Section 'Ktor Auth Plugin'
    Search-Sources '(\bbearer\s*\{|BearerTokens\s*\(|loadTokens\s*\{|refreshTokens\s*\{|\bAuth\s*\)\s*\{)'
}
if ($searchAll -or $Apollo) {
    Write-Section 'Apollo GraphQL Client'
    Search-Sources '(ApolloClient|\.serverUrl\s*\(|\.subscriptionNetworkTransport|HttpNetworkTransport)'
    Write-Section 'Apollo Operations'
    Search-Sources '(\.query\s*\(\s*[A-Z]|\.mutation\s*\(\s*[A-Z]|\.subscription\s*\(\s*[A-Z])'
}
if ($searchAll -or $Volley) {
    Write-Section 'Volley Requests'
    Search-Sources '(StringRequest|JsonObjectRequest|JsonArrayRequest|ImageRequest|RequestQueue|Volley\.newRequestQueue)'
}
if ($searchAll -or $Paths) {
    $segment = '[A-Za-z0-9_{}.\-]+'
    $root = '(api|v[0-9]+|graphql|rest|mobile|auth|oauth|sso|users?|account|session|token|register|signup|signin|logout|password|verify|otp|sms|profile|customer|cart|basket|order|checkout|payment|invoice|product|catalog|inventory|search|category|favo[u]?rites?|wishlist|address|location|delivery|shipping|review|feedback|notification|push|message|chat|track|event|stat[a-z]*|metric|config|settings?|feature|flag|banner|content|media|upload|download|file|image|video|live|stream|webhook|callback)'
    $pathPattern = '"(/' + $segment + '(/' + $segment + ')+/?|' + $root + '(/' + $segment + ')+/?)"'
    $exclude = '^"(image|video|audio|text|application|content|font|model|multipart|message)/|^"/(proc|sys|dev|tmp|etc|usr|var|opt)/'
    $pathMatches = @($sourceFiles | Select-String -Pattern $pathPattern -AllMatches -CaseSensitive)
    Write-Section 'Endpoint-Shaped Path Literals (deduplicated)'
    $pathMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
        Where-Object { $_ -cnotmatch $exclude } | Sort-Object -Unique
    Write-Section 'Endpoint-Shaped Path Literals - call sites'
    $pathMatches | Where-Object {
        @($_.Matches | Where-Object { $_.Value -cnotmatch $exclude }).Count -gt 0
    } | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" }
}
if ($searchAll -or $Urls) {
    $urlPattern = 'https?://(([0-9]{1,3}(\.[0-9]{1,3}){3}|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})(:[0-9]{1,5})?(/[^"<>\s\x00-\x1f]*)?|[A-Za-z0-9-]+(:[0-9]{1,5}(/[^"<>\s\x00-\x1f]*)?|/[^"<>\s\x00-\x1f]*))'
    $urlValues = @($sourceFiles | Select-String -Pattern $urlPattern -AllMatches -CaseSensitive |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $denylist = Join-Path $PSScriptRoot '../references/third_party_hosts.txt'
    $denyPatterns = @()
    if (Test-Path -LiteralPath $denylist) {
        $denyPatterns = @(Get-Content -LiteralPath $denylist | Where-Object { $_ -notmatch '^\s*(#|$)' })
    }
    $urlRecords = @()
    foreach ($value in $urlValues) {
        $uri = $null
        if (-not [Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri)) { continue }
        $hostName = $uri.DnsSafeHost.ToLowerInvariant()
        # Match the Bash noise filter for bare two-label domain candidates.
        $rest = $value -replace '^https?://',''
        if ($rest -notmatch '[/:]' -and ($hostName -split '\.').Count -eq 2 -and
            $hostName -notmatch '\.(com|net|org|io|co|app|dev|me|ai|xyz|info|biz|gov|edu|mil|int|tech|cloud|uk|de|fr|it|es|nl|in|us|ca|au|jp|cn|br|ru|eu|ch|se|no|fi|dk|pl|pt|gr|ie|be|at|cz|sg|hk|kr|tw|mx|ar|cl|za|nz)$') { continue }
        $thirdParty = $false
        foreach ($denyPattern in $denyPatterns) {
            if ($hostName -match $denyPattern) { $thirdParty = $true; break }
        }
        $urlRecords += [pscustomobject]@{ HostName=$hostName; Url=$value; ThirdParty=$thirdParty }
    }
    Write-Section 'First-Party Host Candidates (counts of distinct URL strings; ownership unverified)'
    $urlRecords | Where-Object { -not $_.ThirdParty } | Group-Object HostName |
        Sort-Object Count -Descending | ForEach-Object { '{0,5}  {1}' -f $_.Count,$_.Name }
    Write-Section 'Third-Party Hosts (denylist matches)'
    $urlRecords | Where-Object { $_.ThirdParty } | Select-Object -ExpandProperty HostName | Sort-Object -Unique
    Write-Section 'First-Party URL Candidates'
    $urlRecords | Where-Object { -not $_.ThirdParty } | Select-Object -ExpandProperty Url | Sort-Object -Unique
    Write-Section 'HttpURLConnection'
    Search-Sources '(openConnection|setRequestMethod|HttpURLConnection|HttpsURLConnection)'
    Write-Section 'WebView URLs'
    Search-Sources '(loadUrl|loadData|evaluateJavascript|addJavascriptInterface|WebViewClient|WebChromeClient)'
}
if ($searchAll -or $Auth) {
    Write-Section 'Authentication & API Keys'
    Search-Sources '(?i)(api[_-]?key|auth[_-]?token|bearer|authorization|x-api-key|client[_-]?secret|access[_-]?token|refresh[_-]?token)'
    Write-Section 'Request Signing (HMAC / signature schemes)'
    Search-Sources '(HmacSHA(1|256|512)|Mac\.getInstance\("Hmac|SecretKeySpec\(|Signature\.getInstance\()'
    Search-Sources '(?i)(x-signature|x-client-authorization|x-amz-signature|x-hmac|aws4-hmac|signRequest|signatureFor|computeSignature|signaturev[0-9])'
    Write-Section 'Possible Hardcoded Secrets / Keys'
    Search-Sources '(?i)(app[_-]?secret|client[_-]?secret|signing[_-]?key|hmac[_-]?secret|consumer[_-]?secret|private[_-]?key)'
    Write-Section 'Base URLs and Constants'
    Search-Sources '(?i)(BASE_URL|API_URL|SERVER_URL|ENDPOINT|API_BASE|HOST_NAME)'
    Write-Section 'Ktor Auth (Bearer + Refresh)'
    Search-Sources '(BearerTokens|loadTokens\s*\{|refreshTokens\s*\{|\bbearer\s*\{)'
}
Write-Host "`n=== Search complete ==="
