Join-Path $PSScriptRoot 'Helpers.psm1' | Import-Module

function Install-Scoop {
    <#
    .SYNOPSIS
        Install basic scoop using the new installer and configure Shovel.
    #>
    Write-ActionLog 'Installing base scoop'
    $f = Join-Path $env:USERPROFILE 'install.ps1'
    Invoke-WebRequest 'https://raw.githubusercontent.com/ScoopInstaller/Install/master/install.ps1' -UseBasicParsing -OutFile $f
    & $f -RunAsAdmin

    Write-ActionLog 'Adopting Shovel'
    Get-ChildItem "$env:SCOOP\shims" -Filter 'scoop.*' | Copy-Item -Destination { Join-Path $_.Directory.FullName (($_.BaseName -replace 'scoop', 'shovel') + $_.Extension) }

    shovel config 'SCOOP_REPO' 'https://github.com/Ash258/Scoop-Core.git'
    shovel update

    if ($env:SCOOP_BRANCH) {
        Write-ActionLog "Switching to branch: ${env:SCOOP_BRANCH}"
        shovel config 'SCOOP_BRANCH' $env:SCOOP_BRANCH
        shovel update
    }
}

Export-ModuleMember -Function Install-Scoop
