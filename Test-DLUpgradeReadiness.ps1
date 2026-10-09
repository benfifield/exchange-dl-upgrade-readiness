<#
.SYNOPSIS
    Explains why a distribution list can't be upgraded to a Microsoft 365 group.

.DESCRIPTION
    Evaluates one distribution list against every upgrade blocker documented in
    Microsoft KB 4481100 ("Can't upgrade distribution lists to Microsoft 365
    Groups") and prints each blocker found, naming the offending members, groups,
    mailboxes or policies. Also runs Microsoft's own
    Get-EligibleDistributionGroupForMigration as a cross-check.

    The script is read-only. It signs in to Exchange Online interactively if no
    session is already open, and disconnects only a session it opened itself.

    A bare run shows only the report. Result objects are written to the
    pipeline when the output is piped, or always with -PassThru:
        .\Test-DLUpgradeReadiness.ps1 sales@contoso.com | Export-Csv report.csv

.PARAMETER Identity
    The distribution list to evaluate: email address, alias, name or GUID.

.PARAMETER PassThru
    Always write result objects to the pipeline, e.g. when assigning the output
    to a variable. Piped output does not need this switch.

.EXAMPLE
    .\Test-DLUpgradeReadiness.ps1 -Identity sales@contoso.com

.EXAMPLE
    $r = .\Test-DLUpgradeReadiness.ps1 -Identity sales@contoso.com -PassThru

.LINK
    https://learn.microsoft.com/troubleshoot/exchange/groups-and-distribution-lists/cannot-upgrade-distribution-lists-to-office-365-groups
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'New-CheckResult is called positionally to keep check lines compact.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Identity,

    [switch]$PassThru
)

Set-StrictMode -Version Latest

$SupportedMemberTypes = @('UserMailbox', 'SharedMailbox', 'TeamMailbox', 'MailUser')
$GroupMemberTypes = @(
    'MailUniversalDistributionGroup', 'MailUniversalSecurityGroup', 'MailNonUniversalGroup',
    'DynamicDistributionGroup', 'GroupMailbox', 'RoomList'
)
$SupportedOwnerTypes = @('UserMailbox', 'MailUser')
$MaxOwners = 100
$ResolutionGuide = 'RESOLVING.md'

# One-line fix per RESOLVING.md section. Keys must match that file's "## " headings.
$Resolutions = [ordered]@{
    'Security group'             = "Mail-enabled security groups can't be upgraded. Create a new Microsoft 365 group and move the membership."
    'Dynamic distribution group' = "Dynamic distribution groups can't be upgraded. Create a Microsoft 365 group (dynamic membership needs Entra ID P1)."
    'Room list'                  = "Room lists can't be upgraded or converted back. Keep the room list; create a separate Microsoft 365 group if needed."
    'Unsupported group type'     = "Only cloud distribution lists can be upgraded. Create a new Microsoft 365 group instead."
    'Synced from on-premises'    = 'Move the group''s source of authority to the cloud (Entra group SOA), or recreate it as a cloud distribution list.'
    'No owner'                   = 'Set-DistributionGroup -Identity <DL> -ManagedBy @{Add="<owner>"}'
    'Too many owners'            = 'Set-DistributionGroup -Identity <DL> -ManagedBy @{Remove="<owner1>","<owner2>"} until 100 or fewer remain.'
    'Unsupported owner types'    = 'Add a user mailbox or mail user as owner if none remain, then Set-DistributionGroup -Identity <DL> -ManagedBy @{Remove="<owner>"} for each owner listed.'
    'No members'                 = 'Add-DistributionGroupMember -Identity <DL> -Member <user>'
    'Child groups'               = 'Add the child group''s members directly, then Remove-DistributionGroupMember -Identity <DL> -Member <child group>'
    'Unsupported member types'   = 'Remove-DistributionGroupMember -Identity <DL> -Member <member>. Re-add external people as guests after the upgrade.'
    'Member of other groups'     = 'Remove-DistributionGroupMember -Identity <parent group> -Member <DL> for each parent listed.'
    'Shared mailbox forwarding'  = 'Set-Mailbox -Identity <shared mailbox> -ForwardingAddress $null for each mailbox listed. Re-point forwarding after the upgrade.'
    'Sender restriction'         = 'Set-DistributionGroup -Identity <other DL> -AcceptMessagesOnlyFromDLMembers @{Remove="<DL>"} for each DL listed.'
    'Alias special characters'   = 'Set-DistributionGroup -Identity <DL> -Alias <new alias using only letters, digits, . - _>'
    'Email address policy'       = 'Record the policy settings, then Remove-EmailAddressPolicy -Identity <policy>. Affects the whole tenant.'
    'Undocumented block'         = 'If an earlier upgrade attempt stalled, run Set-DistributionGroup -Identity <DL> -ResetMigrationToUnifiedGroup. Otherwise open a Microsoft support case.'
}

function New-CheckResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Blocked', 'Warning', 'Error', 'Info', 'NotApplicable')]
        [string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [string[]]$Items = @(),
        [string]$Guide = ''
    )
    if ($Guide -and -not $Resolutions.Contains($Guide)) { throw "Unknown resolution guide section '$Guide'." }
    [pscustomobject]@{
        Check      = $Check
        Status     = $Status
        Detail     = $Detail
        Items      = $Items
        Resolution = if ($Guide) { $Resolutions[$Guide] } else { '' }
        Guide      = if ($Guide) { "$ResolutionGuide > $Guide" } else { '' }
    }
}

function New-Blocker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$Guide,
        [string[]]$Items = @()
    )
    New-CheckResult -Check $Check -Status 'Blocked' -Detail $Detail -Items $Items -Guide $Guide
}

function ConvertTo-OpathLiteral {
    param([Parameter(Mandatory)][string]$Value)
    $Value -replace "'", "''"
}

function Format-Recipient {
    param($Recipient)
    "$($Recipient.DisplayName) <$($Recipient.PrimarySmtpAddress)>"
}

function Test-IdentityMatch {
    # True when any value of a (possibly multi-valued) property refers to the
    # target group by DN, GUID or name. Used only by fallback scans.
    param($Value, [string[]]$TargetIds)
    foreach ($v in @($Value)) {
        if ($null -ne $v -and $TargetIds -contains "$v") { return $true }
    }
    $false
}

function Invoke-FilteredQuery {
    # Runs an Exchange cmdlet with a server-side OPATH filter. If the tenant
    # rejects the property as unfilterable, warns and falls back to a full scan
    # filtered locally with $Fallback.
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][scriptblock]$Fallback,
        [hashtable]$Parameters = @{}
    )
    try {
        & $Command @Parameters -Filter $Filter -ResultSize Unlimited -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -notmatch 'not a recognized filterable property') { throw }
        Write-Warning "$Command rejected filter [$Filter]. Falling back to a full scan; this may be slow in large tenants."
        & $Command @Parameters -ResultSize Unlimited -ErrorAction Stop | Where-Object $Fallback
    }
}

function Invoke-Check {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    try {
        & $ScriptBlock
    }
    catch {
        New-CheckResult -Check $Check -Status 'Error' -Detail "Check failed: $($_.Exception.Message)"
    }
}

function Test-GroupType {
    param([Parameter(Mandatory)][string]$RecipientTypeDetails)
    $check = 'Group type'
    switch ($RecipientTypeDetails) {
        'MailUniversalDistributionGroup' {
            New-CheckResult $check 'Pass' 'Distribution list.'
        }
        'MailUniversalSecurityGroup' {
            New-Blocker $check 'Is a mail-enabled security group. Only distribution lists can be upgraded.' 'Security group'
        }
        'DynamicDistributionGroup' {
            New-Blocker $check 'Is a dynamic distribution group. Only distribution lists can be upgraded.' 'Dynamic distribution group'
        }
        'RoomList' {
            New-Blocker $check 'Was converted to a room list.' 'Room list'
        }
        'GroupMailbox' {
            New-CheckResult $check 'NotApplicable' 'Is already a Microsoft 365 group.'
        }
        default {
            New-Blocker $check "Is not a cloud distribution list (RecipientTypeDetails: $RecipientTypeDetails)." 'Unsupported group type'
        }
    }
}

function Test-DirSync {
    param([Parameter(Mandatory)][bool]$IsDirSynced)
    if ($IsDirSynced) {
        New-Blocker 'Cloud managed' 'Is synced from on-premises Active Directory. Only cloud-managed lists can be upgraded.' 'Synced from on-premises'
    }
    else {
        New-CheckResult 'Cloud managed' 'Pass' 'Managed in the cloud.'
    }
}

function Test-OwnerCount {
    param([AllowEmptyCollection()][string[]]$ManagedBy = @())
    $count = @($ManagedBy | Where-Object { $_ }).Count
    if ($count -eq 0) {
        New-Blocker 'Owners' 'Has no owner (ManagedBy is empty). Assign at least one owner.' 'No owner'
    }
    elseif ($count -gt $MaxOwners) {
        New-Blocker 'Owners' "Has $count owners; the maximum is $MaxOwners." 'Too many owners'
    }
    else {
        New-CheckResult 'Owners' 'Pass' "Has $count owner(s)."
    }
}

function Test-OwnerType {
    # Owners with no recipient object (for example, users without a mailbox)
    # can't own a Microsoft 365 group. Emits nothing when there are no owners;
    # Test-OwnerCount already blocks that case.
    param([AllowEmptyCollection()][string[]]$ManagedBy = @())
    $owners = @($ManagedBy | Where-Object { $_ })
    if (-not $owners.Count) { return }
    $unsupported = foreach ($owner in $owners) {
        try {
            $r = Get-Recipient -Identity $owner -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -notmatch "couldn't be found") { throw }
            "$owner [not a mail-enabled recipient]"
            continue
        }
        if ($SupportedOwnerTypes -notcontains $r.RecipientTypeDetails) {
            "$(Format-Recipient $r) [$($r.RecipientTypeDetails)]"
        }
    }
    $unsupported = @($unsupported)
    if ($unsupported.Count) {
        New-Blocker 'Owner types' `
            "Has $($unsupported.Count) owner(s) that aren't $($SupportedOwnerTypes -join ' or '). Replace them." 'Unsupported owner types' `
            -Items $unsupported
    }
    else {
        New-CheckResult 'Owner types' 'Pass' 'All owners are user mailboxes or mail users.'
    }
}

function Test-Membership {
    param([AllowEmptyCollection()][object[]]$Members = @())
    $Members = @($Members | Where-Object { $_ })
    if ($Members.Count -eq 0) {
        return New-Blocker 'Has members' 'Has no members.' 'No members'
    }
    New-CheckResult 'Has members' 'Pass' "Has $($Members.Count) member(s)."

    $childGroups = @($Members | Where-Object { $GroupMemberTypes -contains $_.RecipientTypeDetails })
    if ($childGroups.Count) {
        New-Blocker 'Nested: child groups' "Contains $($childGroups.Count) group(s) as members. Remove them." 'Child groups' `
            -Items ($childGroups | ForEach-Object { "$(Format-Recipient $_) [$($_.RecipientTypeDetails)]" })
    }
    else {
        New-CheckResult 'Nested: child groups' 'Pass' 'Contains no groups.'
    }

    $unsupported = @($Members | Where-Object {
            $SupportedMemberTypes -notcontains $_.RecipientTypeDetails -and
            $GroupMemberTypes -notcontains $_.RecipientTypeDetails
        })
    if ($unsupported.Count) {
        New-Blocker 'Member types' `
            "Has $($unsupported.Count) member(s) that aren't $($SupportedMemberTypes -join ', '). Remove them." 'Unsupported member types' `
            -Items ($unsupported | ForEach-Object { "$(Format-Recipient $_) [$($_.RecipientTypeDetails)]" })
    }
    else {
        New-CheckResult 'Member types' 'Pass' 'All non-group members are supported types.'
    }
}

function Test-ParentGroup {
    param(
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string[]]$TargetIds = @()
    )
    $ids = @($DistinguishedName) + $TargetIds
    $fallback = {
        $members = Get-DistributionGroupMember -Identity $_.Guid.ToString() -ResultSize Unlimited -ErrorAction Stop
        Test-IdentityMatch -Value @($members | ForEach-Object { $_.DistinguishedName; $_.Guid }) -TargetIds $ids
    }.GetNewClosure()
    $parents = @(Invoke-FilteredQuery -Command 'Get-DistributionGroup' `
            -Filter "Members -eq '$(ConvertTo-OpathLiteral $DistinguishedName)'" -Fallback $fallback)
    if ($parents.Count) {
        New-Blocker 'Nested: member of other groups' "Is a member of $($parents.Count) other group(s). Remove it from them." 'Member of other groups' `
            -Items ($parents | ForEach-Object { Format-Recipient $_ })
    }
    else {
        New-CheckResult 'Nested: member of other groups' 'Pass' 'Is not a member of any other group.'
    }
}

function Test-SharedMailboxForwarding {
    param(
        [Parameter(Mandatory)][string]$DistinguishedName,
        [string[]]$TargetIds = @()
    )
    $ids = @($DistinguishedName) + $TargetIds
    $fallback = { Test-IdentityMatch -Value $_.ForwardingAddress -TargetIds $ids }.GetNewClosure()
    $mailboxes = @(Invoke-FilteredQuery -Command 'Get-Mailbox' -Parameters @{ RecipientTypeDetails = 'SharedMailbox' } `
            -Filter "ForwardingAddress -eq '$(ConvertTo-OpathLiteral $DistinguishedName)'" -Fallback $fallback)
    if ($mailboxes.Count) {
        New-Blocker 'Shared mailbox forwarding' "Is the forwarding address of $($mailboxes.Count) shared mailbox(es). Change their forwarding." 'Shared mailbox forwarding' `
            -Items ($mailboxes | ForEach-Object { Format-Recipient $_ })
    }
    else {
        New-CheckResult 'Shared mailbox forwarding' 'Pass' 'No shared mailbox forwards to it.'
    }
}

function Test-SenderRestriction {
    param(
        [Parameter(Mandatory)][string]$DistinguishedName,
        [Parameter(Mandatory)][guid]$Guid,
        [string[]]$TargetIds = @()
    )
    $ids = @($DistinguishedName, $Guid.ToString()) + $TargetIds
    $fallback = { Test-IdentityMatch -Value $_.AcceptMessagesOnlyFromDLMembers -TargetIds $ids }.GetNewClosure()
    $groups = @(Invoke-FilteredQuery -Command 'Get-DistributionGroup' `
            -Filter "AcceptMessagesOnlyFromDLMembers -eq '$(ConvertTo-OpathLiteral $DistinguishedName)'" -Fallback $fallback |
            Where-Object { $_.Guid -ne $Guid })
    if ($groups.Count) {
        New-Blocker 'Sender restriction in other DLs' `
            "Is an allowed sender in the delivery restrictions of $($groups.Count) other distribution list(s). Remove it from their restrictions." 'Sender restriction' `
            -Items ($groups | ForEach-Object { Format-Recipient $_ })
    }
    else {
        New-CheckResult 'Sender restriction in other DLs' 'Pass' 'Not used in any other distribution list''s sender restrictions.'
    }
}

function Test-AliasCharacter {
    param([Parameter(Mandatory)][string]$Alias)
    $bad = @($Alias.ToCharArray() | Where-Object { "$_" -cnotmatch '^[A-Za-z0-9._-]$' } | Select-Object -Unique)
    if ($bad.Count) {
        $shown = $bad | ForEach-Object { if ($_ -eq ' ') { "' ' (space)" } else { "'$_'" } }
        New-Blocker 'Alias characters' "Alias '$Alias' contains special characters. Use only letters, digits, '.', '-' and '_'." 'Alias special characters' `
            -Items $shown
    }
    else {
        New-CheckResult 'Alias characters' 'Pass' "Alias '$Alias' has no special characters."
    }
}

function Test-GroupEmailAddressPolicy {
    # In Exchange Online, new email address policies apply only to Microsoft 365
    # groups. Every tenant also has the built-in legacy 'Default Policy' at
    # priority Lowest, which doesn't block upgrades and can't be removed. Custom
    # policies always get a numeric priority, so both conditions must match.
    $policies = @(Get-EmailAddressPolicy -ErrorAction Stop | Where-Object {
            $_ -and -not ("$($_.Priority)" -eq 'Lowest' -and $_.Name -eq 'Default Policy')
        })
    if ($policies.Count) {
        New-Blocker 'Tenant: group email address policy' `
            'TENANT-WIDE: a custom email address policy applies to Microsoft 365 groups. This blocks every DL upgrade; remove the policy.' 'Email address policy' `
            -Items ($policies | ForEach-Object Name)
    }
    else {
        New-CheckResult 'Tenant: group email address policy' 'Pass' 'No custom email address policy targets Microsoft 365 groups.'
    }
}

function Test-MicrosoftEligibility {
    param(
        # Must never be empty: an empty -Identity makes the cmdlet return every DL.
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrimarySmtpAddress,
        [Parameter(Mandatory)][int]$BlockerCount
    )
    $check = 'Microsoft eligibility check'
    $eligible = @(Get-EligibleDistributionGroupForMigration -Identity $PrimarySmtpAddress -ErrorAction Stop).Count -gt 0
    if ($eligible -and $BlockerCount -eq 0) {
        New-CheckResult $check 'Info' 'Microsoft reports this list as eligible for upgrade.'
    }
    elseif (-not $eligible -and $BlockerCount -gt 0) {
        New-CheckResult $check 'Info' 'Microsoft reports this list as not eligible, consistent with the blockers above.'
    }
    elseif (-not $eligible) {
        New-CheckResult $check 'Warning' 'Microsoft reports this list as not eligible, but no documented blocker was found. It may be blocked for an undocumented reason.' `
            -Guide 'Undocumented block'
    }
    else {
        New-CheckResult $check 'Warning' "Microsoft reports this list as eligible, but $BlockerCount documented blocker(s) were found. Treat the blockers above as likely upgrade failures."
    }
}

function Get-DLUpgradeReadiness {
    param([Parameter(Mandatory)][string]$Identity)

    $recipient = Get-Recipient -Identity $Identity -ErrorAction Stop
    $typeResult = Test-GroupType -RecipientTypeDetails $recipient.RecipientTypeDetails
    if ($typeResult.Status -ne 'Pass') {
        return $typeResult
    }

    $group = Get-DistributionGroup -Identity $recipient.Guid.ToString() -ErrorAction Stop
    $dn = $group.DistinguishedName
    $ids = @($group.Guid.ToString(), "$($group.Name)", "$($group.DisplayName)", "$($group.PrimarySmtpAddress)") | Where-Object { $_ }

    $results = [System.Collections.Generic.List[object]]::new()
    $results.Add($typeResult)
    $checks = [ordered]@{
        'Cloud managed'                     = { Test-DirSync -IsDirSynced ([bool]$group.IsDirSynced) }
        'Owners'                            = { Test-OwnerCount -ManagedBy @($group.ManagedBy | ForEach-Object { "$_" }) }
        'Owner types'                       = { Test-OwnerType -ManagedBy @($group.ManagedBy | ForEach-Object { "$_" }) }
        'Members'                           = { Test-Membership -Members @(Get-DistributionGroupMember -Identity $group.Guid.ToString() -ResultSize Unlimited -ErrorAction Stop) }
        'Nested: member of other groups'    = { Test-ParentGroup -DistinguishedName $dn -TargetIds $ids }
        'Shared mailbox forwarding'         = { Test-SharedMailboxForwarding -DistinguishedName $dn -TargetIds $ids }
        'Sender restriction in other DLs'   = { Test-SenderRestriction -DistinguishedName $dn -Guid $group.Guid -TargetIds $ids }
        'Alias characters'                  = { Test-AliasCharacter -Alias $group.Alias }
        'Tenant: group email address policy' = { Test-GroupEmailAddressPolicy }
    }
    foreach ($name in $checks.Keys) {
        foreach ($r in @(Invoke-Check -Check $name -ScriptBlock $checks[$name])) { $results.Add($r) }
    }

    $blockers = @($results | Where-Object Status -EQ 'Blocked').Count
    $results.Add((Invoke-Check -Check 'Microsoft eligibility check' -ScriptBlock {
                Test-MicrosoftEligibility -PrimarySmtpAddress "$($group.PrimarySmtpAddress)" -BlockerCount $blockers
            }))
    $results
}

function Write-CheckReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Colored console report; results also go to the pipeline.')]
    param(
        [Parameter(Mandatory)]$Recipient,
        [Parameter(Mandatory)][object[]]$Results
    )
    $style = @{
        Pass          = @('PASS', 'Green')
        Blocked       = @('BLOCKED', 'Red')
        Warning       = @('WARN', 'Yellow')
        Error         = @('ERROR', 'Magenta')
        Info          = @('INFO', 'Cyan')
        NotApplicable = @('N/A', 'Gray')
    }
    Write-Host ''
    Write-Host "Distribution list: $($Recipient.DisplayName) <$($Recipient.PrimarySmtpAddress)>" -ForegroundColor White
    Write-Host "GUID:              $($Recipient.Guid)" -ForegroundColor White
    Write-Host ''
    foreach ($r in $Results) {
        $label, $color = $style[$r.Status]
        Write-Host ('[{0,-7}] ' -f $label) -ForegroundColor $color -NoNewline
        Write-Host "$($r.Check): $($r.Detail)"
        foreach ($item in $r.Items) { Write-Host "            - $item" -ForegroundColor $color }
        if ($r.Resolution) {
            Write-Host "            Fix: $($r.Resolution)" -ForegroundColor White
            Write-Host "            See: $($r.Guide)" -ForegroundColor DarkGray
        }
    }

    $blockers = @($Results | Where-Object Status -EQ 'Blocked')
    $errors = @($Results | Where-Object Status -EQ 'Error')
    Write-Host ''
    if ($blockers.Count) {
        Write-Host "$($blockers.Count) blocker(s) found. Fix every BLOCKED item above ($ResolutionGuide has step-by-step instructions), re-run this script, then retry the upgrade." -ForegroundColor Red
    }
    elseif (@($Results | Where-Object Status -EQ 'NotApplicable').Count) {
        Write-Host 'Nothing to upgrade.' -ForegroundColor Gray
    }
    else {
        Write-Host 'No documented blockers found.' -ForegroundColor Green
    }
    if ($errors.Count) {
        Write-Host "$($errors.Count) check(s) could not run; results are incomplete." -ForegroundColor Magenta
    }
    Write-Host ''
}

# --- Main (skipped when dot-sourced, e.g. by the Pester tests) ---
if ($MyInvocation.InvocationName -ne '.') {
    # Checked at runtime, not with #Requires, so tests can dot-source without the module.
    # 3.0.0 is the first version with Get-ConnectionInformation.
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement | Where-Object Version -GE '3.0.0')) {
        throw 'ExchangeOnlineManagement 3.0.0 or later is required. See https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2#install-and-update-the-exchange-online-powershell-module'
    }
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.0.0 -ErrorAction Stop

    $openedSession = $false
    if (-not @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object State -EQ 'Connected').Count) {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        $openedSession = $true
    }
    try {
        $recipient = Get-Recipient -Identity $Identity -ErrorAction Stop
        $results = @(Get-DLUpgradeReadiness -Identity $recipient.Guid.ToString())
        Write-CheckReport -Recipient $recipient -Results $results
        # Emit objects only when a caller consumes them; a bare run shows just the report.
        if ($PassThru -or $MyInvocation.PipelinePosition -lt $MyInvocation.PipelineLength) {
            $results
        }
    }
    finally {
        if ($openedSession) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
    }
}
