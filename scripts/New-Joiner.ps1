<#
.SYNOPSIS
  Lab project: bulk Joiner (onboarding) automation for Microsoft Entra ID via Microsoft Graph.

.DESCRIPTION
  Reads a CSV with columns FirstName, LastName, Department, JobTitle and (optional) ManagerUPN.
  Per row: validate -> skip if the user already exists -> create the user -> assign a license
  -> add the department's groups -> set manager (if given).
  Every action is written to a CSV audit log. Supports -WhatIf. One bad row never stops the run.

.EXAMPLE
  # Dry run, interactive sign-in
  .\scripts\New-Joiner.ps1 -CsvPath .\joiners.csv -Domain yourtenant.onmicrosoft.com -SkuPartNumber AAD_PREMIUM_P2 -WhatIf

.EXAMPLE
  # Real run, unattended with certificate auth
  .\scripts\New-Joiner.ps1 -CsvPath .\joiners.csv -Domain yourtenant.onmicrosoft.com -SkuPartNumber AAD_PREMIUM_P2 `
      -TenantId <tid> -ClientId <appid> -CertThumbprint <thumb>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$Domain,
    [Parameter(Mandatory)][string]$SkuPartNumber,
    [string]$UsageLocation = 'US',
    [string]$LogPath = ".\joiner-log-$(Get-Date -Format yyyyMMdd-HHmmss).csv",
    [string]$TenantId,
    [string]$ClientId,
    [string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['*-Mg*:ErrorAction'] = 'Stop'   # make Graph errors catchable
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

# Access policy: which groups each department gets (role-based, kept in one place)
$DeptGroups = @{
    Sales       = @('All-Staff', 'Sales')
    Engineering = @('All-Staff', 'Engineering')
}

# --- Connect ---
if ($ClientId -and $TenantId -and $CertThumbprint) {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumbprint -NoWelcome
}
else {
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All' -NoWelcome
}

$sku = Get-MgSubscribedSku | Where-Object SkuPartNumber -eq $SkuPartNumber
if (-not $sku) { throw "License '$SkuPartNumber' not found. Run Get-MgSubscribedSku to list valid names." }

# --- Process joiners ---
foreach ($r in Import-Csv -Path $CsvPath) {
    $label = "$($r.FirstName) $($r.LastName)".Trim()
    $first = "$($r.FirstName)" -replace '[^a-zA-Z0-9]', ''
    $last  = "$($r.LastName)"  -replace '[^a-zA-Z0-9]', ''
    $dept  = "$($r.Department)".Trim()

    if (-not $first -or -not $last) {
        Write-Audit $label 'Validate' 'Failed' 'FirstName and LastName are required'
        continue
    }
    $upn = "$first.$last@$Domain".ToLower()

    if (-not $DeptGroups.ContainsKey($dept)) {
        Write-Audit $upn 'Validate' 'Failed' "Unknown department '$dept'"
        continue
    }
    $groupNames = $DeptGroups[$dept]

    # Idempotency: skip anyone who already exists
    $existing = $null
    try   { $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" }
    catch { Write-Audit $upn 'Lookup' 'Failed' $_.Exception.Message; continue }
    if ($existing) {
        Write-Audit $upn 'Create user' 'Skipped' 'Already exists'
        continue
    }

    # Dry run
    $plan = "Create user, license $SkuPartNumber, add to: $($groupNames -join ', ')"
    if (-not $PSCmdlet.ShouldProcess($upn, $plan)) {
        Write-Audit $upn 'Joiner' 'WhatIf' $plan
        continue
    }

    # 1. Create the user
    $u = $null
    try {
        $params = @{
            DisplayName       = $label
            GivenName         = "$($r.FirstName)".Trim()
            Surname           = "$($r.LastName)".Trim()
            UserPrincipalName = $upn
            MailNickname      = "$first.$last".ToLower()
            Department        = $dept
            UsageLocation     = $UsageLocation
            AccountEnabled    = $true
            PasswordProfile   = @{
                Password                      = ([guid]::NewGuid().ToString() + 'aA1!')
                ForceChangePasswordNextSignIn = $true
            }
        }
        if ("$($r.JobTitle)".Trim()) { $params.JobTitle = "$($r.JobTitle)".Trim() }
        $u = New-MgUser @params
        Write-Audit $upn 'Create user' 'Success'
    }
    catch { Write-Audit $upn 'Create user' 'Failed' $_.Exception.Message; continue }

    # New objects can take a few seconds to replicate before they accept changes
    Start-Sleep -Seconds 8

    # 2. Assign license
    try {
        Set-MgUserLicense -UserId $u.Id -AddLicenses @{ SkuId = $sku.SkuId } -RemoveLicenses @() | Out-Null
        Write-Audit $upn "Assign license $SkuPartNumber" 'Success'
    }
    catch { Write-Audit $upn "Assign license $SkuPartNumber" 'Failed' $_.Exception.Message }

    # 3. Add to the department's groups
    foreach ($gName in $groupNames) {
        try {
            $g = Get-MgGroup -Filter "displayName eq '$gName'" | Select-Object -First 1
            if (-not $g) { throw "Group '$gName' not found" }
            New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $u.Id
            Write-Audit $upn "Add to group: $gName" 'Success'
        }
        catch { Write-Audit $upn "Add to group: $gName" 'Failed' $_.Exception.Message }
    }

    # 4. Set manager (optional column)
    $mgrUpn = if ($r.PSObject.Properties['ManagerUPN']) { "$($r.ManagerUPN)".Trim() } else { '' }
    if ($mgrUpn) {
        try {
            $mgr = Get-MgUser -UserId $mgrUpn
            Set-MgUserManagerByRef -UserId $u.Id -BodyParameter @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($mgr.Id)"
            }
            Write-Audit $upn 'Set manager' 'Success' $mgrUpn
        }
        catch { Write-Audit $upn 'Set manager' 'Failed' $_.Exception.Message }
    }
}

# --- Wrap up ---
$script:Log | Export-Csv -Path $LogPath -NoTypeInformation -WhatIf:$false
Write-Host "Audit log written to $LogPath"
Disconnect-MgGraph | Out-Null