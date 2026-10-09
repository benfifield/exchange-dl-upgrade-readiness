# Changelog

Notable changes to this project. Versions follow
[Semantic Versioning](https://semver.org/). Each release is tagged `vX.Y.Z`
and published on the repository's Releases page.

## Unreleased

- New check, **Owner types**: blocks when an owner isn't a user mailbox or
  mail user, for example a shared mailbox, a group or a user without a
  mailbox. Microsoft's DLT365Groupsupgrade script checks this too.
- The shared mailbox forwarding check now also catches mailboxes that
  forward to any of the list's SMTP addresses through
  `ForwardingSmtpAddress`, not just through `ForwardingAddress`.
- Fixed: when a tenant rejected a server-side filter, the "falling back to a
  full scan" path failed with `The term 'Test-IdentityMatch' is not
  recognized` and the check was reported as `ERROR`. This affected the
  parent group, shared mailbox forwarding and sender restriction checks when
  the script was run from a PowerShell prompt.

## 1.1.1 - 2026-10-07

- The email address policy check no longer flags the built-in
  `Default Policy` (priority `Lowest`), which every tenant has. Previously
  every tenant was reported as blocked.
- RESOLVING.md has a new section, "Upgrade fails even though every check
  passes", for upgrades that Microsoft accepts but never completes.
- The script now requires ExchangeOnlineManagement 3.0.0 or later and says
  so up front, instead of failing later on `Get-ConnectionInformation`.
- Documentation fixes for the public release:
    - The Exchange admin center upgrade steps now match Microsoft's
      owner-approval flow (**Send upgrade request**), and note that an
      upgrade can't be undone.
    - README requirements link to Microsoft's setup docs, including execution
      policy and unblocking downloaded scripts.
    - RESOLVING.md lists the roles and sync client versions that group source
      of authority conversion needs.
    - Sender restriction steps add a replacement before removing the list, so
      the other list is never left open to anyone.
    - The email address policy steps record and restore the whole policy,
      including `ManagedByFilter`.

## 1.1.0 - 2026-09-30

- A bare run no longer prints result objects below the report. Objects are
  written to the pipeline when the output is piped, or always with the new
  `-PassThru` switch (needed for `$r = ...`).

## 1.0.0 - 2026-09-29

First release.

- Checks one distribution list against every upgrade blocker in Microsoft
  KB 4481100 and names the offending members, groups, mailboxes or policies.
- Cross-checks the result with `Get-EligibleDistributionGroupForMigration`
  and warns when Microsoft and the documented rules disagree.
- Prints a one-line fix under each blocker, with step-by-step instructions
  in RESOLVING.md.
- Writes result objects to the pipeline for `Export-Csv` and filtering.
- Runs on PowerShell 7 and Windows PowerShell 5.1.
