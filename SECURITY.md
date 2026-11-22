# Security

## Reporting a problem

Please report anything that lets a block end early, lets a looser change apply without its 24-hour wait, or lets another process talk to the Shield service, through a private security advisory on the repository rather than a public issue.

## The guarantees Shield aims for

- **Fail closed.** When the service can't verify its own state, it keeps blocking rather than unblocking.
- **Stricter at once, looser later.** Every weakening (releasing a block, more allowed hours, removing websites) waits at least 24 hours; the service enforces this, not the app.
- **Authenticated changes.** The service accepts requests only from the installed app's exact code signature, and signs its state and receipts with a root-owned key.
- **Contained downloads.** The download tools run under a Seatbelt profile that only allows a loopback connection to a small broker, which allows only the hosts a job needs.

## Out of scope

Shield is a self-commitment tool. It does not defend against an administrator of the Mac (who can stop the service or edit `/etc/hosts`), nor against DNS-over-HTTPS, alternate resolvers, VPNs or direct IP access. These are documented limits, not bugs. See [docs/download-egress-threat-model.md](docs/download-egress-threat-model.md) for the download design.
