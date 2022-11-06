Join-Path $PSScriptRoot 'Helpers.psm1' | Import-Module

function Invoke-Action {
    <#
    .SYNOPSIS
        Invoke specific action handler.
    #>
    switch ($EVENT_TYPE) {
        'pull_request' { Initialize-PR }
        'issue_comment' { Initialize-PR }
        'schedule' { Initialize-Scheduled }
        'issues' { Initialize-Issue }
        default { Write-ActionLog 'Not supported event type' -Err }
    }
}

Export-ModuleMember -Function Invoke-Action
