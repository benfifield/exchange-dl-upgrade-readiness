# Changelog

Notable changes to this project. Versions follow
[Semantic Versioning](https://semver.org/). Each release is tagged `vX.Y.Z`
and published on the repository's Releases page.

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
