# Contributing

Thanks for helping. A few rules keep Shield trustworthy:

1. **Never weaken a block early.** Anything that unblocks a website, adds allowed time or removes a site must wait at least 24 hours, and the service (`Kairos/FixtureBackend.swift`) must enforce it. Stricter changes may apply at once.
2. **Status must be truthful.** Don't show "blocked" or "allowed" unless the service confirmed it. When unsure, say so.
3. **Fail closed.** If state can't be read or verified, keep blocking.
4. **Keep the UI simple.** One name per action, short copy, no internal IDs or jargon (owner, authority, receipt) in user-facing text.

## Before opening a pull request

- Run the unit tests (see README). Add a test for any change to the service or the view model.
- For UI changes, run the two flow tests and include before/after screenshots.
- Don't add personal block lists, schedules, names or paths to code, tests or fixtures; use `example.com`-style data.
