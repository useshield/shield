# Security

## Reporting a problem

Please report anything that lets a block end early, lets a looser change apply without its 24-hour wait, or lets another process talk to the Shield service, through a private security advisory on the repository rather than a public issue.

## The guarantees Shield aims for

- **Fail closed.** When the service can't verify its own state, it keeps blocking rather than unblocking.
- **Stricter at once, looser later.** Every weakening (releasing a block, more allowed hours, removing websites) waits at least 24 hours; the service enforces this, not the app.
- **Authenticated changes.** The service accepts requests only from the installed app's exact code signature, and signs its state and receipts with a root-owned key.
- **Contained downloads (Video Library add-on).** The download tools run under a Seatbelt profile that only allows a loopback connection to a small broker, which allows only the hosts a job needs.

## Known gaps

Shield is a self-commitment tool. Websites are blocked through a browser policy in Chrome, Brave, Edge, Vivaldi and Firefox, and through `/etc/hosts` everywhere else. These are known and planned, not bugs:

- Safari and other apps only get the `/etc/hosts` block, so custom DNS, DNS-over-HTTPS, VPNs and unlisted subdomains can reach a blocked site there.
- Browsers that don't read the policy (such as Arc and Opera) only get a check on how they were started.
- When the service isn't running, Shield records the gap so it shows afterwards.

See [docs/download-egress-threat-model.md](docs/download-egress-threat-model.md) for the download design.
