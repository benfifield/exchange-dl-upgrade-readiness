#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    # Guide section names drive data-driven tests, so load them at discovery time.
    . (Join-Path $PSScriptRoot '..\Test-DLUpgradeReadiness.ps1') -Identity 'dot-source'
    $GuideSections = @($Resolutions.Keys)
}

BeforeAll {
    # Stub Exchange Online cmdlets so tests run without the module or a tenant.
    function Get-Recipient { param($Identity, $Filter, $ResultSize, $ErrorAction) }
    function Get-DistributionGroup { param($Identity, $Filter, $ResultSize, $ErrorAction) }
    function Get-DistributionGroupMember { param($Identity, $ResultSize, $ErrorAction) }
    function Get-Mailbox { param($RecipientTypeDetails, $Filter, $ResultSize, $ErrorAction) }
    function Get-EmailAddressPolicy { param($ErrorAction) }
    function Get-EligibleDistributionGroupForMigration { param($Identity, $ErrorAction) }

    . (Join-Path $PSScriptRoot '..\Test-DLUpgradeReadiness.ps1') -Identity 'dot-source'

    $script:Dn = "CN=Sales,OU=contoso.onmicrosoft.com,OU=Microsoft Exchange Hosted Organizations,DC=NAMPR01A001,DC=PROD,DC=OUTLOOK,DC=COM"
    $script:Guid = [guid]'11111111-1111-1111-1111-111111111111'
}

Describe 'New-CheckResult' {
    It 'builds a result object with all fields' {
        $r = New-CheckResult -Check 'X' -Status 'Pass' -Detail 'ok' -Items @('a')
        $r.Check | Should -Be 'X'
        $r.Status | Should -Be 'Pass'
        $r.Detail | Should -Be 'ok'
        $r.Items | Should -Be @('a')
    }
}

Describe 'ConvertTo-OpathLiteral' {
    It 'doubles single quotes' {
        ConvertTo-OpathLiteral "CN=O'Brien,DC=x" | Should -Be "CN=O''Brien,DC=x"
    }
}

Describe 'Test-GroupType' {
    It 'passes a MailUniversalDistributionGroup' {
        (Test-GroupType -RecipientTypeDetails 'MailUniversalDistributionGroup').Status | Should -Be 'Pass'
    }
    It 'blocks <Type>' -ForEach @(
        @{ Type = 'MailUniversalSecurityGroup' }
        @{ Type = 'DynamicDistributionGroup' }
        @{ Type = 'RoomList' }
        @{ Type = 'MailNonUniversalGroup' }
        @{ Type = 'UserMailbox' }
    ) {
        (Test-GroupType -RecipientTypeDetails $Type).Status | Should -Be 'Blocked'
    }
    It 'marks GroupMailbox as NotApplicable' {
        (Test-GroupType -RecipientTypeDetails 'GroupMailbox').Status | Should -Be 'NotApplicable'
    }
}

Describe 'Test-DirSync' {
    It 'blocks a dir-synced group' {
        (Test-DirSync -IsDirSynced $true).Status | Should -Be 'Blocked'
    }
    It 'passes a cloud group' {
        (Test-DirSync -IsDirSynced $false).Status | Should -Be 'Pass'
    }
}

Describe 'Test-OwnerCount' {
    It 'blocks when there are no owners' {
        (Test-OwnerCount -ManagedBy @()).Status | Should -Be 'Blocked'
    }
    It 'blocks when there are more than 100 owners' {
        (Test-OwnerCount -ManagedBy (1..101 | ForEach-Object { "owner$_" })).Status | Should -Be 'Blocked'
    }
    It 'passes with exactly 100 owners' {
        (Test-OwnerCount -ManagedBy (1..100 | ForEach-Object { "owner$_" })).Status | Should -Be 'Pass'
    }
    It 'passes with one owner' {
        (Test-OwnerCount -ManagedBy @('alice')).Status | Should -Be 'Pass'
    }
}

Describe 'Test-OwnerType' {
    BeforeAll {
        $script:OwnerTypes = @{ alice = 'UserMailbox'; bob = 'MailUser'; helpdesk = 'SharedMailbox'; admins = 'MailUniversalSecurityGroup' }
        Mock Get-Recipient {
            if (-not $script:OwnerTypes.Contains($Identity)) {
                throw "The operation couldn't be performed because object '$Identity' couldn't be found on 'NAMPR01A001.PROD.OUTLOOK.COM'."
            }
            [pscustomobject]@{ DisplayName = $Identity; PrimarySmtpAddress = "$Identity@contoso.com"; RecipientTypeDetails = $script:OwnerTypes[$Identity] }
        }
    }
    It 'passes when every owner is a user mailbox or mail user' {
        (Test-OwnerType -ManagedBy @('alice', 'bob')).Status | Should -Be 'Pass'
    }
    It 'blocks owners of other recipient types and lists them' {
        $r = Test-OwnerType -ManagedBy @('alice', 'helpdesk', 'admins')
        $r.Status | Should -Be 'Blocked'
        $r.Items | Should -HaveCount 2
        $r.Items[0] | Should -Match 'helpdesk.*SharedMailbox'
        $r.Items[1] | Should -Match 'admins.*MailUniversalSecurityGroup'
    }
    It 'blocks an owner that is not a mail-enabled recipient' {
        $r = Test-OwnerType -ManagedBy @('alice', 'nomailbox')
        $r.Status | Should -Be 'Blocked'
        $r.Items[0] | Should -Match 'nomailbox.*not a mail-enabled recipient'
    }
    It 'rethrows other lookup errors' {
        Mock Get-Recipient { throw 'access denied' }
        { Test-OwnerType -ManagedBy @('alice') } | Should -Throw '*access denied*'
    }
    It 'returns nothing when there are no owners' {
        Test-OwnerType -ManagedBy @() | Should -BeNullOrEmpty
    }
}

Describe 'Test-Membership' {
    BeforeAll {
        function New-Member($Name, $Type) {
            [pscustomobject]@{ DisplayName = $Name; PrimarySmtpAddress = "$Name@contoso.com"; RecipientTypeDetails = $Type }
        }
    }
    It 'blocks an empty group' {
        $r = Test-Membership -Members @()
        $r | Should -HaveCount 1
        $r.Check | Should -Be 'Has members'
        $r.Status | Should -Be 'Blocked'
    }
    It 'passes when all members are supported types' {
        $m = @(
            New-Member 'a' 'UserMailbox'
            New-Member 'b' 'SharedMailbox'
            New-Member 'c' 'TeamMailbox'
            New-Member 'd' 'MailUser'
        )
        $r = Test-Membership -Members $m
        $r | ForEach-Object { $_.Status | Should -Be 'Pass' }
    }
    It 'blocks unsupported non-group member types and lists them' {
        $m = @((New-Member 'a' 'UserMailbox'), (New-Member 'contact' 'MailContact'))
        $r = Test-Membership -Members $m | Where-Object Check -EQ 'Member types'
        $r.Status | Should -Be 'Blocked'
        $r.Items | Should -HaveCount 1
        $r.Items[0] | Should -Match 'contact.*MailContact'
    }
    It 'blocks child groups as nesting, not as member types' {
        $m = @((New-Member 'a' 'UserMailbox'), (New-Member 'child' 'MailUniversalDistributionGroup'))
        $r = Test-Membership -Members $m
        ($r | Where-Object Check -EQ 'Nested: child groups').Status | Should -Be 'Blocked'
        ($r | Where-Object Check -EQ 'Nested: child groups').Items[0] | Should -Match 'child'
        ($r | Where-Object Check -EQ 'Member types').Status | Should -Be 'Pass'
    }
}

Describe 'Invoke-FilteredQuery' {
    It 'returns filtered results directly when the filter works' {
        Mock Get-Recipient { @([pscustomobject]@{ Name = 'hit' }) }
        $r = Invoke-FilteredQuery -Command 'Get-Recipient' -Filter "Members -eq 'x'" -Fallback { $true }
        $r.Name | Should -Be 'hit'
        Should -Invoke Get-Recipient -Times 1 -ParameterFilter { $Filter -eq "Members -eq 'x'" }
    }
    It 'falls back to a full scan when the property is not filterable' {
        Mock Get-Recipient { throw "'Members' is not a recognized filterable property." } -ParameterFilter { $Filter }
        Mock Get-Recipient { @([pscustomobject]@{ Name = 'keep' }, [pscustomobject]@{ Name = 'drop' }) } -ParameterFilter { -not $Filter }
        $r = Invoke-FilteredQuery -Command 'Get-Recipient' -Filter "Members -eq 'x'" -Fallback { $_.Name -eq 'keep' } -WarningAction SilentlyContinue
        $r | Should -HaveCount 1
        $r.Name | Should -Be 'keep'
    }
    It 'rethrows other errors' {
        Mock Get-Recipient { throw 'access denied' }
        { Invoke-FilteredQuery -Command 'Get-Recipient' -Filter 'x' -Fallback { $true } } | Should -Throw '*access denied*'
    }
}

Describe 'Test-ParentGroup' {
    It 'blocks when the group is a member of another group' {
        Mock Get-DistributionGroup { @([pscustomobject]@{ DisplayName = 'All Staff'; PrimarySmtpAddress = 'all@contoso.com' }) }
        $r = Test-ParentGroup -DistinguishedName $script:Dn
        $r.Status | Should -Be 'Blocked'
        $r.Items[0] | Should -Match 'All Staff'
        Should -Invoke Get-DistributionGroup -ParameterFilter { $Filter -like 'Members -eq *' }
    }
    It 'finds parent groups in the fallback scan' {
        # Regression: fallbacks built with .GetNewClosure() couldn't call Test-IdentityMatch.
        Mock Get-DistributionGroup { throw "'Members' is not a recognized filterable property." } -ParameterFilter { $Filter }
        $allStaff = [guid]'22222222-2222-2222-2222-222222222222'
        Mock Get-DistributionGroup { @(
            [pscustomobject]@{ DisplayName = 'All Staff'; PrimarySmtpAddress = 'all@contoso.com'; Guid = $allStaff }
            [pscustomobject]@{ DisplayName = 'Unrelated'; PrimarySmtpAddress = 'other@contoso.com'; Guid = [guid]'33333333-3333-3333-3333-333333333333' }
        ) } -ParameterFilter { -not $Filter }
        Mock Get-DistributionGroupMember { [pscustomobject]@{ DistinguishedName = $script:Dn; Guid = $script:Guid } } -ParameterFilter { $Identity -eq $allStaff.ToString() }
        Mock Get-DistributionGroupMember { [pscustomobject]@{ DistinguishedName = 'CN=Someone'; Guid = [guid]::NewGuid() } } -ParameterFilter { $Identity -ne $allStaff.ToString() }
        $r = Test-ParentGroup -DistinguishedName $script:Dn -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Blocked'
        $r.Items | Should -HaveCount 1
        $r.Items[0] | Should -Match 'All Staff'
    }
    It 'passes when no parent groups exist' {
        Mock Get-DistributionGroup { }
        (Test-ParentGroup -DistinguishedName $script:Dn).Status | Should -Be 'Pass'
    }
}

Describe 'Test-SharedMailboxForwarding' {
    It 'blocks when a shared mailbox forwards to the group' {
        Mock Get-Mailbox { @([pscustomobject]@{ DisplayName = 'Help Desk'; PrimarySmtpAddress = 'help@contoso.com' }) }
        $r = Test-SharedMailboxForwarding -DistinguishedName $script:Dn
        $r.Status | Should -Be 'Blocked'
        $r.Items[0] | Should -Match 'Help Desk'
        Should -Invoke Get-Mailbox -ParameterFilter { $RecipientTypeDetails -eq 'SharedMailbox' -and $Filter -like 'ForwardingAddress -eq *' }
    }
    It 'passes when nothing forwards to the group' {
        Mock Get-Mailbox { }
        (Test-SharedMailboxForwarding -DistinguishedName $script:Dn).Status | Should -Be 'Pass'
    }
}

Describe 'Test-SenderRestriction' {
    It 'blocks when another DL only accepts mail from this group' {
        Mock Get-DistributionGroup { @([pscustomobject]@{ DisplayName = 'Execs'; PrimarySmtpAddress = 'execs@contoso.com'; Guid = [guid]::NewGuid() }) }
        $r = Test-SenderRestriction -DistinguishedName $script:Dn -Guid $script:Guid
        $r.Status | Should -Be 'Blocked'
        $r.Items[0] | Should -Match 'Execs'
        Should -Invoke Get-DistributionGroup -ParameterFilter { $Filter -like 'AcceptMessagesOnlyFromDLMembers -eq *' }
    }
    It 'finds restricting DLs in the fallback scan' {
        Mock Get-DistributionGroup { throw "'AcceptMessagesOnlyFromDLMembers' is not a recognized filterable property." } -ParameterFilter { $Filter }
        Mock Get-DistributionGroup { @(
            [pscustomobject]@{ DisplayName = 'Execs'; PrimarySmtpAddress = 'execs@contoso.com'; Guid = [guid]::NewGuid(); AcceptMessagesOnlyFromDLMembers = @($script:Dn) }
            [pscustomobject]@{ DisplayName = 'Open'; PrimarySmtpAddress = 'open@contoso.com'; Guid = [guid]::NewGuid(); AcceptMessagesOnlyFromDLMembers = @() }
        ) } -ParameterFilter { -not $Filter }
        $r = Test-SenderRestriction -DistinguishedName $script:Dn -Guid $script:Guid -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Blocked'
        $r.Items | Should -HaveCount 1
        $r.Items[0] | Should -Match 'Execs'
    }
    It 'ignores the group restricting itself' {
        Mock Get-DistributionGroup { @([pscustomobject]@{ DisplayName = 'Sales'; PrimarySmtpAddress = 'sales@contoso.com'; Guid = $script:Guid }) }
        (Test-SenderRestriction -DistinguishedName $script:Dn -Guid $script:Guid).Status | Should -Be 'Pass'
    }
    It 'passes when no DL references the group' {
        Mock Get-DistributionGroup { }
        (Test-SenderRestriction -DistinguishedName $script:Dn -Guid $script:Guid).Status | Should -Be 'Pass'
    }
}

Describe 'Test-AliasCharacter' {
    It 'passes <Alias>' -ForEach @(
        @{ Alias = 'sales' }
        @{ Alias = 'Sales.Team-2_EU' }
    ) {
        (Test-AliasCharacter -Alias $Alias).Status | Should -Be 'Pass'
    }
    It 'blocks <Alias> and reports offending characters' -ForEach @(
        @{ Alias = 'sales&marketing'; Bad = '&' }
        @{ Alias = 'sales team'; Bad = ' ' }
        @{ Alias = "o'brien#1"; Bad = "'" }
        @{ Alias = "caf$([char]0xE9)"; Bad = [string][char]0xE9 }
    ) {
        $r = Test-AliasCharacter -Alias $Alias
        $r.Status | Should -Be 'Blocked'
        $r.Items -join '' | Should -BeLike "*$Bad*"
    }
}

Describe 'Test-GroupEmailAddressPolicy' {
    # In Exchange Online every email address policy is a Microsoft 365 groups
    # policy, and the returned objects have no IncludeUnifiedGroupRecipients property.
    It 'blocks when any email address policy exists' {
        Mock Get-EmailAddressPolicy { @(
            [pscustomobject]@{ Name = 'Groups'; Priority = 1; EnabledPrimarySMTPAddressTemplate = '@groups.contoso.com' }
        ) }
        $r = Test-GroupEmailAddressPolicy
        $r.Status | Should -Be 'Blocked'
        $r.Items[0] | Should -Match 'Groups'
    }
    It 'passes when no email address policy exists' {
        Mock Get-EmailAddressPolicy { }
        (Test-GroupEmailAddressPolicy).Status | Should -Be 'Pass'
    }
    # Every tenant has the built-in legacy 'Default Policy' at priority Lowest.
    It 'ignores the built-in Default Policy' {
        Mock Get-EmailAddressPolicy { @(
            [pscustomobject]@{ Name = 'Default Policy'; Priority = 'Lowest'; EnabledPrimarySMTPAddressTemplate = '@contoso.onmicrosoft.com' }
        ) }
        (Test-GroupEmailAddressPolicy).Status | Should -Be 'Pass'
    }
    It 'blocks on a custom policy alongside the Default Policy and lists only the custom one' {
        Mock Get-EmailAddressPolicy { @(
            [pscustomobject]@{ Name = 'Groups'; Priority = 1; EnabledPrimarySMTPAddressTemplate = '@groups.contoso.com' }
            [pscustomobject]@{ Name = 'Default Policy'; Priority = 'Lowest'; EnabledPrimarySMTPAddressTemplate = '@contoso.onmicrosoft.com' }
        ) }
        $r = Test-GroupEmailAddressPolicy
        $r.Status | Should -Be 'Blocked'
        $r.Items | Should -HaveCount 1
        $r.Items[0] | Should -Match 'Groups'
    }
    It 'blocks on a custom policy named Default Policy' {
        Mock Get-EmailAddressPolicy { @(
            [pscustomobject]@{ Name = 'Default Policy'; Priority = 1; EnabledPrimarySMTPAddressTemplate = '@groups.contoso.com' }
        ) }
        (Test-GroupEmailAddressPolicy).Status | Should -Be 'Blocked'
    }
}

Describe 'Test-MicrosoftEligibility' {
    It 'is Info when Microsoft says eligible and no blockers' {
        Mock Get-EligibleDistributionGroupForMigration { [pscustomobject]@{ PrimarySmtpAddress = 'sales@contoso.com' } }
        (Test-MicrosoftEligibility -PrimarySmtpAddress 'sales@contoso.com' -BlockerCount 0).Status | Should -Be 'Info'
    }
    It 'is Info when Microsoft says ineligible and blockers were found' {
        Mock Get-EligibleDistributionGroupForMigration { }
        (Test-MicrosoftEligibility -PrimarySmtpAddress 'sales@contoso.com' -BlockerCount 2).Status | Should -Be 'Info'
    }
    It 'warns of an undocumented reason when ineligible with no blockers' {
        Mock Get-EligibleDistributionGroupForMigration { }
        $r = Test-MicrosoftEligibility -PrimarySmtpAddress 'sales@contoso.com' -BlockerCount 0
        $r.Status | Should -Be 'Warning'
        $r.Detail | Should -Match 'undocumented'
    }
    It 'warns of disagreement when eligible but blockers were found' {
        Mock Get-EligibleDistributionGroupForMigration { [pscustomobject]@{ PrimarySmtpAddress = 'sales@contoso.com' } }
        (Test-MicrosoftEligibility -PrimarySmtpAddress 'sales@contoso.com' -BlockerCount 1).Status | Should -Be 'Warning'
    }
    It 'refuses an empty address (would return every DL)' {
        { Test-MicrosoftEligibility -PrimarySmtpAddress '' -BlockerCount 0 } | Should -Throw
    }
}

Describe 'Invoke-Check' {
    It 'converts a thrown error into an Error result' {
        $r = Invoke-Check -Check 'Boom' -ScriptBlock { throw 'kaboom' }
        $r.Check | Should -Be 'Boom'
        $r.Status | Should -Be 'Error'
        $r.Detail | Should -Match 'kaboom'
    }
    It 'passes through results from a successful check' {
        $r = Invoke-Check -Check 'Fine' -ScriptBlock { New-CheckResult -Check 'Fine' -Status 'Pass' -Detail 'ok' }
        $r.Status | Should -Be 'Pass'
    }
}

Describe 'Resolution guidance' {
    BeforeAll {
        $script:GuidePath = Join-Path $PSScriptRoot '..\RESOLVING.md'
        function New-Member($Name, $Type) {
            [pscustomobject]@{ DisplayName = $Name; PrimarySmtpAddress = "$Name@contoso.com"; RecipientTypeDetails = $Type }
        }
    }
    It 'rejects an unknown guide section' {
        { New-CheckResult -Check 'X' -Status 'Blocked' -Detail 'd' -Guide 'No such section' } | Should -Throw '*Unknown resolution guide*'
    }
    It 'gives every blocker a fix and a guide section' {
        $other = [pscustomobject]@{ DisplayName = 'Other'; PrimarySmtpAddress = 'other@contoso.com'; Guid = [guid]::NewGuid() }
        Mock Get-DistributionGroup { $other }
        Mock Get-Mailbox { $other }
        Mock Get-EmailAddressPolicy { [pscustomobject]@{ Name = 'Groups'; Priority = 1 } }
        Mock Get-Recipient { [pscustomobject]@{ DisplayName = 'Help Desk'; PrimarySmtpAddress = 'help@contoso.com'; RecipientTypeDetails = 'SharedMailbox' } }
        $blocked = @(
            'MailUniversalSecurityGroup', 'DynamicDistributionGroup', 'RoomList', 'UserMailbox' |
                ForEach-Object { Test-GroupType -RecipientTypeDetails $_ }
            Test-DirSync -IsDirSynced $true
            Test-OwnerCount -ManagedBy @()
            Test-OwnerCount -ManagedBy (1..101 | ForEach-Object { "o$_" })
            Test-OwnerType -ManagedBy @('helpdesk')
            Test-Membership -Members @()
            Test-Membership -Members @((New-Member 'g' 'MailUniversalDistributionGroup'), (New-Member 'c' 'MailContact'))
            Test-ParentGroup -DistinguishedName $script:Dn
            Test-SharedMailboxForwarding -DistinguishedName $script:Dn
            Test-SenderRestriction -DistinguishedName $script:Dn -Guid $script:Guid
            Test-AliasCharacter -Alias 'a&b'
            Test-GroupEmailAddressPolicy
        ) | Where-Object Status -EQ 'Blocked'
        $blocked | Should -HaveCount 16
        foreach ($b in $blocked) {
            $b.Resolution | Should -Not -BeNullOrEmpty -Because "$($b.Check) is blocked"
            $b.Guide | Should -BeLike 'RESOLVING.md > *'
        }
    }
    It 'gives the undocumented-block warning a fix' {
        Mock Get-EligibleDistributionGroupForMigration { }
        (Test-MicrosoftEligibility -PrimarySmtpAddress 'a@contoso.com' -BlockerCount 0).Resolution | Should -Not -BeNullOrEmpty
    }
    It 'gives passing results no fix' {
        (Test-DirSync -IsDirSynced $false).Resolution | Should -BeNullOrEmpty
        (Test-AliasCharacter -Alias 'ok').Resolution | Should -BeNullOrEmpty
    }
    It 'has a RESOLVING.md heading for guide section <_>' -ForEach $GuideSections {
        $script:GuidePath | Should -Exist
        (Get-Content $script:GuidePath) | Should -Contain "## $_"
    }
}

Describe 'Get-DLUpgradeReadiness' {
    BeforeAll {
        Mock Get-Recipient {
            [pscustomobject]@{ Guid = $script:Guid; RecipientTypeDetails = 'MailUniversalDistributionGroup'; DistinguishedName = $script:Dn }
        } -ParameterFilter { $Identity }
        Mock Get-Recipient {
            [pscustomobject]@{ DisplayName = 'Alice'; PrimarySmtpAddress = 'alice@contoso.com'; RecipientTypeDetails = 'UserMailbox' }
        } -ParameterFilter { $Identity -eq 'alice' }
        Mock Get-DistributionGroup {
            [pscustomobject]@{
                Guid = $script:Guid; Name = 'Sales'; DisplayName = 'Sales'; PrimarySmtpAddress = 'sales@contoso.com'; Alias = 'sales'
                DistinguishedName = $script:Dn; IsDirSynced = $false; ManagedBy = @('alice')
            }
        } -ParameterFilter { $Identity }
        Mock Get-DistributionGroup { } -ParameterFilter { $Filter }
        Mock Get-DistributionGroupMember { [pscustomobject]@{ DisplayName = 'Bob'; PrimarySmtpAddress = 'bob@contoso.com'; RecipientTypeDetails = 'UserMailbox' } }
        Mock Get-Mailbox { }
        Mock Get-EmailAddressPolicy { }
        Mock Get-EligibleDistributionGroupForMigration { [pscustomobject]@{ PrimarySmtpAddress = 'sales@contoso.com' } }
    }
    It 'reports no blockers for a clean group' {
        $r = Get-DLUpgradeReadiness -Identity 'sales'
        @($r | Where-Object Status -EQ 'Blocked') | Should -HaveCount 0
        @($r | Where-Object Status -EQ 'Error') | Should -HaveCount 0
        ($r | Where-Object Check -EQ 'Microsoft eligibility check').Status | Should -Be 'Info'
    }
    It 'stops after the type check for a dynamic distribution group' {
        Mock Get-Recipient {
            [pscustomobject]@{ Guid = $script:Guid; RecipientTypeDetails = 'DynamicDistributionGroup'; DistinguishedName = $script:Dn }
        } -ParameterFilter { $Identity }
        $r = Get-DLUpgradeReadiness -Identity 'dyn'
        $r | Should -HaveCount 1
        $r.Status | Should -Be 'Blocked'
        Should -Invoke Get-DistributionGroupMember -Times 0 -Scope It
    }
    It 'keeps running other checks when one check errors' {
        Mock Get-Mailbox { throw 'transient failure' }
        $r = Get-DLUpgradeReadiness -Identity 'sales'
        ($r | Where-Object Check -EQ 'Shared mailbox forwarding').Status | Should -Be 'Error'
        ($r | Where-Object Check -EQ 'Alias characters').Status | Should -Be 'Pass'
    }
}
