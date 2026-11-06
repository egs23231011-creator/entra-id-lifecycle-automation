# Entra ID Lifecycle Automation Lab

PowerShell automation for the Joiner-Mover-Leaver lifecycle in Microsoft Entra ID, using the Microsoft Graph PowerShell SDK and certificate-based app-only authentication.

> **Lab project.** Built and tested in a Microsoft Entra test tenant with fake users. Not used in production.

## Status

| Workflow | Script | Status |
| --- | --- | --- |
| Leaver (offboarding) | `scripts/Offboard-Users.ps1` | Built and tested in lab |
| Joiner (onboarding) | `scripts/New-Joiner.ps1` | Built and tested in lab |
| Mover (department change) | n/a | Planned |

## Leaver workflow

For each user in a CSV, in this order:

1. Disable the account.
2. Revoke sign-in sessions.
3. Tag the record (`extensionAttribute1`) with the offboarding timestamp, so real profile data isn't overwritten.
4. Remove all group memberships.
5. Remove directly assigned licenses.

**Why this order.** Disabling first stops new sign-ins, so a user cannot start a fresh session in the gap before sessions are revoked. Revoking sessions invalidates refresh tokens. Access tokens that were already issued can stay valid for a limited time unless Continuous Access Evaluation applies, so revocation is not instant.

## Joiner workflow

For each row in a CSV (`FirstName`, `LastName`, `Department`, `JobTitle`, optional `ManagerUPN`):

1. Validate the row: names present and the department exists in the access policy map.
2. Skip the user if the account already exists, so re-runs are safe.
3. Create the user with a random password and a forced change at first sign-in.
4. Assign the license.
5. Add the department's groups (for example, Sales gets All-Staff and Sales).
6. Set the manager, if one is given.

Input example:

```csv
FirstName,LastName,Department,JobTitle,ManagerUPN
Maya,Chen,Sales,Account Executive,manager@yourtenant.onmicrosoft.com
Dev,Patel,Engineering,Support Engineer,
```

Lab result: two valid rows were created, licensed, grouped, and (for one) given a manager; a row with an unknown department was rejected by validation. Re-run: TODO (fill in after running it a second time).

Lab shortcut: the random password is never shown. A production workflow would use a Temporary Access Pass or a similar controlled onboarding step.
## Design

**Authentication.** The script signs in as an app registration using a certificate, so it can run unattended with no password or client secret. The private key stays in the certificate store and is marked non-exportable.

**Permissions (Microsoft Graph, application):**

| Permission | Used for |
| --- | --- |
| `User.ReadWrite.All` | Disable users, revoke sessions, update attributes, remove licenses |
| `GroupMember.ReadWrite.All` | Remove users from groups |
| `Directory.Read.All` | Read a user's group memberships |

`User.ReadWrite.All` as an application permission is tenant-wide. In production this should be narrowed, for example with Administrative Units.

**Safety features**

- `-WhatIf` dry run. Every action is previewed and logged as `WhatIf` with nothing changed.
- Per-user, per-step error handling. A bad row is logged and skipped; the run continues.
- CSV audit log with timestamp, user, step, status, and detail.
- Safe re-runs: steps are repeatable and missing users are logged, not fatal.

## Usage

**Prerequisites:** PowerShell 7, and the Graph modules:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, `
    Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
```

**One-time setup**

1. Create an app registration in the test tenant (single tenant, no redirect URI).
2. Create a self-signed certificate and upload the public `.cer` to the app:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=Lifecycle-Automation-Lab' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeySpec Signature `
    -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1)
Export-Certificate -Cert $cert -FilePath .\Lifecycle-Automation-Lab.cer
$cert.Thumbprint
```

3. Add the three application permissions above and grant admin consent.
4. Confirm sign-in works: `(Get-MgContext).AuthType` should print `AppOnly`.

**Leaver input (`leavers.csv`)**

```csv
UserPrincipalName
leaver1@yourtenant.onmicrosoft.com
leaver2@yourtenant.onmicrosoft.com
```

**Run**

```powershell
# Preview only
.\scripts\Offboard-Users.ps1 -CsvPath .\leavers.csv -WhatIf

# Real run with certificate auth
.\scripts\Offboard-Users.ps1 -CsvPath .\leavers.csv `
    -TenantId '<tenant-id>' -ClientId '<client-id>' -CertThumbprint '<thumbprint>'
```

## Sample audit log

```csv
"Timestamp","User","Step","Status","Detail"
"2026-11-05T20:02:03","leaver1@yourtenant.onmicrosoft.com","Disable account","Success",""
"2026-11-05T20:02:05","leaver1@yourtenant.onmicrosoft.com","Revoke sign-in sessions","Success",""
"2026-11-05T20:02:05","leaver1@yourtenant.onmicrosoft.com","Tag as offboarded","Success",""
```

See `samples/sample-audit-log.csv` for a full run. Tenant details are replaced with placeholders.

## Lab results

- Test setup: 3 users to offboard, 1 control user, and 1 invalid account in the CSV.
- Real run: all 18 steps for the 3 users succeeded; the invalid account was logged as a failed lookup and skipped; the control user was unchanged.
- Re-run: TODO (fill in after running the script a second time).
- Screenshots: TODO (add before/after images to `docs/screenshots/` after scrubbing tenant names and emails).

## Known limitations

- Dynamic-membership and on-premises-synced groups can't be edited this way; those removals would be logged as failures.
- Licenses assigned through group-based licensing are not removed directly.
- Accounts holding admin roles may be blocked from changes by an app-only identity.
- Not covered: mailbox conversion (needs Exchange Online), MFA method removal, Intune device retire, OneDrive handoff.

## Lessons learned

- Device-code sign-in was rejected in my lab tenant while browser sign-in worked, so scripts use the interactive browser flow for human sign-in.
- Graph cmdlets can emit non-terminating errors that `try/catch` misses, which let a failed lookup continue and could log failures as successes. Fixed by defaulting all Graph cmdlets to `-ErrorAction Stop`.
- `-WhatIf` propagated into `Export-Csv`, so dry runs wrote no audit log. Fixed with `-WhatIf:$false` on the export.
- A trailing space in a pasted Client ID caused an authentication failure that looked like a certificate problem.

## Future work

- Joiner and Mover scripts sharing one department-to-groups policy.
- Scope the app with Administrative Units.
- Trigger from an HR feed instead of a CSV, with an approval step.
- Run as an Azure Automation runbook with a managed identity.
- Exchange Online offboarding steps (mailbox, forwarding).