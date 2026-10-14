# Licenses

## This project

Our own original code is licensed **GPL-2.0-or-later** (see [LICENSE](LICENSE)); the "or later"
applies to all files we write. Why: Track A links QEMU, which is GPL-2.0, and GPL-2.0-or-later is
the only choice that stays compatible with both QEMU (GPL-2.0) and any Apache-2.0 upstream code we
build against. Full reasoning and the alternatives considered: decision 0001 in
[docs/DECISIONS.md](docs/DECISIONS.md).

## Third-party components

Nothing in this table is vendored into the repository yet. It records what each component is
under, so the license obligations are known before we depend on it.

| Component | Used for | License | Notes |
| --- | --- | --- | --- |
| [UTM](https://github.com/utmapp/UTM) | Track A: iOS VM host app (upstream of our fork) | Apache-2.0 | Forked into `track-a-utm/`; upstream headers and `LICENSE` are kept intact |
| [QEMU](https://www.qemu.org/) | Track A: emulation backend used by UTM | GPL-2.0 (most files; some files are GPL-2.0-or-later or other licenses) | Built from upstream submodules at build time, not vendored here. Distributing an IPA that links QEMU makes that distribution subject to GPL-2.0 |
| [Ubuntu](https://ubuntu.com/) base image / cloud image | Guest root filesystem | Mixed free licenses (GPL, LGPL, MIT, BSD, and others) | Downloaded by the user at first run from Ubuntu's official servers; never committed to this repo |
| [XFCE](https://xfce.org/) / [LXQt](https://lxqt-project.org/) | Lightweight guest desktop | GPL/LGPL (XFCE: mostly GPL-2.0-or-later; LXQt: LGPL-2.1-or-later) | Installed inside the guest image, not linked into the app |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Generates the iOS Xcode project in CI | MIT | CI-only build tool, never shipped |
| [swift-actions](https://github.com/swift-actions) / GitHub Actions | CI plumbing | MIT (per action) | CI-only |
| [StikJIT](https://github.com/StikDebug/StikJIT) / [StikDebug](https://github.com/StikDebug/StikDebug) | Optional: enabling JIT at runtime from the device | GPL-3.0 / MIT (check upstream) | **Reference/optional tooling only.** If we link StikJIT we must re-check this table and DECISIONS.md first |
| [Husk](https://github.com/Leviidev/Husk) | Reference for JIT helper design | GPL-2.0-or-later | **Read only. Never copy code from it.** |
| [Madeira](https://github.com/utmapp/Madeira) | Reference for memory handling | GPL-3.0-or-later | **Read only. Never copy code from it.** |
| [iSH](https://github.com/ish-app/ish) | Reference for syscall translation | GPL-3.0 | **Read only. Never copy code from it.** |
| [gVisor](https://gvisor.dev/) | Reference for the kernel-interface design | Apache-2.0 | **Read only.** |
| [QEMU linux-user](https://www.qemu.org/docs/master/user/main.html) | Reference: syscall translation checklist | GPL-2.0 | **Read only for the syscall table; do not copy code.** |

## Obligations we must honour when we ship

- Ship the license texts of everything we distribute together (GPL-2.0 text, and the upstream
  UTM Apache-2.0 `LICENSE`, plus QEMU's notices) alongside the IPA, and point at exact source
  revisions for the corresponding source.
- Do not relicense upstream code. Our GPL-2.0-or-later applies to files we wrote.
- Keep this file updated in the same commit that introduces a new dependency.

_Last reviewed: 2026-10-14 (Phase 0)._
