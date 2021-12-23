Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Test-Hash {
    param (
        [Parameter(Mandatory)]
        [String] $Manifest,
        [Int] $IssueID,
        $Gci,
        $Object
    )

    $outputH = @(shovel utils 'checkhashes' $Gci.FullName --additional-options -Force *>&1)
    $ex = $LASTEXITCODE
    Write-Log 'Output' $outputH

    if (($ex -eq 0) -and ($outputH[-2] -like 'OK') -and ($outputH[-1] -like 'Writing*')) {
        Write-Log 'Cannot reproduce'

        Add-Comment -ID $IssueID -Message @(
            'Cannot reproduce'
            ''
            'Are you sure your scoop is up to date? Clean cache and reinstall'
            "Please run ``shovel update; shovel cache rm $Manifest;`` and update/reinstall application"
            ''
            'Hash mismatch could be caused by these factors:'
            ''
            '- Network error'
            '- Antivirus configuration'
            '- Blocked site (Great Firewall of China, Corporate restrictions, ...)'
        )
        Remove-Label -ID $IssueID -Label 'hash-fix-needed'
        Close-Issue -ID $IssueID
    } elseif ($outputH[-1] -notlike 'Writing*') {
        # There is some error
        Write-Log 'Automatic check of hashes encounter some problems.'

        Add-Label -Id $IssueID -Label 'manifest-fix-needed'
    } else {
        Write-Log 'Verified hash failed'

        $repoInfo = (Invoke-GithubRequest "repos/$REPOSITORY").Content | ConvertFrom-Json
        $masterBranch = $repoInfo.default_branch
        $message = @('You are right. Thank you for reporting.')
        # TODO: Post labels at the end of function
        Add-Label -ID $IssueID -Label 'verified', 'hash-fix-needed'
        $prs = (Invoke-GithubRequest "repos/$REPOSITORY/pulls?state=open&base=$masterBranch&sorting=updated").Content | ConvertFrom-Json
        $titleToBePosted = "$Manifest@$($Object.version): Fix hash"
        $prs = $prs | Where-Object { $_.title -eq $titleToBePosted }

        # There is alreay PR for
        if ($prs.Count -gt 0) {
            Write-Log 'PR - Update description'

            # Only take latest updated
            $pr = $prs | Select-Object -First 1
            $prID = $pr.number
            # TODO: Additional checks if this PR is really fixing same issue

            $message += ''
            $message += "There is already pull request which take care of this issue. (#$prID)"

            Write-Log 'PR ID' $prID
            # Update PR description
            Invoke-GithubRequest "repos/$REPOSITORY/pulls/$prID" -Method Patch -Body @{ 'body' = (@("- Closes #$IssueID", $pr.body) -join "`r`n") }
            Add-Label -ID $IssueID -Label 'duplicate'
            #TODO: Try to post 'Duplicate of #OriginalIssueID'
        } else {
            Write-Log 'PR - Create new branch and post PR'

            $branch = "$Manifest-hash-fix-$(Get-Random -Maximum 258258258)"

            Write-Log 'Branch' $branch

            git checkout -B $branch
            # TODO: There is some problem

            Write-Log 'Git Status' @(git status --porcelain)

            git add $Gci.FullName
            git commit -m $titleToBePosted
            git push 'origin' $branch

            # Create new PR
            Invoke-GithubRequest -Query "repos/$REPOSITORY/pulls" -Method Post -Body @{
                'title' = $titleToBePosted
                'base'  = $masterBranch
                'head'  = $branch
                'body'  = "- Closes #$IssueID"
            }
        }
        Add-Comment -ID $IssueID -Message $message
    }
}

function Test-Downloading {
    param([String] $Manifest, [Int] $IssueID, $Gci, $Object)

    $Gci | Out-Null
    $broken_urls = @()
    # TODO: Adopt shovel download $Gci.FullName
    # TODO:? Aria2 support
    # dl_with_cache_aria2 $Manifest 'DL' $object (default_architecture) "/" $object.cookies $true

    foreach ($arch in @('64bit', '32bit', 'arm64')) {
        $urls = @(url $Object $arch)

        foreach ($url in $urls) {
            # Trim rename (#48)
            $url = $url -replace '#/.*$', ''
            Write-Log 'url' $url

            try {
                dl_with_cache $Manifest 'DL' $url $null $Object.cookies $true
            } catch {
                $broken_urls += $url
                continue
            }
        }
    }

    if ($broken_urls.Count -eq 0) {
        Write-Log 'All OK'

        $message = @(
            'Cannot reproduce.'
            ''
            'All files could be downloaded without any issue.'
            'Problems with download could be caused by:'
            ''
            '- Network error'
            '- Blocked site (Great Firewall of China, Corporate restrictions, ...)'
            '- Antivirus settings blocking URL/downloaded file'
            '- Proxy configuration'
        )

        Add-Comment -ID $IssueID -Comment $message
        # TODO: Close??
    } else {
        Write-Log 'Broken URLS' $broken_urls

        $string = ($broken_urls | Select-Object -Unique | ForEach-Object { "- $_" }) -join "`r`n"
        Add-Label -ID $IssueID -Label 'manifest-fix-needed', 'verified', 'help wanted'
        Add-Comment -ID $IssueID -Comment 'Thank you for reporting. You are right.', '', 'Following URLs are not accessible:', '', $string
    }
}

function Initialize-Issue {
    Write-Log 'Issue initialized'

    if (-not (($GH_EVENT.action -eq 'opened') -or ($GH_EVENT.action -eq 'labeled'))) {
        Write-Log "Only actions 'opened' and 'labeled' are supported"
        return
    }

    $title = $GH_EVENT.issue.title
    $id = $GH_EVENT.issue.number
    $label = $GH_EVENT.issue.labels.name

    # Only labeled action with verify label should continue
    if (($GH_EVENT.action -eq 'labeled') -and ($label -notcontains 'verify')) {
        Write-Log 'Labeled action contains wrong label'
        return
    }

    $gci, $manifest_loaded, $gciArchived = $manifestArchived = $null
    $problematicName, $problematicVersion, $problem = Resolve-IssueTitle $title
    if (($null -eq $problematicName) -or
        ($null -eq $problematicVersion) -or
        ($null -eq $problem)
    ) {
        Write-Log 'Not compatible issue title'
        return
    }

    try {
        $gci, $manifest_loaded = Get-Manifest $problematicName
    } catch {
        Add-Comment -ID $id -Message "The specified manifest ``$problematicName`` does not exist in this bucket. Make sure you opened the issue in the correct bucket."
        Add-Label -Id $id -Label 'invalid'
        Remove-Label -Id $id -Label 'verify'
        Close-Issue -ID $id
        return
    }

    if ($manifest_loaded.version -ne $problematicVersion) {
        $comment = @(
            "You reported version ``$problematicVersion``, but the latest available version is ``$($manifest_loaded.version)``. Make sure you opened the issue in the correct bucket."
            ''
            "Run ``scoop update; scoop update $problematicName --force``"
        )

        try {
            Write-Log "Looking for archived version ($problematicName $problematicVersion)"
            $gciArchived, $manifestArchived = Get-ManifestSpecificVersion $problematicName $problematicVersion
        } catch {
            Write-Log 'Cannot find archived version: ' $_.Exception.Message
            $comment = @(
                "Your reported version ``$problematicVersion`` is not available in this bucket. Make sure you opened the issue in the correct bucket."
                ''
                'If you have specific need to have this exact version, please leave a comment on this issue with the said reason.'
            )
        }

        Add-Comment -ID $id -Message $comment
        Close-Issue -ID $id
        Remove-Label -Id $id -Label 'verify'
        return
    }

    $splat = @{
        'Manifest' = $gci.BaseName
        'IssueID'  = $id
        'Gci'      = $gci
        'Object'   = $manifest_loaded
    }
    if ($manifestArchived -and $gciArchived) {
        $splat.Gci = $gciArchived
        $splat.Object = $manifestArchived
    }

    switch -Wildcard ($problem) {
        '*hash check*' {
            Write-Log 'Hash check failed'
            Test-Hash @splat
        }
        '*extract_dir*' {
            Write-Log 'Extract dir error'
            # TODO: Implement
            # Test-ExtractDir @splat
        }
        '*download*failed*' {
            Write-Log 'Download failed'
            Test-Downloading @splat
        }
        default { Write-Log 'Not supported issue action' }
    }

    Remove-Label -ID $id -Label 'verify'
    Write-Log 'Issue finished'
}

Export-ModuleMember -Function Initialize-Issue
