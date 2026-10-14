# Research notes

Short summaries of prior art, written for a future agent that has no memory of the session that
learned them. Every claim carries a source; where a source could not be found, the note says so
instead of asserting it. **These are notes to learn from, not code to copy** — several of these
projects are copyleft (see LICENSES.md).

| Note | Why it matters |
| --- | --- |
| [JIT and entitlements on iOS](jit-and-entitlements-on-ios.md) | Whether the app can execute generated code at all, and which sideloading route to document for the owner |
| [Syscall translation prior art](syscall-translation-prior-art.md) | How iSH, gVisor, WSL1, QEMU linux-user and ios-linuxkit handle syscalls, processes, futexes and page size — the design space for Track B |

Open questions to answer in later sessions (do not re-research what is already settled in
`docs/DECISIONS.md`):

- Which concrete mechanism actually triggers JIT enablement on iOS 17.4-18+ from StikDebug, and can
  we drive it from an in-app extension (Husk's `HuskJITHelper` design)?
- Does the increased-memory-limit entitlement survive any free-Apple-ID sideloading path?
- What is the real measured cost of translating `svc` at load time versus patching a libc on an
  iPad, on a shell workload?
