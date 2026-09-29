# Contributing

Bug reports and fixes are welcome.

## Ground rules

- **Redact tenant data.** Never post real names, email addresses, domains,
  GUIDs or distinguished names in issues, pull requests or test data. Use
  placeholders such as `user1@contoso.com`.
- **Microsoft's documentation is the source of truth.** A change to what counts
  as a blocker, or to a fix in RESOLVING.md, should link the Microsoft Learn
  page that supports it.
- **Keep the script read-only.** It must never change a tenant. Commands that
  change things belong in RESOLVING.md, with their side effects described.
- **Exchange Online only.** The script depends on one module
  (`ExchangeOnlineManagement`) and one sign-in. Don't add a Microsoft Graph or
  other module dependency.
- **Verify property names against Microsoft's docs.** Before the script or a
  test mock reads a property of an Exchange object, confirm the cmdlet actually
  returns it. The script runs under `Set-StrictMode`, so a missing property
  throws. Mocks must mirror real object shapes, or tests pass while the script
  fails against a real tenant.
- **Don't add `#Requires -Modules ExchangeOnlineManagement`.** The tests and
  CI dot-source the script without that module installed. The script checks for
  the module at runtime instead.

## Making a change

1. Fork the repository and create a branch.
2. Write or update a Pester test for the change first. The tests mock every
   Exchange cmdlet, so they need no tenant.
3. Run the checks locally:

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./Test-DLUpgradeReadiness.ps1
```

4. Open a pull request against `main`. CI runs the same checks on
   PowerShell 7 and Windows PowerShell 5.1, and both must pass before merging.

If you add a blocker, add its fix to the `$Resolutions` map in the script and a
matching `## ` section to RESOLVING.md. A test fails if the two drift apart.

Add a line to the top of CHANGELOG.md describing any user-visible change.
