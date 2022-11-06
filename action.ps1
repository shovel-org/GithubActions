#!/usr/bin/env pwsh
$Global:ErrorActionPreference = 'Continue'
$Global:VerbosePreference = 'Continue'

# Import all modules
Join-Path $PSScriptRoot 'src' | Get-ChildItem -File | Select-Object -ExpandProperty Fullname | Import-Module

Install-Scoop

Test-NestedBucket
Initialize-NeededConfiguration

Write-ActionLog 'Git email' (git config --get 'user.email')
Write-ActionLog 'FULL EVENT' $EVENT_RAW

Invoke-Action

Write-ActionLog 'Number of Github Requests' $env:GH_REQUEST_COUNTER

if ($env:NON_ZERO_EXIT) { exit $NON_ZERO }
