Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Initialize-PR {
    <#
    .SYNOPSIS
        Handle pull requests actions.
    #>
    Write-Log 'PR initialized'

    $commented = $false
    switch ($EVENT.action) {
        'opened' {
            Write-Log 'Opened PR'
        }
        'created' {
            Write-Log 'Commented PR'

            if ($EVENT.comment.body -like '/verify*') {
                Write-Log 'Verify comment'

                if ($EVENT.issue.pull_request) {
                    Write-Log 'Pull request comment'

                    $commented = $true
                    # There is need to get actual pull request event
                    $content = Invoke-GithubRequest "repos/$REPOSITORY/pulls/$($EVENT.issue.number)" | Select-Object -ExpandProperty Content
                    $EVENT_new = ConvertFrom-Json $content
                } else {
                    Write-Log 'Issue comment'
                    exit 0
                }
            } else {
                Write-Log 'Not supported comment body'
                exit 0
            }
        }
        default {
            Write-Log 'Only action ''opened'' is supported'
            exit 0
        }
    }
    Write-Log 'Pure PR Event' $EVENT

    if ($EVENT_new) {
        Write-Log 'There is new event available'

        $EVENT = $EVENT_new

        Write-Log 'New event' $EVENT
    }

    Write-Log 'Commented' $commented

    #region Forked repo / branch selection
    $head = if ($commented) { $EVENT.head } else { $EVENT.pull_request.head }
    if ($head.repo.fork) {
        Write-Log 'Forked repository'

        $REPOSITORY_forked = "$($head.repo.full_name):$($head.ref)"
        Write-Log 'Repo' $REPOSITORY_forked

        $cloneLocation = '/github/forked_workspace'
        git clone --branch $head.ref $head.repo.clone_url $cloneLocation
        $BUCKET_ROOT = $cloneLocation
        $buck = Join-Path $BUCKET_ROOT 'bucket'
        $MANIFESTS_LOCATION = if (Test-Path $buck) { $buck } else { $BUCKET_ROOT }

        Push-Location $cloneLocation
    }

    # Repository context of commented PR is not set to $head.ref
    $ref = $head.ref
    if ((@(git branch) -replace '^\*\s+(.*)$', '$1') -ne $ref) {
        Write-Log "Switching branch to $ref"
        git checkout $ref
        git pull
    }

    # When forked repository it needs to be '/github/forked_workspace'
    Write-Log 'Context of action' (Get-Location)

    #endregion Forked repo
    Write-log 'Files in PR'

    (Get-ChildItem $BUCKET_ROOT | Select-Object -ExpandProperty Basename) -join ', '
    (Get-ChildItem $MANIFESTS_LOCATION | Select-Object -ExpandProperty Basename) -join ', '

    $checks = @()
    $invalid = @()
    $prID = $EVENT.number

    # Do not run on removed files
    $files = Get-AllChangedFilesInPR $prID -Filter
    Write-Log 'PR Files' $files

    foreach ($file in $files) {
        Write-Log "Starting $($file.filename) checks"

        # Reset variables from previous iteration
        $manifest = $null
        $object = $null
        $statuses = [Ordered] @{ }

        # Convert path into gci item to hold all needed information
        $manifest = Get-ChildItem $BUCKET_ROOT $file.filename
        Write-Log 'Manifest' $manifest

        $object = Get-Content $manifest.Fullname -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -eq $object) {
            Write-Log 'Conversion failed'

            # Handling of configuration files (vscode, ...) will not be problem as soon as nested bucket folder is restricted
            Write-Log 'Extension' $manifest.Extension
            if ($manifest.Extension -eq '.json') {
                Write-Log 'Invalid JSON'
                $invalid += $manifest.Basename
            } else {
                Write-Log 'Not manifest at all'
            }
            Write-Log "Skipped $($file.filename)"
            continue
        }

        #region Property checks
        $statuses.Add('Description', ([bool] $object.description))
        $statuses.Add('License', ([bool] $object.license))
        # TODO: More advanced license checks
        #endregion Property checks

        #region Hashes
        Write-Log 'Hashes'

        $outputH = @(& (Join-Path $BINARIES_FOLDER 'checkhashes.ps1') -App $manifest.Basename -Dir $MANIFESTS_LOCATION *>&1)
        Write-Log 'Output' $outputH

        # everything should be all right when latest string in array will be OK
        $statuses.Add('Hashes', ($outputH[-1] -like 'OK'))

        Write-Log 'Hashes done'
        #endregion Hashes

        #region Checkver
        Write-Log 'Checkver'
        $outputV = @(& (Join-Path $BINARIES_FOLDER 'checkver.ps1') -App $manifest.Basename -Dir $MANIFESTS_LOCATION -Force *>&1)
        Write-log 'Output' $outputV

        # If there are more than 2 lines and second line is not version, there is problem
        $checkver = ((($outputV.Count -ge 2) -and ($outputV[1] -like "$($object.version)")))
        $statuses.Add('Checkver', $checkver)

        switch -Wildcard ($outputV[-1]) {
            'ERROR*' {
                Write-Log 'Error in checkver'
                $autoupdate = $false
            }
            "couldn't match*" {
                Write-Log 'Version match fail'
                $autoupdate = $false
            }
            default { $autoupdate = $checkver }
        }
        $statuses.Add('Autoupdate', $autoupdate)

        # There is some hash property defined in autoupdate
        if ((hash $object.autoupdate '32bit') -or (hash $object.autoupdate '64bit')) {
            # If any item contains 'Could not find hash*' there is hash extraction error.
            $statuses.Add('Autoupdate Hash Extraction', ($outputV -notlike 'Could not find hash*'))
        }


        Write-Log 'Checkver done'
        #endregion

        #region formatjson
        Write-Log 'Format'
        # TODO: implement format check using array compare if possible (or just strings with raws)
        # TODO: I am not sure if this will handle tabs and everything what could go wrong.
        #$raw = Get-Content $manifest.Fullname -Raw
        #$new_raw = $object | ConvertToPrettyJson
        #$statuses.Add('Format', ($raw -eq $new_raw))
        Write-Log 'Format done'
        #endregion formatjson

        $checks += [Ordered] @{ 'Name' = $manifest.Basename; 'Statuses' = $statuses }

        Write-Log "Finished $($file.filename) checks"
    }

    Write-Log 'Checked manifests' $checks.name
    Write-Log 'Invalids' $invalid

    # No checks at all
    # There were no manifests compatible
    if (($checks.Count -eq 0) -and ($invalid.Count -eq 0)) {
        Write-Log 'No compatible files in PR'
        exit 0
    }

    # Create nice comment to post
    $message = New-Array
    foreach ($check in $checks) {
        Add-IntoArray $message "### $($check.Name)"
        Add-IntoArray $message ''

        foreach ($status in $check.Statuses.Keys) {
            $b = $check.Statuses.Item($status)
            Write-Log $status $b

            if (-not $b) { $env:NON_ZERO_EXIT = $true }

            Add-IntoArray $message (New-CheckListItem $status -OK:$b)
        }
        Add-IntoArray $message ''
    }

    if ($invalid.Count -gt 0) {
        Write-Log 'PR contains invalid manifests'

        $env:NON_ZERO_EXIT = $true

        Add-IntoArray $message '### Invalid manifests'
        Add-IntoArray $message ''

        Add-IntoArray $message ($invalid | ForEach-Object { "- $_`n" })
    }

    # Add some more human friendly message
    if ($env:NON_ZERO_EXIT) {
        $message.Insert(0, 'Your changes does not pass some checks')
        Add-Label -ID $prID -Label 'package-fix-neeed'
    } else {
        $message.InsertRange(0, @('All changes looks good.', '', 'Wait for review from human collaborators.'))
        Remove-Label -ID $prID -Label 'package-fix-neeed'
        Add-Label -ID $prID -Label 'review-needed'
    }
    # TODO: Comment URL to action log
    # $url = "https://github.com/$REPOSITORY/runs/$RUN_ID"
    # Add-IntoArray $message "_You can find log of all checks in '$url'_"

    Add-Comment -ID $prID -Message $message

    Write-Log 'PR finished'
}

Export-ModuleMember -Function Initialize-PR