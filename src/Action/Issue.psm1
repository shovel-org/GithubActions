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
    Write-ActionLog 'Output' $outputH

    if (($ex -eq 0) -and ($outputH[-2] -like 'OK') -and ($outputH[-1] -like 'Writing*')) {
        Write-ActionLog 'Cannot reproduce' -Err

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
        Write-ActionLog 'Automatic check of hashes encounter some problems.' -Err

        Add-Label -Id $IssueID -Label 'manifest-fix-needed'
    } else {
        Write-ActionLog 'Verified hash failed' -Success

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
            Write-ActionLog 'PR - Update description' -Success

            # Only take latest updated
            $pr = $prs | Select-Object -First 1
            $prID = $pr.number
            # TODO: Additional checks if this PR is really fixing same issue

            $message += ''
            $message += "There is already pull request which take care of this issue. (#$prID)"

            Write-ActionLog 'PR ID' $prID
            # Update PR description
            Invoke-GithubRequest "repos/$REPOSITORY/pulls/$prID" -Method Patch -Body @{ 'body' = (@("- Closes #$IssueID", $pr.body) -join "`r`n") }
            Add-Label -ID $IssueID -Label 'duplicate'
            #TODO: Try to post 'Duplicate of #OriginalIssueID'
        } else {
            Write-ActionLog 'PR - Create new branch and post PR' -Success

            $branch = "$Manifest-hash-fix-$(Get-Random -Maximum 258258258)"

            Write-ActionLog 'Branch' $branch

            git checkout -B $branch
            # TODO: There is some problem

            Write-ActionLog 'Git Status' @(git status --porcelain)

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
    param([String] $Manifest, [Int] $IssueID, $Gci, $Object, [String] $Utility)

    $broken_urls = @()
    $origParams = $params = @('download', $Gci.Fullname, '--all-architectures')
    if ($Utility) { $params += @('--utility', $Utility) }

    Write-ActionLog 'Download command parameters' ($params -join ' ')

    $outputSHvanilla = @()
    $outputSH = @(shovel @params *>&1)
    $failedCount = $LASTEXITCODE

    # Download it using native utility
    if (($failedCount -ne 0) -and $Utility) {
        $outputSHvanilla = @(shovel @origParams *>&1)
        $failedCount = $LASTEXITCODE
    }

    # Try to get the failed URLs
    if ($failedCount -ne 0) {
        foreach ($arch in @('64bit', '32bit', 'arm64')) {
            $urls = @(Get-ArchitectureSpecificProperty 'url' $Object $arch)

            foreach ($url in $urls) {
                # Trim rename (#48)
                $url = $url -replace '#/.*$', ''

                try {
                    Invoke-WebRequest -Uri $url -Method 'Head'
                } catch {
                    $broken_urls += $url
                    Write-ActionLog "$url -> $($_.Exception.Message)"
                    continue
                }
            }
        }
    }

    if (($broken_urls.Count -eq 0) -and ($failedCount -eq 0)) {
        Write-ActionLog 'All OK' -Success

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
        Write-ActionLog 'Broken URLS' $broken_urls -Warning

        $comm = @('Thank you for reporting. You are right.')
        if ($broken_urls.Count -gt 0) {
            $string = ($broken_urls | Select-Object -Unique | ForEach-Object { "- $_" }) -join "`r`n"
            $comm += @('', 'Following URLs are not accessible:', '', $string)
        } else {
            $code = New-DetailsCommentString -Summary 'Command output' -Content $outputSH
            $comm += @('', $code)
        }

        Write-ActionLog 'Download output' ($outputSH -join "`r`n")
        if ($outputSHvanilla) { Write-ActionLog 'Download output (no utility)' ($outputSH -join "`r`n") }

        Add-Label -ID $IssueID -Label 'manifest-fix-needed', 'verified', 'help wanted'
        Add-Comment -ID $IssueID -Comment $comm

        # TODO: Check for opened PRs with `^$Gci.Basename@$Manifest.version` or `^$Gci.Basenanem: Update`
    }
}

function Initialize-Issue {
    Write-ActionLog 'Issue initialized' -Success

    if ($GH_EVENT.action -notin @('opened', 'labeled')) {
        Write-ActionLog "Only actions 'opened' and 'labeled' are supported" -Err
        return
    }

    $title = $GH_EVENT.issue.title
    $id = $GH_EVENT.issue.number
    $label = $GH_EVENT.issue.labels.name

    # Only labeled action with verify label should continue
    if (($GH_EVENT.action -eq 'labeled') -and ($label -notcontains 'verify')) {
        Write-ActionLog 'Labeled action contains wrong label' -Err
        return
    }

    $gci, $manifest_loaded, $gciArchived = $manifestArchived = $null
    $problematicName, $problematicVersion, $problem = Resolve-IssueTitle $title
    if (($null -eq $problematicName) -or
        ($null -eq $problematicVersion) -or
        ($null -eq $problem)
    ) {
        Write-ActionLog 'Not compatible issue title' -Err
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
            Write-ActionLog "Looking for archived version ($problematicName $problematicVersion)" -Warning
            $gciArchived, $manifestArchived = Get-ManifestSpecificVersion $problematicName $problematicVersion
        } catch {
            Write-ActionLog 'Cannot find archived version: ' $_.Exception.Message -Err
            $comment = @(
                "Your reported version ``$problematicVersion`` is not available in this bucket. Make sure you opened the issue in the correct bucket."
                ''
                'If you have specific need to have this exact version, please leave a comment on this issue with the said reason.'
            )

            Add-Comment -ID $id -Message $comment
            Close-Issue -ID $id
            Remove-Label -Id $id -Label 'verify'
            return
        }
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
            Write-ActionLog 'Hash check failed' -Success
            Test-Hash @splat
        }
        '*extract_dir*' {
            Write-ActionLog 'Extract dir error' -Success
            # TODO: Implement
            # Test-ExtractDir @splat
        }
        '*download*failed*' {
            Write-ActionLog 'Download failed' -Success
            if ($problem -like '*via*') {
                $util = $problem -replace '.*via\s+(\w+)\s+.*', '$1'
                # Only supported utilities
                if ($util -in @('aria2')) {
                    $splat.Utility = $util
                }
            }

            Test-Downloading @splat
        }
        default { Write-ActionLog 'Not supported issue action' -Err }
    }

    Remove-Label -ID $id -Label 'verify'
    Write-ActionLog 'Issue finished'
}

Export-ModuleMember -Function Initialize-Issue
