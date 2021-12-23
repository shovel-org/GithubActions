Join-Path $PSScriptRoot 'Variables.psm1' | Import-Module

function Write-ActionLog {
    <#
    .SYNOPSIS
        Persist message in docker log. For debug mainly. Write-Host is more suitable because then Write-ActionLog is not interfering with pipes.
    .PARAMETER Summary
        Header of log.
    .PARAMETER Message
        Array of objects to be saved into docker log.
    #>
    param(
        [String] $Summary = '',
        [Parameter(ValueFromPipeline)]
        [Object[]] $Message,
        [Switch] $Info,
        [Switch] $Err,
        [Switch] $Warning,
        [Switch] $Success
    )

    process {
        $color = 'White'
        if ($Info) { $color = 'DarkGray' }
        if ($Err) { $color = 'DarkRed' }
        if ($Warning) { $color = 'DarkYellow' }
        if ($Success) { $color = 'Green' }

        $splat = @{ 'ForegroundColor' = $color }

        # If it is only summary it is informative log
        if ($Summary -and ($null -eq $Message)) {
            Write-Host "INFO: $Summary" @splat
        } elseif (($Message.Count -eq 1) -and ($Message[0] -isnot [Hashtable])) {
            # Simple non hashtable object and summary should be one liner
            Write-Host "${Summary}: $Message" @splat
        } else {
            # Detailed output using format table
            Write-Host "Log of ${Summary}:" @splat
            $mess = ($Message | Format-Table -HideTableHeaders -AutoSize | Out-String).Trim() -split "`r`n"
            Write-Host ($mess | ForEach-Object { "`n    $_" }) @splat
        }

        Write-Host '' @splat
    }
}

function Get-EnvironmentVariable {
    <#
    .SYNOPSIS
        List all environment variables. Mainly debug purpose.
        Do not leak GITHUB_TOKEN, ACTION_* and SSH_KEY.
    #>
    return Get-ChildItem env: | Where-Object { (($_.Name -ne 'GITHUB_TOKEN') -and ($_.Name -notlike 'ACTIONS_*')) -and ($_.Name -ne 'SSH_KEY') }
}

function New-Array {
    <#
    .SYNOPSIS
        Create new Array list. More suitable for usage as it provides better operations.
    #>

    return New-Object System.Collections.ArrayList
}

function Add-IntoArray {
    <#
    .SYNOPSIS
        Append list with given item.
    .PARAMETER List
        List to be expanded.
    .PARAMETER Item
        Item to be added into list.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList] $List,
        [System.Object] $Item
    )

    $List.Add($Item) | Out-Null
}

function Expand-Property {
    <#
    .SYNOPSIS
        Shortcut for expanding property of object.
    .PARAMETER Object
        Base object.
    .PARAMETER Property
        Property to be expanded.
        TODO: Rework and support nested properties
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Object] $Object,
        [Parameter(Mandatory)]
        [String] $Property
    )

    process { return $Object | Select-Object -ExpandProperty $Property }
}

function Initialize-NeededConfiguration {
    <#
    .SYNOPSIS
        Initialize all settings, environment, configurations to work as expected.
    #>

    shovel update
    shovel --version
    git --version

    @('cache', 'buckets', 'modules', 'persist', 'shims', 'workspace') | ForEach-Object { New-Item (Join-Path $env:SCOOP $_) -Force -ItemType 'Directory' | Out-Null }

    $user = ($env:GITHUB_REPOSITORY -split '/')[0]
    $email = if ($env:GITH_EMAIL) { $env:GITH_EMAIL } else { $DEFAULT_EMAIL }
    $rem = "https://${env:GITHUB_ACTOR}:$env:GITHUB_TOKEN@github.com/$env:GITHUB_REPOSITORY.git"

    git config --global 'user.name' $user
    git config --global 'user.email' $email
    git remote 'set-url' --push 'origin' $rem

    shovel config '7ZIPEXTRACT_USE_EXTERNAL' $true
    shovel install 'hub' -g
    if (-not $env:HUB_VERBOSE) {
        $env:HUB_VERBOSE = '1'
        [System.Environment]::SetEnvironmentVariable('HUB_VERBOSE', $env:HUB_VERBOSE, 'Machine')
    }

    # Log all environment variables
    Write-ActionLog 'Environment' (Get-EnvironmentVariable)
}

function Get-Manifest {
    <#
    .SYNOPSIS
        Parse manifest and return it's path and object representation.
    .PARAMETER Name
        Name of manifest to parse.
    #>
    param([Parameter(Mandatory)][String] $Name)

    # It should alwyas be one item. Just in case use -First
    $gciItem = Get-ChildItem $MANIFESTS_LOCATION "$Name.*" | Select-Object -First 1
    # TODO: Consider better approach?
    $manifest = shovel cat $gciItem.Fullname --format json | ConvertFrom-Json

    return $gciItem, $manifest
}

function Get-ManifestSpecificVersion {
    <#
    .SYNOPSIS
        Parse manifest and return it's path and object representation.
    .PARAMETER Name
        Name of manifest to parse.
    #>
    param([Parameter(Mandatory)][String] $Name, $Version)

    # It should alwyas be one item. Just in case use -First
    $gciItem = Join-Path $MANIFESTS_LOCATION "old\$Name" | Get-ChildItem -Filter "$Version.*" -File | Select-Object -First 1
    # TODO: Consider better approach?
    $manifest = shovel cat $gciItem.Fullname --format json | ConvertFrom-Json

    Write-ActionLog "Found '$($gciItem.Fullname)' for $Name ($Version)"

    return $gciItem, $manifest
}

function New-DetailsCommentString {
    <#
    .SYNOPSIS
        Create code fenced block surrounded with <details>.
    .PARAMETER Summary
        Text of expand button.
    .PARAMETER Content
        Content of code fenced block.
    .PARAMETER Type
        Type of code fenced block (json, yml, ...).
        Needs to be valid markdown code fenced block type.
    #>
    param([Parameter(Mandatory)][String] $Summary, [String[]] $Content, [String] $Type = 'text')

    return @"
<details>
<summary>$Summary</summary>

``````$Type
$($Content -join "`r`n")
``````
</details>
"@
}

function New-CheckListItem {
    <#
    .SYNOPSIS
        Create markdown check list item.
    .PARAMETER Item
        Name of list item.
    .PARAMETER OK
        Item will be marked as done.
    .PARAMETER IndentLevel
        Indentation level of item. Used for nested lists.
    .PARAMETER Simple
        Simple list item will be used instead of check list.
    #>
    param ([Parameter(Mandatory)][String] $Item, [Int] $IndentLevel = 0, [Switch] $OK, [Switch] $Simple)

    $ind = ' ' * 4 * $IndentLevel
    $char = if ($OK) { 'x' } else { ' ' }
    $check = if ($Simple) { '' } else { "[$char] " }

    return "$ind- $check$Item"
}

function New-CheckList {
    <#
    .SYNOPSIS
        Create checklist.
    .PARAMETER Status
        Hashtable/PSCustomObject with name of check as key and boolean (or other pscustomobject) as value.
    #>
    param($Status)

    [PSCustomObject] $result = @() # Array of objects
    $final = @() # Final array of evaluated check lists

    function _res ($name, $indentation, $state) {
        return [PsCustomObject] [Ordered] @{
            'Item'   = $name
            'Indent' = $indentation
            'State'  = $state
        }
    }

    foreach ($name in $Status.Keys) {
        $item = $Status.Item($name)
        $ind = 0
        $parentState = $true

        if ($item -is [boolean]) {
            $result += _res $name $ind $item
        } else {
            $result += _res $name $ind $null
            foreach ($k in $item.Keys) {
                $nestedState = $item.Item($k)
                if ($nestedState -eq $false) { $parentState = $false }
                $result += _res $k ($ind + 1) $nestedState
            }
            ($result | Where-Object { ($_.Item -eq $name) -and ($null -eq $_.State) }).State = $parentState
        }
    }

    foreach ($res in $result) {
        Write-ActionLog $res.Item $res.State
        if ($res.State -eq $false) { $env:NON_ZERO_EXIT = $true }
        $final += New-CheckListItem -Item $res.Item -IndentLevel $res.Indent -OK:$res.State
    }

    return $final
}

function Test-NestedBucket {
    <#
    .SYNOPSIS
        Test if bucket contains nested `bucket` folder.
        Buckets should contain nested folder for many reasons and in Actions main reason is to keep location checks low.
        Open new issue and exit with non zero exit code otherwise.
    #>

    if (Test-Path $MANIFESTS_LOCATION) {
        Write-ActionLog 'Bucket contains nested bucket folder'
    } else {
        Write-ActionLog 'Buckets without nested bucket folder are not supported.'

        $adopt = 'Adopt nested bucket structure'
        # Get opened issues
        $req = Invoke-GithubRequest "repos/$REPOSITORY/issues?state=open"
        # Filter issues with $adopt name
        $issues = ConvertFrom-Json $req.Content | Where-Object { $_.title -eq $adopt }

        if ($issues -and ($issues.Count -gt 0)) {
            Write-ActionLog 'Issue already exists'
        } else {
            New-Issue -Title $adopt -Body @(
                'Buckets without nested `bucket` folder are not supported. You will not be able to use actions without it.',
                '',
                'See <https://github.com/shovel-org/GenericBucket> for the most optimal bucket structure.'
            )
        }

        exit $NON_ZERO
    }
}

function Resolve-IssueTitle {
    <#
    .SYNOPSIS
        Parse issue title and return manifest name, version and problem.
    .PARAMETER Title
        Title to be parsed.
    .EXAMPLE
        Resolve-IssueTitle 'recuva@2.4: hash check failed'
    #>
    param([Parameter(Mandatory)][String] $Title)

    # https://regex101.com/r/a69Ie4/1
    $result = $Title -match '(?<name>.+)@(?<version>.+?):\s*(?<problem>.*)$'

    if ($result) {
        return $Matches.name, $Matches.version, $Matches.problem
    } else {
        return $null, $null, $null
    }
}

Export-ModuleMember -Function Write-ActionLog, Get-EnvironmentVariables, New-Array, Add-IntoArray, Initialize-NeededConfiguration, `
    Expand-Property, Get-Manifest, Get-ManifestSpecificVersion, New-DetailsCommentString, New-CheckListItem, Test-NestedBucket, `
    Resolve-IssueTitle, New-CheckList
