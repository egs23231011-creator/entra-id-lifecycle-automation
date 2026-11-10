<#
.SYNOPSIS
  Lab project: bulk Leaver (offboarding) automation for Microsoft Entra ID via Microsoft Graph.

.DESCRIPTION
  Reads a CSV with a UserPrincipalName column and, per user:
  disable account -> revoke sessions -> tag record -> remove group memberships -> remove licenses.
  Every action is written to a CSV audit log. Supports -WhatIf. One bad user never stops the run.

.EXAMPLE
  # Dry run, interactive sign-in
  .\Offboard-Users.ps1 -CsvPath .\leavers.csv -WhatIf

.EXAMPLE
  # Real run, unattended with certificate auth
  .\Offboard-Users.ps1 -CsvPath .\leavers.csv -TenantId <tid> -ClientId <appid> -CertThumbprint <thumb>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$LogPath = ".\offboard-log-$(Get-Date -Format yyyyMMdd-HHmmss).csv",
    [string]$TenantId,
    [string]$ClientId,
    [string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['*-Mg*:ErrorAction'] = 'Stop'   # Graph cmdlets otherwise emit non-terminating errors that try/catch misses
$script:Log = [System.Collections.Generic.List[object]]::new()

function Write-Audit {
    param($Upn, $Step, $Status, $Detail = '')
    $script:Log.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        User      = $Upn
        Step      = $Step
        Status    = $Status
        Detail    = $Detail
    })
    Write-Host "[$Status] $Upn - $Step $Detail"
}

function Invoke-Step {
    param($Cmdlet, $Upn, $Step, [scriptblock]$Action)
    if ($Cmdlet.ShouldProcess($Upn, $Step)) {
        try   { & $Action; Write-Audit $Upn $Step 'Success' }
        catch { Write-Audit $Upn $Step 'Failed' $_.Exception.Message }
    }
    else { Write-Audit $Upn $Step 'WhatIf' }
}

# --- Connect ---
if ($ClientId -and $TenantId -and $CertThumbprint) {
    # App-only (unattended). App needs application permissions:
    # User.ReadWrite.All, GroupMember.ReadWrite.All, Directory.Read.All
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumbprint -NoWelcome
}
else {
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All' -NoWelcome
}

# --- Process leavers ---
$rows = Import-Csv -Path $CsvPath
foreach ($row in $rows) {
    $upn = "$($row.UserPrincipalName)".Trim()
    if (-not $upn) { continue }

    $user = $null
    try {
        $user = Get-MgUser -UserId $upn -Property Id, UserPrincipalName, AccountEnabled
    }
    catch {
        Write-Audit $upn 'Lookup' 'Failed' $_.Exception.Message
        continue
    }
    if (-not $user) {
        Write-Audit $upn 'Lookup' 'Failed' 'User not found'
        continue
    }

    # 1. Block sign-in FIRST so no new sessions can start
    Invoke-Step $PSCmdlet $upn 'Disable account' {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
    }

    # 2. Revoke refresh tokens (access tokens can live up to ~1h without CAE)
    Invoke-Step $PSCmdlet $upn 'Revoke sign-in sessions' {
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
    }

    # 3. Tag the record without overwriting real profile data
    Invoke-Step $PSCmdlet $upn 'Tag as offboarded' {
        Update-MgUser -UserId $user.Id -OnPremisesExtensionAttributes @{
            extensionAttribute1 = "Offboarded $(Get-Date -Format s) via script"
        }
    }

    # 4. Remove group memberships (dynamic and synced groups will fail and be logged)
    try {
        $groups = Get-MgUserMemberOf -UserId $user.Id -All |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }
    }
    catch {
        Write-Audit $upn 'List groups' 'Failed' $_.Exception.Message
        $groups = @()
    }
    foreach ($g in $groups) {
        $gName = $g.AdditionalProperties['displayName']
        Invoke-Step $PSCmdlet $upn "Remove from group: $gName" {
            Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id
        }
    }

    # 5. Remove directly assigned licenses (group-based licenses go with the group removal)
    try   { $skus = @((Get-MgUserLicenseDetail -UserId $user.Id).SkuId | Where-Object { $_ }) }
    catch { Write-Audit $upn 'List licenses' 'Failed' $_.Exception.Message; $skus = @() }
    if ($skus.Count -gt 0) {
        Invoke-Step $PSCmdlet $upn "Remove $($skus.Count) license(s)" {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skus | Out-Null
        }
    }
}

# --- Wrap up ---
$script:Log | Export-Csv -Path $LogPath -NoTypeInformation -WhatIf:$false
Write-Host "Audit log written to $LogPath"
Disconnect-MgGraph | Out-Null