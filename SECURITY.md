# Security

## What the script does with your tenant

- It is read-only. Apart from `Connect-ExchangeOnline`,
  `Disconnect-ExchangeOnline` and `Import-Module`, it runs only `Get-*`
  cmdlets, and it makes no changes to Exchange Online.
- It never stores credentials. Sign-in is handled by the
  `ExchangeOnlineManagement` module's interactive sign-in.
- It sends nothing anywhere except Exchange Online. Results go to the console
  and the PowerShell pipeline only.
- It disconnects only the Exchange Online session it opened itself.

The commands in [RESOLVING.md](RESOLVING.md) *do* change your tenant. Read each
section's warnings before you run them.

## Handling output

The script's output contains names, email addresses and group memberships from
your tenant. Treat saved reports as internal data, and redact them before
sharing them publicly, including in issues on this repository.

## Reporting a vulnerability

Report security problems privately: open this repository's **Security** tab
and choose **Report a vulnerability**. Please don't open a public issue.

Only the latest version on the `main` branch receives fixes.
