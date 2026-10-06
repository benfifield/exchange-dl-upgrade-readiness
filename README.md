# Test-DLUpgradeReadiness

[![Tests](../../actions/workflows/test.yml/badge.svg)](../../actions/workflows/test.yml)

Explains **why** a distribution list (DL) can't be upgraded to a Microsoft 365
group. The script checks one DL against every blocker in Microsoft KB 4481100,
[Can't upgrade distribution lists to Microsoft 365 Groups](https://learn.microsoft.com/troubleshoot/exchange/groups-and-distribution-lists/cannot-upgrade-distribution-lists-to-office-365-groups),
and names the members, groups, mailboxes or policies causing each blocker.

The script is read-only. It changes nothing in the tenant. See
[SECURITY.md](SECURITY.md) for details.

> **Not affiliated with Microsoft.** This is an independent tool, not endorsed
> or supported by Microsoft. The checks follow KB 4481100 as of April 2025.
> Microsoft's article is the source of truth, and Microsoft can change the
> upgrade rules at any time.

## Requirements

- PowerShell 7+ or Windows PowerShell 5.1
- `ExchangeOnlineManagement` module:
  `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
- An account that can read recipients and email address policies and run
  `Get-EligibleDistributionGroupForMigration`, for example **Exchange
  Administrator**. A check the account lacks rights for is reported as `ERROR`;
  the other checks still run.

## Usage

```powershell
.\Test-DLUpgradeReadiness.ps1 -Identity sales@contoso.com
```

`-Identity` accepts an email address, alias, name or GUID. If no Exchange Online
session is open, an interactive sign-in window appears. A session the script
opened is disconnected when it finishes; an existing session is left open.

A bare run shows only the report. Result objects are written to the pipeline
when the output is piped, or always with `-PassThru` (needed when assigning the
output to a variable):

```powershell
.\Test-DLUpgradeReadiness.ps1 sales@contoso.com | Export-Csv sales-report.csv -NoTypeInformation
$r = .\Test-DLUpgradeReadiness.ps1 sales@contoso.com -PassThru
$r | Where-Object Status -eq 'Blocked'
```

Each object has `Check`, `Status` (`Pass`, `Blocked`, `Warning`, `Error`,
`Info`, `NotApplicable`), `Detail`, `Items` (the offending objects),
`Resolution` (a one-line fix) and `Guide` (the RESOLVING.md section).
`Resolution` and `Guide` are empty for results that need no fix.

The output contains real names, email addresses and group memberships from
your tenant. Redact it before sharing it publicly, including in issues on this
repository. The repo's `.gitignore` excludes `*.csv` so exported reports aren't
committed by accident.

## Sample output

```text
Distribution list: Sales Team <sales@contoso.com>
GUID:              3f2a9c1e-...

[PASS   ] Group type: Distribution list.
[PASS   ] Cloud managed: Managed in the cloud.
[BLOCKED] Owners: Has no owner (ManagedBy is empty). Assign at least one owner.
            Fix: Set-DistributionGroup -Identity <DL> -ManagedBy @{Add="<owner>"}
            See: RESOLVING.md > No owner
[BLOCKED] Alias characters: Alias 'sales&eu' contains special characters. Use only letters, digits, '.', '-' and '_'.
            - '&'
            Fix: Set-DistributionGroup -Identity <DL> -Alias <new alias using only letters, digits, . - _>
            See: RESOLVING.md > Alias special characters
[BLOCKED] Nested: member of other groups: Is a member of 1 other group(s). Remove it from them.
            - All Staff <all@contoso.com>
            Fix: Remove-DistributionGroupMember -Identity <parent group> -Member <DL> for each parent listed.
            See: RESOLVING.md > Member of other groups
[INFO   ] Microsoft eligibility check: Microsoft reports this list as not eligible, consistent with the blockers above.

3 blocker(s) found. Fix every BLOCKED item above (RESOLVING.md has step-by-step instructions), re-run this script, then retry the upgrade.
```

## Fixing blockers

Each `BLOCKED` line shows a one-line `Fix:` and the section of
[RESOLVING.md](RESOLVING.md) with full steps, commands and side effects to
watch for. RESOLVING.md also explains how to run the upgrade once the list is
clear.

A clean report doesn't guarantee the upgrade will succeed. Microsoft's upgrade
job can fail without reporting an error. If that happens, see
[Upgrade fails even though every check passes](RESOLVING.md#upgrade-fails-even-though-every-check-passes).

## Checks

| Check | Blocked when | How to fix |
|---|---|---|
| Group type | The group is a mail-enabled security group, a dynamic distribution group, a room list or another non-DL type. Remaining checks are skipped. | [Security group](RESOLVING.md#security-group), [Dynamic distribution group](RESOLVING.md#dynamic-distribution-group), [Room list](RESOLVING.md#room-list), [Unsupported group type](RESOLVING.md#unsupported-group-type) |
| Cloud managed | The group is synced from on-premises AD (`IsDirSynced`). | [Synced from on-premises](RESOLVING.md#synced-from-on-premises) |
| Owners | The group has no owner, or more than 100 owners. | [No owner](RESOLVING.md#no-owner), [Too many owners](RESOLVING.md#too-many-owners) |
| Has members | The group has no members. | [No members](RESOLVING.md#no-members) |
| Nested: child groups | A member is itself a group. | [Child groups](RESOLVING.md#child-groups) |
| Member types | A member isn't `UserMailbox`, `SharedMailbox`, `TeamMailbox` or `MailUser`. | [Unsupported member types](RESOLVING.md#unsupported-member-types) |
| Nested: member of other groups | The group is a member of another group. | [Member of other groups](RESOLVING.md#member-of-other-groups) |
| Shared mailbox forwarding | A shared mailbox forwards to the group. | [Shared mailbox forwarding](RESOLVING.md#shared-mailbox-forwarding) |
| Sender restriction in other DLs | Another DL accepts mail only from this group's members. | [Sender restriction](RESOLVING.md#sender-restriction) |
| Alias characters | The alias contains characters other than letters, digits, `.`, `-` and `_`. Microsoft's article says only "special characters" without listing them, so this allowed set is an inference and may be stricter or looser than Microsoft's actual rule. | [Alias special characters](RESOLVING.md#alias-special-characters) |
| Tenant: group email address policy | A custom email address policy targets Microsoft 365 groups. This check covers the whole tenant and blocks every DL. | [Email address policy](RESOLVING.md#email-address-policy) |
| Microsoft eligibility check | Not a blocker. It compares the result with `Get-EligibleDistributionGroupForMigration` and warns when the two disagree. For example, Microsoft may report the DL ineligible with no documented blocker found. | [Undocumented block](RESOLVING.md#undocumented-block) |

The checks use server-side OPATH filters. If a tenant rejects a filter
property, the check falls back to a full scan and prints a warning, since the
scan can be slow in large tenants.

## Tests

Tests use Pester 5+ and mock every Exchange cmdlet, so they need neither a
tenant nor the Exchange module.

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./tests
```

## License

[MIT](LICENSE)
