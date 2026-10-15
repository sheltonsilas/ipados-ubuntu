# Ubuntu Desktop for iPadOS

Run a full **Ubuntu (arm64) Linux desktop** on an iPad. Everything is built by public GitHub
Actions runners into an **unsigned `.ipa`** that you sideload yourself. No Apple Developer
account, no paid services, no App Store.

[![Build unsigned IPA](https://github.com/sheltonsilas/ipados-ubuntu/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/sheltonsilas/ipados-ubuntu/actions/workflows/build-ipa.yml)
[![Core tests](https://github.com/sheltonsilas/ipados-ubuntu/actions/workflows/tests.yml/badge.svg)](https://github.com/sheltonsilas/ipados-ubuntu/actions/workflows/tests.yml)

## What this is (10 lines)

1. iOS cannot boot a Linux kernel or use a hypervisor, so there are two ways to get Ubuntu.
2. **Track A** (fallback, ships first): a fork of [UTM](https://github.com/utmapp/UTM) that
   emulates an arm64 Ubuntu VM with a lightweight XFCE/LXQt desktop.
3. **Track B** (the long-term goal): a native runtime that loads Ubuntu arm64 ELF binaries and
   runs them directly on the iPad CPU, translating Linux system calls in our own code — the same
   idea as WSL1, iSH and gVisor, but for arm64 on iOS. It already runs a real arm64 **Linux**
   program in CI and inside the app; the whole plan is [docs/TRACK-B-PLAN.md](docs/TRACK-B-PLAN.md).
4. Both tracks are built in CI into unsigned IPAs published on the
   [Releases page](https://github.com/sheltonsilas/ipados-ubuntu/releases).
5. Track A always stays working, so there is a usable app even while Track B is unfinished.
6. JIT-style memory is required, so the app cannot go on the App Store and is not a target.
7. Everything here is public: code, issues, CI logs. No secrets are ever committed.
8. The current state lives in [docs/STATUS.md](docs/STATUS.md) — read that first.
9. Prior art, decisions and the roadmap live in [docs/](docs).
10. Licensed GPL-2.0-or-later (see [LICENSES.md](LICENSES.md)); upstream components keep their own licenses.

## Install (sideloading)

1. Open [Releases](https://github.com/sheltonsilas/ipados-ubuntu/releases) and download
   `UbuntuPad-unsigned.ipa` (from `nightly` for the newest, or a tagged release for a milestone).
2. Sideload it with **AltStore**, **SideStore**, **Sideloadly** or **TrollStore**.
3. Enable **JIT** for the app (StikDebug, or the in-app helper once it exists) — see
   [docs/SETUP.md](docs/SETUP.md). The Ubuntu desktop is unusably slow without JIT.
4. Launch the app. The first run downloads the Ubuntu image; expect a long wait the first time.

Step-by-step, non-technical instructions for the project owner: [docs/SETUP.md](docs/SETUP.md).

## Repository layout

| Path | Contents |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Instructions every AI agent must read before touching this repo |
| [docs/STATUS.md](docs/STATUS.md) | What works, what is broken, next tasks |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Phases with checkboxes |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Numbered design decisions with alternatives |
| [docs/LOG.md](docs/LOG.md) | Dated session log, newest first |
| [docs/TRACK-B-PLAN.md](docs/TRACK-B-PLAN.md) | Track B's complete plan: design problems, milestones, exit criteria, risks |
| [docs/RESEARCH/](docs/RESEARCH) | Notes on prior art (UTM, iSH, gVisor, FEX, WSL1, Husk) |
| [docs/SETUP.md](docs/SETUP.md) | Tokens, sideloading, JIT, owner checklist |
| [track-a-utm/](track-a-utm) | Track A: the UTM-based baseline |
| [track-b-runtime/](track-b-runtime) | Track B: syscall-translation runtime (platform-independent core + iOS shell) |
| [LICENSES.md](LICENSES.md) | Every third-party component and its license |

## Building locally

Track B's platform-independent core builds and tests anywhere Swift runs:

```bash
cd track-b-runtime/core
swift test
```

The iOS app and the IPA are built only in CI (macOS runner, `CODE_SIGNING_ALLOWED=NO`):

```bash
cd track-b-runtime && xcodegen generate --spec ios/project.yml
xcodebuild -project UbuntuPad.xcodeproj -scheme UbuntuPad -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## License

Our own code: **GPL-2.0-or-later**. See [LICENSES.md](LICENSES.md) and decision 0001 in
[docs/DECISIONS.md](docs/DECISIONS.md).
