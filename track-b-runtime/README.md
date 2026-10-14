# Track B — the native arm64 syscall-translation runtime

**Status: Phase 0 skeleton.** The ELF header parser, the curated syscall table and the diagnostics
model exist and are tested in CI. Nothing executes a Linux binary yet.

## Layout

```
core/                       SwiftPM package: platform-independent, builds and tests on Linux CI
  Sources/UbuntuPadCore/
    ELF.swift               ELF64/AArch64 header + program header parsing, PT_INTERP lookup
    SyscallTable.swift      curated arm64 syscall numbers and lookup helpers
    Diagnostics.swift       the report an owner pastes into a GitHub issue
    Version.swift           version/phase constants (named BuildInfo, not the module name)
  Tests/UbuntuPadCoreTests/ unit tests, including a real cross-compiled arm64 binary
ios/                        the iOS shell (SwiftUI + XcodeGen spec)
  project.yml               source of truth for the Xcode project (decision 0005)
  UbuntuPad/                app sources; the only place Apple-only APIs may appear
testdata/hello.c            the probe program: static arm64, used by tests and by Phase 2
```

`core` must never import `Darwin`, `UIKit`, `SwiftUI`, `Metal`, `MachO` or friends — CI enforces
this (decision 0006), because that is what lets us test syscall semantics on a free Linux runner.

## What Phase 2 adds, in order

1. **ELF loader**: map `PT_LOAD` segments into the guest address space from parsed program headers.
   The parser already rejects non-AArch64, non-ELF64, truncated and misordered images, and CI checks
   its offsets against a real `-static` aarch64 binary built with `gcc-aarch64-linux-gnu`.
2. **Guest memory model**: 4 KiB guest pages on top of 16 KiB host pages, with a software page table
   (see [syscall-translation prior art](../docs/RESEARCH/syscall-translation-prior-art.md)).
3. **Syscall dispatch**: `write`, `exit`, `mmap`, `brk`, `read` first, then the table in
   `SyscallTable.swift`, which CI keeps consistent.
4. **Capture mechanism**: `svc` rewriting vs a patched libc vs interpretation — decision 0008 is
   still *proposed* and must be resolved with measurements, not opinion.
5. **A static arm64 "hello world" running in tests** on the ubuntu-latest runner, asserting stdout.
   `testdata/hello.c` is that program.

## How to run the tests

```bash
cd track-b-runtime/core
swift test                      # works on macOS and Linux
```

To also exercise the real-binary check locally, cross-compile the probe and point the test at it:

```bash
aarch64-linux-gnu-gcc -static -O0 -o /tmp/hello-arm64 track-b-runtime/testdata/hello.c
UBUNTUPAD_TEST_BINARY=/tmp/hello-arm64 swift test --filter ELFTests
```

Without `UBUNTUPAD_TEST_BINARY` that one test reports **skipped**, never passed — check the test
output, not just the exit code.
