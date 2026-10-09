# Resolving upgrade blockers

How to fix each blocker that `Test-DLUpgradeReadiness.ps1` reports. Each
`BLOCKED` line in the script's output ends with `See: RESOLVING.md > <section>`;
the section names below match.

## Before you start

- Run every command in Exchange Online PowerShell unless the section says
  otherwise. See
  [Connect to Exchange Online PowerShell](https://learn.microsoft.com/powershell/exchange/connect-to-exchange-online-powershell).
- Replace each `<placeholder>` with a name, alias, email address or GUID. The
  script's output lists the exact objects involved.
- Record the current state before changing it. Several fixes remove settings
  you may want to restore after the upgrade. For example:
  `Get-DistributionGroup <DL> | Format-List * > before.txt`
- If you aren't an owner of a group you change and the command fails with a
  management-rights error, add `-BypassSecurityGroupManagerCheck` to
  `Set-DistributionGroup`, `Add-DistributionGroupMember` or
  `Remove-DistributionGroupMember`.
- Changes can take a few minutes to replicate. Re-run the script after fixing
  everything; upgrade only when it reports no blockers.

## Upgrading once the list is clear

**An upgrade can't be undone.** The new Microsoft 365 group keeps the list's
email address and members, so people keep sending mail to the same address.

You need the Exchange Administrator (or Global Administrator) role and a
mailbox of your own. Choose one way to upgrade:

- **Ask the owners to approve it.** In the Exchange admin center, go to
  **Recipients > Groups > Distribution list**, select the list, and choose
  **Send upgrade request**. Pick the owners to email and select **Send
  Request**. The upgrade starts when an owner selects **Upgrade** in that
  email.
- **Upgrade it yourself** in PowerShell:

```powershell
Upgrade-DistributionGroup -DlIdentities '<DL email address>'
```

The upgrade usually finishes within 10 minutes. See Microsoft's
[Upgrade distribution lists to Microsoft 365 Groups](https://learn.microsoft.com/exchange/recipients-in-exchange-online/manage-distribution-groups/upgrade-distribution-lists).
If it doesn't finish, see
[Upgrade fails even though every check passes](#upgrade-fails-even-though-every-check-passes).

## Security group

**Why:** The group is a mail-enabled security group. Only distribution lists
can be upgraded, and a security group can't be converted into one.

**Fix:** Create a new Microsoft 365 group and copy the membership. The
commands copy only members a Microsoft 365 group accepts (people and shared
mailboxes); the script's output and `Get-DistributionGroupMember` show any
others, such as contacts or nested groups. Owners must be added as members
before they can be added as owners.

```powershell
$source = '<security group>'
$new = New-UnifiedGroup -DisplayName '<display name>' -Alias '<new alias>' -AccessType Private -Owner '<owner>'
$members = Get-DistributionGroupMember -Identity $source -ResultSize Unlimited |
    Where-Object RecipientTypeDetails -in 'UserMailbox', 'SharedMailbox', 'TeamMailbox', 'MailUser'
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Members -Links $members.PrimarySmtpAddress
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Members -Links '<owner>'
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Owners -Links '<owner>'
Get-UnifiedGroupLinks -Identity $new.Identity -LinkType Owners   # check the owners
```

If you see yourself listed as an owner and don't want to be, remove yourself
with `Remove-UnifiedGroupLinks -LinkType Owners`.

**Watch out:** Security groups often grant permissions, such as mailbox access,
SharePoint sites or app access. The new group doesn't inherit any of them.
Keep the security group for permissions, or re-grant each one to the new
group.

The new group gets a new address. To move the old address to it, give the
security group a different primary address, remove the old address from it,
then give the old address to the new group. Mail sent to the old address
bounces until the last command runs, so run all three together.

```powershell
Set-DistributionGroup -Identity $source -PrimarySmtpAddress '<different address>'
Set-DistributionGroup -Identity $source -EmailAddresses @{Remove='<old address>'}
Set-UnifiedGroup -Identity $new.Identity -PrimarySmtpAddress '<old address>'
```

## Dynamic distribution group

**Why:** Dynamic distribution groups compute membership from a filter, so there
is no fixed membership to upgrade.

**Fix:** Choose one:

- Keep the dynamic distribution group. It keeps working as it does today.
- Create a Microsoft 365 group with dynamic membership in the Microsoft Entra
  admin center (**Groups > New group**, membership type **Dynamic User**).
  Rewrite the Exchange recipient filter as an Entra membership rule; see
  [Create or update a dynamic membership group](https://learn.microsoft.com/entra/identity/users/groups-create-rule).
  Dynamic membership requires Microsoft Entra ID P1 or higher.
- Create a Microsoft 365 group with fixed membership copied from the current
  members:

```powershell
$members = Get-DynamicDistributionGroupMember -Identity '<dynamic group>' -ResultSize Unlimited
$new = New-UnifiedGroup -DisplayName '<display name>' -Alias '<alias>' -AccessType Private
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Members -Links $members.PrimarySmtpAddress
```

**Watch out:** A copied membership doesn't update itself when people join or
leave.

## Room list

**Why:** The group was converted to a room list (`-RoomList`). Room lists
exist for room finders in Outlook and can't be upgraded or converted back to
ordinary distribution lists.

**Fix:** Keep the room list for room booking. If people also use it as a
mailing list, create a separate Microsoft 365 group for them (see
[Security group](#security-group) for the commands).

## Unsupported group type

**Why:** The object isn't a cloud universal distribution list. For example, it
may be a non-universal group (`MailNonUniversalGroup`) left over from an older
on-premises Exchange, or not a group at all. The script's output shows its
`RecipientTypeDetails`.

**Fix:** If it's an on-premises group, change its group scope to Universal in
Active Directory (see
[Group scope](https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-groups#group-scope))
and let it sync, then follow
[Synced from on-premises](#synced-from-on-premises).
Otherwise, create a new Microsoft 365 group and move the membership (see
[Security group](#security-group)).

## Synced from on-premises

**Why:** The list is synced from on-premises Active Directory (`IsDirSynced` is
`True`), so Active Directory owns it and Exchange Online can't change it.

**Fix (preferred): move the source of authority to the cloud.** Microsoft
Entra group source of authority (SOA) conversion makes a synced group
cloud-managed while it keeps its identity and membership.

Before you start, check Microsoft's prerequisites in
[Configure Group Source of Authority](https://learn.microsoft.com/entra/identity/hybrid/how-to-group-source-of-authority-configure#prerequisites).
In short, you need:

- the **Hybrid Administrator** role to make the change, and the Application
  Administrator or Cloud Application Administrator role to approve
  (consent to) the permissions below the first time
- a recent sync client: Microsoft Entra Connect Sync 2.5.76.0 or later, or
  Cloud Sync 1.1.1370.0 or later. Older versions ignore the change and keep
  syncing from Active Directory.
- the Microsoft Graph PowerShell SDK; see
  [Install the Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/installation)

```powershell
# Exchange Online: find the group's Entra object ID
$id = (Get-DistributionGroup -Identity '<DL>').ExternalDirectoryObjectId

# Microsoft Graph
Connect-MgGraph -Scopes 'Group.ReadWrite.All', 'Group-OnPremisesSyncBehavior.ReadWrite.All'
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groups/$id/onPremisesSyncBehavior" -Body @{ isCloudManaged = $true }
```

Wait for the change to reach Exchange Online: `(Get-DistributionGroup '<DL>').IsDirSynced`
should return `False`. Then re-run the script.

**Fix (alternative): recreate the list in the cloud.** Record the list's
members, owners, email addresses and settings. Remove it from on-premises
Active Directory or from the sync scope (see
[Microsoft Entra Connect Sync: Configure filtering](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-sync-configure-filtering)),
wait until `Get-DistributionGroup '<DL>'` no longer finds it, then create a
cloud distribution list with the same addresses and membership
(`New-DistributionGroup`).

**Watch out:** Once the source of authority moves, changes made on-premises no
longer sync to the cloud. Recreating the list causes a mail outage until the
new list exists, and messages to the old address bounce while the address is
free.

## No owner

**Why:** An upgraded Microsoft 365 group must have an owner, and this list has
none (`ManagedBy` is empty).

**Fix:** Add one or more owners. `@{Add=...}` keeps any existing owners.

```powershell
Set-DistributionGroup -Identity '<DL>' -ManagedBy @{Add='<owner>'}
```

The owner must be a mailbox or mail user. Owners aren't added as members
automatically; add them as members too if they should get the list's mail.

## Too many owners

**Why:** A Microsoft 365 group can't be created with more than 100 owners.

**Fix:** Remove owners until 100 or fewer remain. `@{Remove=...}` keeps the
other owners.

```powershell
(Get-DistributionGroup -Identity '<DL>').ManagedBy   # review current owners
Set-DistributionGroup -Identity '<DL>' -ManagedBy @{Remove='<owner1>','<owner2>'}
```

## Unsupported owner types

**Why:** A Microsoft 365 group's owners must be user mailboxes or mail users.
One or more owners of this list (listed in the script's output) are something
else, such as a shared mailbox, a group, or a user with no mailbox. Microsoft's
[DLT365Groupsupgrade troubleshooting script](https://microsoft.github.io/CSS-Exchange/M365/DLT365Groupsupgrade/)
reports this as a blocker.

**Fix:** If none of the current owners is supported, add a user mailbox or
mail user as owner first, so the list is never left without one. Then remove
each owner listed.

```powershell
Set-DistributionGroup -Identity '<DL>' -ManagedBy @{Add='<supported owner>'}
Set-DistributionGroup -Identity '<DL>' -ManagedBy @{Remove='<owner>'}
```

An owner shown as "not a mail-enabled recipient" is usually a user whose
mailbox or licence was removed. Either give them a mailbox again or remove them
as owner.

**Watch out:** People removed as owners can no longer manage the list's
membership. If the owner was a group, add the people who should manage the
list as owners individually.

## No members

**Why:** A list with no members can't be upgraded.

**Fix:** Add at least one supported member (user mailbox, shared mailbox or
mail user). If the list is unused, consider deleting it instead of upgrading
it.

```powershell
Add-DistributionGroupMember -Identity '<DL>' -Member '<user>'
```

## Child groups

**Why:** Microsoft 365 groups can't contain other groups, so a list with
groups as members can't be upgraded.

**Fix:** For each child group listed, add its supported members to the list
directly, then remove the child group.

```powershell
$dl = '<DL>'
$child = '<child group>'
Get-DistributionGroupMember -Identity $child -ResultSize Unlimited |
    Where-Object RecipientTypeDetails -in 'UserMailbox', 'SharedMailbox', 'TeamMailbox', 'MailUser' |
    ForEach-Object { Add-DistributionGroupMember -Identity $dl -Member $_.PrimarySmtpAddress -ErrorAction Continue }
Remove-DistributionGroupMember -Identity $dl -Member $child -Confirm:$false
```

Errors saying a recipient is already a member are harmless. This flattens one
level only. If the child group has groups of its own, re-run the script and
repeat for any groups it still reports.

**Watch out:** People added this way no longer follow the child group; later
changes to the child group don't reach the upgraded group.

## Unsupported member types

**Why:** A Microsoft 365 group's members can only be user mailboxes, shared
mailboxes, team mailboxes or mail users. Other members, such as mail contacts,
guest mail users and public folders, block the upgrade.

**Fix:** Record the members listed in the script's output, then remove them.

```powershell
Remove-DistributionGroupMember -Identity '<DL>' -Member '<member>' -Confirm:$false
```

This includes guests (`GuestMailUser`). That's expected: guests block the
upgrade, but a Microsoft 365 group can have guests once it exists. Remove
them now and add them back afterward.

After the upgrade, add external people who still need the group's mail:

1. Make sure guests are allowed in Microsoft 365 groups. See
   [Manage guest access in Microsoft 365 groups](https://learn.microsoft.com/microsoft-365/admin/create-groups/manage-guest-access-in-groups).
2. If the person isn't a guest in your tenant yet (for example, they were a
   mail contact), invite them. See
   [Add B2B collaboration users](https://learn.microsoft.com/entra/external-id/add-users-administrator).
   If the invitation fails because the email address is already in use,
   delete the old mail contact (`Remove-MailContact`) and try again.
3. Add the guest to the new group:

```powershell
Add-UnifiedGroupLinks -Identity '<new group>' -LinkType Members -Links '<guest email address>'
```

**Watch out:** Removed members stop receiving the list's mail until they're
added back as guests.

## Member of other groups

**Why:** The list is itself a member of one or more other groups (listed in the
script's output), and nested lists can't be upgraded.

**Fix:** Remove the list from each parent group.

```powershell
Remove-DistributionGroupMember -Identity '<parent group>' -Member '<DL>' -Confirm:$false
```

**Watch out:** People who got mail through the parent group because of this
list stop getting it. Before you remove the list, decide how the parent should
reach them after the upgrade, for example by adding them to the parent
directly.

## Shared mailbox forwarding

**Why:** One or more shared mailboxes (listed in the script's output) forward
their mail to this list.

**Fix:** Record each mailbox's forwarding settings, then clear forwarding.

```powershell
Get-Mailbox -Identity '<shared mailbox>' | Format-List ForwardingAddress, DeliverToMailboxAndForward
Set-Mailbox -Identity '<shared mailbox>' -ForwardingAddress $null
```

After the upgrade, set forwarding again if it's still needed:

```powershell
Set-Mailbox -Identity '<shared mailbox>' -ForwardingAddress '<new group>' -DeliverToMailboxAndForward $true
```

**Watch out:** Until forwarding is restored, mail sent to the shared mailbox
stays in it and doesn't reach the list's members. If
`DeliverToMailboxAndForward` was `False`, nobody may see that mail unless
someone monitors the shared mailbox.

## Sender restriction

**Why:** Other distribution lists (listed in the script's output) accept mail
only from members of this list (`AcceptMessagesOnlyFromDLMembers`).

**Fix:** For each other list, run these steps in order.

**1. Record who is allowed to send to it.**

```powershell
Get-DistributionGroup -Identity '<other DL>' | Format-List AcceptMessagesOnlyFrom*
```

**2. If this list is the only entry, add a replacement first,** for example
the individual people who should be allowed to send. Skipping this step lets
**anyone** send to the other list once step 3 runs.

```powershell
Set-DistributionGroup -Identity '<other DL>' -AcceptMessagesOnlyFrom @{Add='<user1>','<user2>'}
```

**3. Remove this list from the restriction.** `@{Remove=...}` keeps the other
allowed senders.

```powershell
Set-DistributionGroup -Identity '<other DL>' -AcceptMessagesOnlyFromDLMembers @{Remove='<DL>'}
```

## Alias special characters

**Why:** The list's alias contains characters that Microsoft 365 groups don't
accept. The script's output shows which characters.

**Fix:** Change the alias to one that uses only letters, digits, `.`, `-` and
`_`.

```powershell
Set-DistributionGroup -Identity '<DL>' -Alias '<new-alias>'
```

**Watch out:** Changing the alias doesn't change the list's email addresses.
Check them with `(Get-DistributionGroup '<DL>').EmailAddresses`. The new alias
must not already be used by another recipient.

## Email address policy

**Why:** The tenant has a custom email address policy for Microsoft 365
groups. While it exists, **no** distribution list in the tenant can be
upgraded.

The built-in `Default Policy` (priority `Lowest`) exists in every tenant and
isn't a blocker, so the script ignores it. Don't remove or change it. Custom
policies always have a numeric priority
([Set-EmailAddressPolicy](https://learn.microsoft.com/powershell/module/exchange/set-emailaddresspolicy#-priority)).

**Fix:** Record the policy's settings, remove the policy, upgrade your lists,
then recreate the policy if you still need it.

```powershell
Get-EmailAddressPolicy | Format-List * > email-address-policies.txt
Remove-EmailAddressPolicy -Identity '<policy>'
```

After the upgrades are done, recreate each policy from the values you
recorded. Copy `Priority`, `EnabledEmailAddressTemplates` and, if it isn't
empty, `ManagedByFilter` (which limits the policy to groups created by certain
users):

```powershell
New-EmailAddressPolicy -Name '<policy>' -IncludeUnifiedGroupRecipients -EnabledEmailAddressTemplates '<template1>','<template2>' -Priority <recorded priority>
```

Add `-ManagedByFilter '<recorded filter>'` to that command if the policy had
one. See
[New-EmailAddressPolicy](https://learn.microsoft.com/powershell/module/exchange/new-emailaddresspolicy).

**Watch out:** This affects the whole tenant. While the policy is gone, new
Microsoft 365 groups get addresses in the tenant's default domain instead of
the policy's domain. Existing groups keep their addresses. Coordinate with
whoever owns the tenant's group naming and addressing, and keep the gap
short.

## Undocumented block

**Why:** Microsoft's own check (`Get-EligibleDistributionGroupForMigration`)
says the list isn't eligible, but none of the documented blockers apply.

**Fix:** Try these in order:

1. If someone already tried to upgrade this list, check whether an upgrade
   is still marked as in progress:
   `(Get-DistributionGroup '<DL>').MigrationToUnifiedGroupInProgress`.
   If it returns `True` and the attempt is more than an hour old, clear the
   flag, then retry the upgrade:
   `Set-DistributionGroup -Identity '<DL>' -ResetMigrationToUnifiedGroup`
2. Wait an hour and re-run the script. Recent changes may not have replicated.
3. Open a Microsoft support case. Include the script's output, which shows
   every documented condition was checked.

## Upgrade fails even though every check passes

**Symptom:** The script reports no blockers and Microsoft's eligibility check
says the list is eligible, but the upgrade never completes. Either:

- the owner selects the button in the upgrade email and the card says
  "Upgrade process failed", or
- `Upgrade-DistributionGroup` reports that the request was submitted.
  `WhenChanged` updates to the time of the attempt, but
  `MigrationToUnifiedGroupInProgress` stays `False` and the list stays a
  distribution list.

No error appears in PowerShell or in the unified audit log.

**Why:** Unknown. Microsoft doesn't document this failure. The upgrade runs as
a background job in Microsoft's service, which doesn't report its errors to
admins. Others have seen it on simple cloud lists too
([Office 365 for IT Pros](https://office365itpros.com/2024/10/14/upgrade-distribution-lists-failure/)).
The script can only check for documented causes, so it can't detect this.

**Fix:** Work out whether the problem is the list or the tenant, then involve
Microsoft. Upgrades can't be undone, so test only with lists you're willing to
convert.

**1. Confirm the upgrade failed.** Upgrades normally finish in 5 to 10
minutes. Wait at least an hour, then check:

```powershell
Get-DistributionGroup '<DL>' | Format-List MigrationToUnifiedGroupInProgress, WhenChanged
Get-Recipient '<DL>' | Format-List RecipientTypeDetails
```

`GroupMailbox` means the upgrade finished. `MigrationToUnifiedGroupInProgress`
of `True` means it's still running.

**2. Retry as an admin.** If the owner's approval failed, have an admin with
the Exchange Administrator role run the upgrade. This shows whether the
problem is limited to the owner's approval step.

```powershell
Upgrade-DistributionGroup -DlIdentities '<DL email address>'
```

**3. Test with a new list.** Create a simple list with one owner and one
member, upgrade it, and check it after an hour as in step 1.

```powershell
New-DistributionGroup -Name '<test name>' -Alias '<test alias>' -ManagedBy '<owner>' -Members '<member>'
Upgrade-DistributionGroup -DlIdentities '<test alias>@<domain>'
```

Delete the test list afterward. If it upgraded, it's now a Microsoft 365
group: `Remove-UnifiedGroup -Identity '<test alias>@<domain>'`. If not:
`Remove-DistributionGroup -Identity '<test alias>@<domain>'`.

- If the new list upgrades, the problem is specific to the original list.
  Recreating it is usually quicker than a support case. Record the original
  list's members, owners and addresses, delete it with
  `Remove-DistributionGroup`, then create the new list with
  `New-DistributionGroup` using the same addresses. Mail to the list bounces
  between the two steps, so do them together.
- If the new list also fails, something in the tenant blocks every upgrade.
  Go to step 4.

**4. Open a Microsoft support case.** Only Microsoft's service-side logs show
the real error. Include:

- each list's primary SMTP address, GUID and `ExternalDirectoryObjectId`
- the date, time and time zone of each attempt, and who started it (owner
  email or admin PowerShell)
- the output of `Get-EligibleDistributionGroupForMigration` for each list,
  showing they're eligible
- this script's output for each list, showing no documented blocker applies
- the tenant settings you've ruled out, such as email address policies,
  group naming policy and who can create Microsoft 365 groups

Ask Microsoft for the error logged by the upgrade job for each attempt.
