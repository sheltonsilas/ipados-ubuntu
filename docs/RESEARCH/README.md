# Research notes

Short summaries of prior art, written for a future agent that has no memory of the session that
learned them. Every claim carries a source; where a source could not be found, the note says so
instead of asserting it. **These are notes to learn from, not code to copy** — several of these
projects are copyleft (see LICENSES.md).

| Note | Why it matters |
| --- | --- |
| [JIT and entitlements on iOS](jit-and-entitlements-on-ios.md) | Whether the app can execute generated code at all, which sideloading route to document for the owner, and what the memory entitlements really grant (revised 2026-10-15) |
| [Syscall translation prior art](syscall-translation-prior-art.md) | How iSH, gVisor, WSL1, QEMU linux-user and ios-linuxkit handle syscalls, processes, futexes and page size — the design space for Track B |
| [The process model without a process API](process-model-without-fork.md) | The model Track B will implement for `fork`/`clone`/`wait`/signals/descriptors inside one app, and the copy-on-write consequence of executing guest code natively |
| [Getting a Linux desktop onto the iPad screen](desktop-graphics-path.md) | Why Xvfb plus damage rectangles plus XTest is the smallest display path, and what a full-frame copy would cost |

The plan these notes feed is [../TRACK-B-PLAN.md](../TRACK-B-PLAN.md).

Open questions to answer in later sessions (do not re-research what is already settled in
`docs/DECISIONS.md`):

- Which concrete mechanism actually triggers JIT enablement on iOS 17.4-18+ from StikDebug, and can
  we drive it from an in-app extension (Husk's `HuskJITHelper` design)?
- Does the increased-memory-limit entitlement survive any free-Apple-ID sideloading path, and what does
  `os_proc_available_memory()` report on the owner's iPad with and without it?
- What is the real measured cost of translating `svc` at load time versus patching a libc on an
  iPad, on a shell workload?
- How expensive is an eager address-space copy on `fork` for a realistic shell workload, and is a
  hardware write barrier (mprotect + fault) worth it at that size? Measure before deciding (B3).
- Does `Xvfb -shmem`'s XWD buffer layout survive a round trip into a Metal texture without a conversion
  pass, and what is the measured cost of a 2360×1640 damage rectangle pipeline? (B7)
