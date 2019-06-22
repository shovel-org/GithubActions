# TODO: Remove and make it automatically
param (
    [Parameter(Mandatory)]
    [ValidateSet('Issue', 'PR', 'Push', '__TESTS__', 'Scheduled')]
    [String] $Type
)

#region Function pool
function Resolve-IssueTitle {
    <#
    .SYNOPSIS
        Parse issue title and return manifest name, version and problem.
    .PARAMETER Title
        Title to be parsed.
    .EXAMPLE
        Resolve-IssueTitle 'recuva@2.4: hash check failed'
    #>
    param([String] $Title)

    $result = $Title -match '(?<name>.+)@(?<version>.+):\s*(?<problem>.*)$'

    if ($result) {
        return $Matches.name, $Matches.version, $Matches.problem
    } else {
        return $null, $null, $null
    }
}

function Write-Log {
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    param ([String[]] $Message)

    Write-Output ''
    $Message | ForEach-Object { Write-Output "LOG: $_" }
}

function New-CheckListItem {
    param ([String] $Check, [Switch] $OK)

    if ($OK) {
        return "- [x] $Check"
    } else {
        return "- [ ] $Check"
    }
}

function Invoke-GithubRequest {
    <#
    .SYNOPSIS
        Invoke authenticated github API request.
    .PARAMETER Query
        Query to be executed
    .PARAMETER Method
        Method to be used with request
    .PARAMETER Body
        Additional body to be send.
    #>
    param(
        [Parameter(Mandatory)]
        [String] $Query,
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = 'Get',
        [Hashtable] $Body
    )

    $api_base_url = 'https://api.github.com'
    $headers = @{
        # Authorization token is neeeded for posting comments and to increase limit of requests
        'Authorization' = "token $env:GITHUB_TOKEN"
    }

    $parameters = @{
        'Headers' = $headers
        'Method'  = $Method
        'Uri'     = "$api_base_url/$Query"
    }
    if ($Body) { $parameters.Add('Body', (ConvertTo-Json $Body -Depth 8 -Compress)) }

    return Invoke-WebRequest @parameters
}

# ⬆⬆⬆⬆⬆⬆⬆⬆ OK ⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆








function Add-Comment {
    <#
    .SYNOPSIS
        Add comment into specific issue / PR
    #>
    param([Int] $ID, [String[]] $Message)

    return Invoke-WebRequest -Headers $HEADER -Body (ConvertTo-Json $BODY -Depth 8 -Compress) -Method Post "$API_BASE_URl/repos/Ash258/GithubActionsBucketForTesting/issues/5/comments"
}

function Add-Label {
    param([Ing] $ID, [String[]] $Labels)

    foreach ($label in $Labels) { Write-Log $label }
}

# TODO: Rename?
function Initialize-Issue {
    Write-Log 'Issue initialized'
    # TODO: Test listing of /github/workspace ...

    # Only continue if new issue is created
    if ($EVENT.action -ne 'opened') {
        Write-Log 'Every issues action except ''opened'' are ignored.'
        exit 0
    }
    $envs = [Environment]::GetEnvironmentVariables().Keys
    $table = @()
    $table += '| Name | Value |'
    $table += '| :--- | :--- |'
    $envs | ForEach-Object {
        $table += "| $_ | $([Environment]::GetEnvironmentVariable($_))|"
    }

    $table = $table -join "`r`n"
    Write-Output $table

    # Invoke-WebRequest -Headers $HEADER -Body (ConvertTo-Json $BODY -Depth 8 -Compress) -Method Post "$API_BASE_URl/repos/Ash258/GithubActionsBucketForTesting/issues/5/comments"
}

function Initialize-PR {
    Write-Log 'PR initialized'

    # TODO: Get all changed files in PR
    # Since binaries do not return any data on success flow needs to be this:
    # Run check with force param
    # if error, then just
    # git status, if changed
    # run checkver
    # run checkhashes
    # run formatjson?

    # TODO: Bucket
    # & "$env:SCOOP_HOME\bin\check<>.ps1" "-App $name -Dir $BUCKET_ROOT -Force"
    $status = if ($LASTEXITCODE -eq 0) { 'x' } else { ' ' }

    $body = @{
        'body' = (@(
                "- Properties",
                "    - [$status] Description",
                "    - [$status] License",
                "- [$status] Checkver functional",
                "- [$status] Autoupdate working",
                "- [$status] Hashes are correct",
                "- [$status] Manifest is formatted"
            ) -join "`r`n")
    }

    Write-Log $body.body
}

function Initialize-Push {
    Write-Log 'Push initialized'
}

function Initialize-Scheduled {
    Write-Log 'Scheduled initialized'

    $bodyS = @{
        'body' = (@("Scheduled comment each hour - $(Get-Date)", 'WORKSPACE', "$(Get-ChildItem $env:GITHUB_WORKSPACE)") -join "`r`n")
    }

    Invoke-WebRequest -Headers $HEADER -Body (ConvertTo-Json $bodyS) -Method Post "$API_BASE_URl/repos/$REPOSITORY/issues/7/comments"
}
#endregion Function pool

#region Main
# For dot sourcing whole file inside tests
if ($Type -eq '__TESTS__') { return }

# Convert actual API response to object
$global:EVENT = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
# Event type for automatic handler detection
$global:EVENT_TYPE = $env:GITHUB_EVENT_NAME
# user/repo format
$global:REPOSITORY = $env:GITHUB_REPOSITORY
# Location of bucket
$global:BUCKET_ROOT = $env:GITHUB_WORKSPACE

# Backward compatability for manifests inside root of repository
$nestedBucket = Join-Path $BUCKET_ROOT 'bucket'
$global:MANIFESTS_LOCATION = if (Test-Path $nestedBucket) { $nestedBucket } else { $BUCKET_ROOT }

Write-Host $env:SCOOP_HOME -ForegroundColor DarkBlue
Write-Host $env:GITHUB_EVENT_NAME -ForegroundColor DarkRed
Write-Host $MANIFESTS_LOCATION -ForegroundColor DarkBlue

switch ($Type) {
    'Issue' { Initialize-Issue }
    'PR' { Initialize-PR }
    'Push' { Initialize-Push }
    'Scheduled' { Initialize-Scheduled }
}

# switch ($EVENT_TYPE) {
# 	'issues' { Initialize-Issue }
# 	'pull_requests' { Initialize-PR }
# 	'push' { Initialize-Push }
# 	'schedule' { Initialize-Scheduled }
# }
#endregion Main
