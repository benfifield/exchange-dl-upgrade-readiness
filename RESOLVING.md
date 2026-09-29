# Resolving upgrade blockers

How to fix each blocker that `Test-DLUpgradeReadiness.ps1` reports. Each
`BLOCKED` line in the script's output ends with `See: RESOLVING.md > <section>`;
the section names below match.

## Before you start

- Run every command in Exchange Online PowerShell (`Connect-ExchangeOnline`)
  unless the section says otherwise.
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

In the Exchange admin center, go to **Recipients > Groups > Distribution
list**, select the list, and choose **Upgrade to Microsoft 365 group**. Or,
in PowerShell:

```powershell
Upgrade-DistributionGroup -DlIdentities <DL email address>
```

## Security group

**Why:** The group is a mail-enabled security group. Only distribution lists
can be upgraded, and a security group can't be converted into one.

**Fix:** Create a new Microsoft 365 group and copy the membership. Owners must
be added as members before they can be added as owners.

```powershell
$source = '<security group>'
$new = New-UnifiedGroup -DisplayName '<display name>' -Alias '<alias>' -AccessType Private
$members = Get-DistributionGroupMember -Identity $source -ResultSize Unlimited
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Members -Links $members.PrimarySmtpAddress
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Members -Links '<owner>'
Add-UnifiedGroupLinks -Identity $new.Identity -LinkType Owners -Links '<owner>'
```

**Watch out:** Security groups often grant permissions, such as mailbox access,
SharePoint sites or app access. The new group doesn't inherit any of them.
Keep the security group for permissions, or re-grant each one to the new
group. The new group can't reuse the old email address until the address is
removed from the security group.

## Dynamic distribution group

**Why:** Dynamic distribution groups compute membership from a filter, so there
is no fixed membership to upgrade.

**Fix:** Choose one:

- Keep the dynamic distribution group. It keeps working as it does today.
- Create a Microsoft 365 group with dynamic membership in the Microsoft Entra
  admin center (**Groups > New group**, membership type **Dynamic User**).
  Rewrite the Exchange recipient filter as an Entra membership rule. Dynamic
  membership requires Microsoft Entra ID P1 or higher.
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

**Fix:** If it's an on-premises group, change it to a universal group in
Active Directory and let it sync, then follow
[Synced from on-premises](#synced-from-on-premises).
Otherwise, create a new Microsoft 365 group and move the membership (see
[Security group](#security-group)).

## Synced from on-premises

**Why:** The list is synced from on-premises Active Directory (`IsDirSynced` is
`True`), so Active Directory owns it and Exchange Online can't change it.

**Fix (preferred): move the source of authority to the cloud.** Microsoft
Entra group source of authority (SOA) conversion makes a synced group
cloud-managed while it keeps its identity and membership. It needs the
Microsoft Graph PowerShell SDK and an admin who can consent to the scopes
below. Review Microsoft's prerequisites first:
[Group source of authority](https://aka.ms/groupsoadocs).

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
Active Directory or from the sync scope, wait for the cloud copy to be
deleted, then create a cloud distribution list with the same addresses and
membership.

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

After the upgrade, external people who still need the group's mail can be
invited as guests (Microsoft Entra B2B) and added to the new group.

```powershell
Add-UnifiedGroupLinks -Identity '<new group>' -LinkType Members -Links '<guest user>'
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

**Fix:** Remove this list from each other list's restriction. `@{Remove=...}`
keeps the other allowed senders.

```powershell
Get-DistributionGroup -Identity '<other DL>' | Format-List AcceptMessagesOnlyFrom*
Set-DistributionGroup -Identity '<other DL>' -AcceptMessagesOnlyFromDLMembers @{Remove='<DL>'}
```

**Watch out:** If this list was the only allowed sender entry, removing it
lets **anyone** send to the other list. First add a replacement restriction,
for example the individual people who should be allowed to send:

```powershell
Set-DistributionGroup -Identity '<other DL>' -AcceptMessagesOnlyFrom @{Add='<user1>','<user2>'}
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

**Fix:** Record the policy's settings, remove the policy, upgrade your lists,
then recreate the policy if you still need it.

```powershell
Get-EmailAddressPolicy | Format-List Name, Priority, EnabledEmailAddressTemplates, EnabledPrimarySMTPAddressTemplate > email-address-policies.txt
Remove-EmailAddressPolicy -Identity '<policy>'
```

After the upgrades are done:

```powershell
New-EmailAddressPolicy -Name '<policy>' -IncludeUnifiedGroupRecipients -EnabledEmailAddressTemplates 'SMTP:@<domain>' -Priority 1
```

**Watch out:** This affects the whole tenant. While the policy is gone, new
Microsoft 365 groups get addresses in the default domain instead of the
policy's domain. Coordinate with whoever owns the tenant's group naming and
addressing, and keep the gap short.

## Undocumented block

**Why:** Microsoft's own check (`Get-EligibleDistributionGroupForMigration`)
says the list isn't eligible, but none of the documented blockers apply.

**Fix:** Try these in order:

1. If someone already tried to upgrade this list and the attempt stalled or
   failed, clear the in-progress migration flag, then retry the upgrade:
   `Set-DistributionGroup -Identity '<DL>' -ResetMigrationToUnifiedGroup`
2. Wait an hour and re-run the script. Recent changes may not have replicated.
3. Open a Microsoft support case. Include the script's output, which shows
   every documented condition was checked.
