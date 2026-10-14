# JIT and entitlements on iOS/iPadOS (non-jailbroken)

_Learned 2026-10-14. Sources cited inline. Treat every line as "what the documentation says", not
as behaviour we have verified — none of this has been tested on a device yet._

## The key correction

An app cannot make its own generated code executable merely by declaring an entitlement. The
practical sideloaded-JIT workflow makes the app **debug-attachable** (`get-task-allow`) and then a
debugger-capable helper attaches to it. "Has the entitlement in the IPA" and "the OS honours it"
are different things.

## Entitlements: what each one really does

| Item | Meaning | Source |
| --- | --- | --- |
| `get-task-allow` | Lets a debugger attach. It is the prerequisite for the debugger-based JIT route (AltJIT, SideStore/StikDebug, TrollStore's "launch with JIT"). Apple removes it for App Store submission. | [StikDebug](https://github.com/StikDebug/StikDebug), [Apple: debugger entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger) |
| `dynamic-codesigning` | The entitlement name commonly associated with directly executable generated code. TrollStore documents it as **banned on iOS 15+ on A12 and newer**; UTM ships a separate TrollStore IPA because of it. | [TrollStore](https://github.com/opa334/TrollStore), [UTM iOS guide](https://docs.getutm.app/installation/ios/) |
| `com.apple.security.cs.allow-jit` | Apple's Hardened Runtime entitlement for creating writable/executable memory via `MAP_JIT`. Documented for **macOS**; not a magic iOS sideloading grant. | [Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit) |
| `com.apple.security.cs.allow-unsigned-executable-memory` | macOS Hardened Runtime exception for W+X memory. Same caveat. | [Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory) |
| `com.apple.private.cs.debugger` | Private entitlement, banned on iOS 15+ A12+; not the same as the documented debugger entitlement. | [TrollStore](https://github.com/opa334/TrollStore) |

Sideloading tools cannot grant private entitlements freely: the effective entitlements come from the
signing identity, the provisioning profile, the tool's behaviour and OS enforcement. No source found
proves AltStore/SideStore preserve *arbitrary* entitlements across versions — only that their
documented JIT workflows need an attachable target.

## How JIT is actually enabled

1. Install the app with `get-task-allow`.
2. A helper (on device or over a network/USB pairing) connects to the device's debug services using
   a pairing record and (on modern systems) developer disk image support.
3. The helper attaches to the running app; the app can then use JIT-capable memory.
4. JIT stays available until the app is force-quit or purged while suspended.

- [AltJIT / AltStore FAQ](https://faq.altstore.io/altstore-classic/enabling-jit/altjit) (iOS 17
  workflow is Mac-only per those docs)
- [SideStore JIT guide](https://docs.sidestore.io/docs/advanced/jit) (delegates to StikDebug on
  newer systems)
- [StikDebug](https://github.com/StikDebug/StikDebug) README: support from iOS 17.4, "fully
  supported" 17.4-18.
- [StikJIT integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md): on
  systems where attachment alone is insufficient, the app and debugger use **breakpoints as a
  request channel** to prepare executable regions; a JIT engine must implement the matching
  protocol.
- Historical explanation of the `CS_DEBUGGED` state and the old self-`ptrace` trick:
  [Saagar Jha, "Jailed Just-in-Time Compilation on iOS"](https://saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/).
- The self-`ptrace` trick broke on iOS 14 (codesigning SIGKILL): [UTM issue #397](https://github.com/utmapp/UTM/issues/397).
- **Husk's design** puts the attaching code in an **app extension** (`HuskJITHelper.appex` +
  `StikJIT.framework` + a pairing file in Documents), because a process cannot synchronously debug
  itself; if the sideloader strips extensions, Husk recommends StikDebug instead.
  [Husk built-in JIT](https://github.com/Leviidev/Husk/blob/main/docs/06-built-in-jit.md)

Correction worth keeping: the iOS 14 JIT hardening is attributed to **debugging/codesigning
changes**, not to App Clips. No primary source was found for an App-Clip-specific kernel rule.

## "JIT-less" is not the same as W^X

UTM SE is genuinely a **non-JIT interpreter** (slower). An `mprotect`/W^X scheme that flips pages
between writable and executable is still JIT because it generates code at runtime.

## Page size

- Apple recommends querying the runtime page size (`vm_page_size`) instead of assuming a constant:
  [WWDC20 porting session](https://developer.apple.com/videos/play/wwdc2020/10214/), [`mmap(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mmap.2.html).
- Husk's substrate notes describe preparing executable memory in **16 KiB pages, one page at a
  time**, which also implies per-page latency:
  [Husk JIT substrate](https://github.com/Leviidev/Husk/blob/main/docs/02-jit-substrate.md).
- Not verified: that every iPad model and iOS version exposes the same page size. Query it at
  runtime.

## What this means for us

- Ship the app with `get-task-allow` and document the debugger-attach route as the supported way to
  get JIT (decision recorded in SETUP.md's entitlement table).
- Do not plan on `dynamic-codesigning` or the increased-memory-limit entitlement surviving a
  free-Apple-ID sideload.
- A built-in helper extension (Husk-style) is worth attempting, but it must be confirmed per
  sideloading tool, because extension signing is tool-dependent.
- Re-check this note when we learn something on a real device, and correct it rather than deleting it.
