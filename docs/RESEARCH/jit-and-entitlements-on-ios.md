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

## 2026-10-15 — second pass, after reading Apple's own pages again

Added because Track B's plan now hangs on these two questions and the answers changed the wording
above. Everything here is *documented* unless marked inferred.

**Writable-and-executable memory is Apple-controlled.** Apple's Platform Security guide says iOS/iPadOS
use Execute Never, that pages which are both writable and executable are allowed only under tightly
controlled conditions, that the kernel checks for Apple's **dynamic-code-signing** entitlement, and that
even then only a single such `mmap` is permitted. `com.apple.security.cs.allow-jit` is documented as the
**macOS Hardened Runtime** route via `MAP_JIT`, not as an iOS sideloading entitlement; the entitlement
iOS actually checks is Apple-only. [Platform Security: runtime process security](https://support.apple.com/en-in/guide/security/sec15bfe098e/web), [`allow-jit`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)

**What is *not* documented:** that `mprotect(PROT_EXEC)` on an app-owned anonymous mapping always fails
without an entitlement. XNU adds `PROT_EXEC` in `vm_map.c`, and its code-signing test expects unsigned
code execution to be stopped by enforcement (SIGBUS with PMAP code signing, SIGKILL under the VM-layer
path, depending on platform and configuration) — i.e. the *protection call* succeeding says nothing
about whether the *bytes* may execute. This is exactly why the app measures both and reports: a probe
that reports `rx_mapping=ok` is evidence, a probe that reports `failed` is also evidence, and neither is
an assumption. [XNU `vm_map.c`](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/vm/vm_map.c), [XNU VM code-signing test](https://newosxbook.com/src.php?tree=xnu&file=/tests/vm_test_code_signing.c)

**Sideloading routes, corrected and dated.** AltStore Classic/AltJIT and SideStore + StikDebug/StikJIT
both work by attaching a debugger to a development-signed, `get-task-allow` target: they obtain JIT state
*at runtime*, they do not grant Apple's dynamic-code-signing entitlement. SideStore's JIT page documents
17.4–18, and its FAQ documents the free-account limits (three active apps, ten App IDs a week, seven-day
refresh). TrollStore preserves arbitrary entitlements *except* that `dynamic-codesigning` is banned on
iOS 15+ on A12-or-newer, and its published support ends at **17.0** — so it is not a route for a modern
iPad. StikJIT's integration guide says a debugger attach alone may not be enough on TXM/SPTM systems and
describes a breakpoint-based protocol for preparing executable regions. [SideStore JIT](https://docs.sidestore.io/docs/advanced/jit), [SideStore FAQ](https://docs.sidestore.io/docs/faq), [TrollStore](https://github.com/opa334/TrollStore), [StikJIT integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)

**The memory entitlements are separate capabilities, not RAM grants.**
`com.apple.developer.kernel.increased-memory-limit` raises the app's jetsam limit on **supported device
models** and tells the developer to query `os_proc_available_memory()` rather than assume a number;
`com.apple.developer.kernel.extended-virtual-addressing` is about address space, not physical memory. A
free Personal Team can build and test on a personal device but is limited to seven-day profiles; Apple
documents that more advanced capabilities require Developer Program membership, and the capability must
be enabled for the App ID (which regenerates the provisioning profile). We could **not** verify from the
public capability matrix which membership tier authorises each of the two memory entitlements. What the
app must therefore do is the same as for JIT: **report what it actually has** (`os_proc_available_memory()`
and the physical/available pair) instead of writing a number into a document. [Increased Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit), [Extended Virtual Addressing](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing), [enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/), [developer account basics](https://developer.apple.com/help/account/basics/about-your-developer-account/), [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

**Consequence for the design, and it is the important part:** Track B never asks for a
writable-and-executable page — text is written while the mapping is writable and made executable
afterwards (decisions 0011/0018/0019). That is the *only* shape with a chance of working under Apple's
rule, and the app ships with `get-task-allow` so the documented debugger route is available to the
owner. The question "does it actually work on my iPad" is answered by the app's probe output in a
GitHub issue, not by this note.
