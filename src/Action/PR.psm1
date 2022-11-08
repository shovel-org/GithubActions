Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Start-PR {
    <#
    .SYNOPSIS
        PR state handler.
    .OUTPUTS
        $null - Not supported state, which should be exited on.
        $true | $false
    #>
    $commented = $false

    switch ($GH_EVENT.action) {
        'opened' {
            Write-ActionLog 'Opened PR'
        }
        'created' {
            Write-ActionLog 'Commented PR'

            if ($GH_EVENT.comment.body -like '/verify*') {
                Write-ActionLog 'Verify comment'

                if ($GH_EVENT.issue.pull_request) {
                    Write-ActionLog 'Pull request comment'

                    $commented = $true
                    # There is need to get actual pull request event
                    $content = Invoke-GithubRequest "repos/$REPOSITORY/pulls/$($GH_EVENT.issue.number)" | Select-Object -ExpandProperty 'Content'
                    $script:EVENT_new = ConvertFrom-Json $content
                } else {
                    Write-ActionLog 'Issue comment'
                    $commented = $null # No need to do anything on issue comment
                }
            } else {
                Write-ActionLog 'Not supported comment body'
                $commented = $null
            }
        }
        default {
            Write-ActionLog 'Only action ''opened'' is supported'
            $commented = $null
        }
    }

    return $commented
}

function Set-RepositoryContext {
    <#
    .SYNOPSIS
        Repository context of commented PR is not set to correct $head.ref.
    #>
    param ([Parameter(Mandatory)] $Ref)

    if ((git branch --show-current) -ne $Ref) {
        Write-ActionLog "Switching branch to $Ref"

        git fetch --all
        git checkout $Ref
        git pull
    }
}

function New-FinalMessage {
    <#
    .SYNOPSIS
        Create and post final comment with information for collaborators.
    .PARAMETER Check
        Array of manifests checks.
    .PARAMETER Invalid
        Array of invalid manifests.
    #>
    param(
        [Object[]] $Check,
        [String[]] $Invalid
    )

    $prID = $GH_EVENT.number
    $message = New-Array

    foreach ($ch in $Check) {
        Add-IntoArray $message "### $($ch.Name)"
        Add-IntoArray $message ''
        New-CheckList $ch.Statuses | ForEach-Object { Add-IntoArray $message $_ }
        Add-IntoArray $message ''
    }

    if ($Invalid.Count -gt 0) {
        Write-ActionLog 'PR contains invalid manifests'

        $env:NON_ZERO_EXIT = $true
        Add-IntoArray $message '### Invalid manifests'
        Add-IntoArray $message ''
        $Invalid | ForEach-Object { Add-IntoArray $message "- $_" }
    }

    $labelsToAdd = @()
    $labelsToRemove = @()
    # Add some more human friendly message
    if ($env:NON_ZERO_EXIT) {
        $message.Insert(0, '[Your changes do not pass checks.](https://github.com/shovel-org/GithubActions/wiki/Pull-Request-Checks)')
        $labelsToAdd += 'manifest-fix-needed'
        $labelsToRemove += 'review-needed'
    } else {
        $message.InsertRange(0, @('All changes look good.', '', 'Wait for review from human collaborators.'))
        $labelsToAdd += 'review-needed'
        $labelsToRemove += 'manifest-fix-needed'
    }

    # TODO: Comment URL to action log
    # Add-IntoArray $message "[_See log of all checks_](https://github.com/$REPOSITORY/runs/$RUN_ID)"

    Remove-Label -ID $prID -Label $labelsToRemove
    Add-Label -ID $prID -Label $labelsToAdd
    Add-Comment -ID $prID -Message $message
}

function Test-PRFile {
    <#
    .SYNOPSIS
        Validate all changed files.
    .PARAMETER File
        Changed files in pull request.
    .OUTPUTS
        Tupple of check object and array of invalid manifests.
    #>
    param([Object[]] $File)

    $check = @()
    $invalid = @()
    foreach ($f in $File) {
        Write-ActionLog "Starting $($f.filename) checks"

        # Reset variables from previous iteration
        $manifest = $null
        $object = $null
        $statuses = [Ordered] @{ }

        # TODO: Adopt verify utility

        # Convert path into gci item to hold all needed information
        $manifest = Get-ChildItem $BUCKET_ROOT $f.filename
        Write-ActionLog 'Manifest' $manifest

        # For Some reason -ErrorAction is not honored for convertfrom-json
        $old_e = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        # TODO: Yaml
        $object = shovel cat $manifest.FullName --format json | ConvertFrom-Json
        $ErrorActionPreference = $old_e

        if ($null -eq $object) {
            Write-ActionLog 'Conversion failed'

            # Handling of configuration files (vscode, ...) will not be problem as soon as nested bucket folder is restricted
            Write-ActionLog 'Extension' $manifest.Extension

            if ($manifest.Extension -eq '.json') {
                Write-ActionLog 'Invalid JSON'
                $invalid += $manifest.Basename
            } elseif ($manifest.Extension -in ('.yml', '.yaml')) {
                Write-ActionLog 'Invalid YML'
                $invalid += $manifest.Basename
            } else {
                Write-ActionLog 'Not manifest at all'
            }
            Write-ActionLog "Skipped $($f.filename)"
            continue
        }

        #region 1. Property checks
        $statuses.Add('Description', ([bool] $object.description))
        $statuses.Add('License', ([bool] $object.license))
        # TODO: More advanced license checks
        #endregion 1. Property checks

        #region 2. Hashes
        if ($object.version -ne 'nightly') {
            Write-ActionLog 'Hashes'
            $outputH = @(& shovel utils checkhashes $manifest.FullName *>&1)
            $ec = $LASTEXITCODE
            Write-ActionLog 'Output' $outputH

            # Everything should be all right when latest string in array will be OK
            $statuses.Add('Hashes', (($ec -eq 0) -and ($outputH[-1] -like 'OK')))

            Write-ActionLog 'Hashes done'
        }
        #endregion 2. Hashes

        #region 3. Checkver and 4. Autoupdate
        if ($object.checkver) {
            Write-ActionLog 'Checkver'
            $outputV = @(& shovel utils checkver $manifest.FullName --additional-options -Force *>&1)
            $ec = $LASTEXITCODE
            Write-ActionLog 'Output' $outputV

            # If there are more than 2 lines and second line is not version, there is problem
            $checkver = (($ec -eq 0) -and (($outputV.Count -ge 2) -and ($outputV[1].ToString().Trim() -eq "$($object.version)")))
            $statuses.Add('Checkver', $checkver)
            Write-ActionLog 'Checkver done'

            #region Autoupdate
            if ($object.autoupdate) {
                Write-ActionLog 'Autoupdate'
                $autoupdate = $false
                switch -Wildcard ($outputV[-1]) {
                    'ERROR*' {
                        Write-ActionLog 'Error in checkver'
                    }
                    'could*t match*' {
                        Write-ActionLog 'Version match fail'
                    }
                    'Writing updated*' {
                        Write-ActionLog 'Autoupdate finished successfully'
                        $autoupdate = $true
                    }
                    default { $autoupdate = $checkver }
                }
                $statuses.Add('Autoupdate', $autoupdate)

                # There is some hash property defined in autoupdate
                if ((($outputV -like 'Searching hash for*')) -or
                    (Get-ArchitectureSpecificProperty 'hash' $object.autoupdate '32bit') -or
                    (Get-ArchitectureSpecificProperty 'hash' $object.autoupdate '64bit') -or
                    (Get-ArchitectureSpecificProperty 'hash' $object.autoupdate 'arm64')
                ) {
                    $result = $autoupdate
                    if ($result) {
                        # If any result contains any item with 'Could not find hash*' there is hash extraction error.
                        $result = (($outputV -like 'Could not find hash*').Count -eq 0)
                    }
                    $statuses.Add('Autoupdate Hash Extraction', $result)
                }
                Write-ActionLog 'Autoupdate done'
            }
            #endregion Autoupdate
        }
        #endregion 3. Checkver and 4. Autoupdate

        $check += [Ordered] @{ 'Name' = $manifest.Basename; 'Statuses' = $statuses }

        Write-ActionLog "Finished $($f.filename) checks"
    }

    return $check, $invalid
}

function Initialize-PR {
    <#
    .SYNOPSIS
        Handle pull requests action.
    .DESCRIPTION
        1. Clone repository / Switch to correct branch
        2. Validate all changed manifests
        3. Post comment with check results
    #>
    Write-ActionLog 'PR initialized'

    #region Stage 1 - Repository initialization
    $commented = Start-PR
    if ($null -eq $commented) { return } # Exit on not supported state
    Write-ActionLog 'Commented?' $commented

    $GH_EVENT | ConvertTo-Json -Depth 8 -Compress | Write-ActionLog 'Pure PR Event'
    if ($EVENT_new) {
        Write-ActionLog 'There is new event available'
        $GH_EVENT = $EVENT_new
        $GH_EVENT | ConvertTo-Json -Depth 8 -Compress | Write-ActionLog 'New Event'
    }

    # TODO: Ternary
    $head = if ($commented) { $GH_EVENT.head } else { $GH_EVENT.pull_request.head }

    if ($head.repo.fork) {
        Write-ActionLog 'Forked repository'

        # There is no need to run whole action under forked repository due to permission problem
        if ($commented -eq $false) {
            Write-ActionLog 'Cannot comment with read only token'
            # TODO: Execute it and adopt pester like checks
            return
        }

        $REPOSITORY_forked = "$($head.repo.full_name):$($head.ref)"
        Write-ActionLog 'Repo' $REPOSITORY_forked

        $cloneLocation = "${env:TMP}\forked_repository"
        git clone --branch $head.ref $head.repo.clone_url $cloneLocation
        $script:BUCKET_ROOT = $cloneLocation
        $buck = Join-Path $BUCKET_ROOT 'bucket'
        # TODO: Ternary
        $script:MANIFESTS_LOCATION = if (Test-Path $buck) { $buck } else { $BUCKET_ROOT }

        Write-ActionLog "Switching to $REPOSITORY_forked"
        Push-Location $cloneLocation
    }

    # Repository context of commented PR is not set to $head.ref
    Set-RepositoryContext $head.ref
    #endregion Stage 1 - Repository initialization

    # In case of forked repository it needs to be '/github/forked_workspace'
    Get-Location | Write-ActionLog 'Context of action'
    (Get-ChildItem $BUCKET_ROOT | Select-Object -ExpandProperty 'BaseName') -join ', ' | Write-ActionLog 'Root Files'
    (Get-ChildItem $MANIFESTS_LOCATION | Select-Object -ExpandProperty 'BaseName') -join ', ' | Write-ActionLog 'Manifests'

    # Do not run checks on removed files
    $files = Get-AllChangedFilesInPR $GH_EVENT.number -Filter
    Write-ActionLog 'PR Changed Files' $files
    $files = $files | Where-Object -Property 'filename' -Like -Value 'bucket/*'
    Write-ActionLog 'Only Changed Manifests' $files

    # Stage 2 - Manifests validation
    $check, $invalid = Test-PRFile $files

    #region Stage 3 - Final Message
    Write-ActionLog 'Checked manifests' $check.name
    Write-ActionLog 'Invalids' $invalid

    if (($check.Count -eq 0) -and ($invalid.Count -eq 0)) {
        Write-ActionLog 'No compatible files in PR'
        return
    }

    # TODO: Pester like check
    New-FinalMessage $check $invalid
    #endregion Stage 3 - Final Message

    Write-ActionLog 'PR finished'
}

Export-ModuleMember -Function Initialize-PR
