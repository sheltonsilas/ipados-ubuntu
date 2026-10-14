# AGENTS.md — read this before you do anything

You are an AI agent picking up a long-running, multi-session project. The owner is **not a
programmer** and is not expected to answer technical questions. Work autonomously, decide,
document, and keep going.

## Read order (about 5 minutes)

1. This file.
2. [docs/STATUS.md](docs/STATUS.md) — the truthful current state and the next 5 tasks.
3. [docs/DECISIONS.md](docs/DECISIONS.md) — decisions already made. **Do not re-litigate them.**
4. The last two entries of [docs/LOG.md](docs/LOG.md) — what the previous session did.
5. [docs/ROADMAP.md](docs/ROADMAP.md) — which phase is active and its exit criteria.

If a fact matters and is not in those files, add it. A future agent has **no memory** of your
session; anything you do not write down is lost.

## Mission

Get a real Ubuntu (arm64) graphical desktop running on iPadOS, built entirely by public GitHub
Actions runners into an unsigned IPA that the owner sideloads.

Two tracks run in parallel:

- **Track A — baseline** (`track-a-utm/`): fork UTM, build its iOS target as an unsigned IPA in
  CI, ship a preconfigured Ubuntu arm64 + XFCE/LXQt VM. This is the fallback and the performance
  benchmark. It must never be broken for long.
- **Track B — the real goal** (`track-b-runtime/`): a native runtime that loads Ubuntu arm64 ELF
  binaries and executes them on the iPad CPU with Linux syscalls handled in our own code. The
  platform-independent part lives in a Swift package that builds and tests on Linux CI; the iOS
  shell is a thin SwiftUI app.

## Hard constraints (violating these is a failure)

1. **Everything is public.** Public repo, public issues, public CI logs. Never commit secrets,
   tokens, personal data, or device identifiers.
2. **Only GitHub-hosted public runners.** `macos-15` for iOS builds, `ubuntu-latest` for core
   tests. No self-hosted runners, no paid services, no credentials for third-party services.
3. **The deliverable is an unsigned IPA.** Build with code signing disabled and zip `Payload/`
   yourself in CI. Never require an Apple Developer account or Apple credentials.
4. **No App Store work.** JIT-style memory is required and forbidden there. Do not spend time on
   compliance, review guidelines, or store assets.
5. **Respect licenses.** UTM is Apache-2.0; QEMU is GPL-2.0. Husk (GPL-2.0-or-later) and Madeira
   (GPL-3.0-or-later) are **references to read, never code to copy**. Keep
   [LICENSES.md](LICENSES.md) accurate whenever you add a dependency or vendor anything.
6. **Be honest.** Never claim something works unless CI or a test proves it. If it is not proven
   on a physical iPad, label it **unverified on device**. Report failing or unrun checks as
   failures, never as passes.

## Rules of engagement

- **Do not ask the owner technical questions.** Decide, write the decision into DECISIONS.md, and
  continue. Ask only when a login cannot be completed, a permission only they can grant is
  needed, or something is legally risky.
- **Secrets:** the git/gh credential lives in the OS credential store. Never print a token, never
  write one to a file, commit, workflow, issue, log or chat message. CI uses the built-in
  `GITHUB_TOKEN`. See [docs/SETUP.md](docs/SETUP.md).
- **Never force-push, reset, or rewrite published history.** Never delete phases in ROADMAP.md;
  update them. Never delete an entry in LOG.md.
- **Prefer the simplest design that could work, then measure.** No speculative features. Cap
  research time and write down what you learned.
- **Tests are the source of truth**, not your confidence. Every phase exit criterion should be an
  automated test wherever that is possible; a phase is done only when its tests pass in CI.
- **Keep the owner's reports short:** what changed, what works, what is next, what (if anything)
  you need from them.

## Where things are

```
README.md               what this is, how to install the IPA
AGENTS.md               this file
LICENSES.md             third-party components and licenses
docs/STATUS.md          current state, next 5 tasks, token info
docs/ROADMAP.md         phases 0-6 with checkboxes and exit criteria
docs/DECISIONS.md       numbered decisions: context, options, choice, consequences
docs/LOG.md             dated session log, newest first
docs/SETUP.md           token renewal, sideloading, JIT, owner checklist
docs/RESEARCH/          prior-art notes (read before designing)
track-a-utm/            UTM fork and VM definition for the baseline app
track-b-runtime/core/   platform-independent Swift package (builds on Linux)
track-b-runtime/ios/    SwiftUI shell, XcodeGen spec, entitlements
tools/                  repository checks used by CI
.github/workflows/      CI: build-ipa (macos-15), tests (ubuntu-latest)
```

## How to work a session

1. Run `gh auth status` (or check whether `GH_TOKEN` is set) and `git log --oneline -5`.
2. Take the top item from "next tasks" in docs/STATUS.md unless a red build takes priority.
3. Build, test locally where possible, push, then **watch CI yourself**:
   `gh run watch` / `gh run view --log-failed`. Do not stop at the first red build; read the log,
   fix, push again.
4. Update STATUS.md, LOG.md, ROADMAP.md and DECISIONS.md in the same session.
5. Commit in small, focused commits. Do not commit generated build output (`build/`, `*.ipa`).

## Known environment limits (as of the last session)

- The agent machine is Windows with Git Bash. `xcodebuild` and `swift` are **not** available
  locally, so iOS builds and Swift core tests are validated only in CI.
- A browser is available for GitHub web operations; the owner is signed in there.
