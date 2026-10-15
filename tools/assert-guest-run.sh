#!/usr/bin/env bash
# Asserts that a built `ubuntupad-run` really executes guest programs, on a real Apple-silicon host.
#
# The point of asserting on stdout *between the runner's markers* is that a passing exit code proves
# nothing here: a runner that never enters the guest, or that prints the message itself, would still
# exit 0. Every check below is about bytes that could only have come from guest code running on the
# guest's own stack, with its own link-time addresses.
#
# Usage: tools/assert-guest-run.sh <ubuntupad-run> <hello-nostdlib> <stack-probe-nostdlib>
set -euo pipefail

runner="${1:?usage: assert-guest-run.sh <ubuntupad-run> <hello-nostdlib> <stack-probe-nostdlib>}"
hello="${2:?missing the hello guest binary}"
probe="${3:?missing the stack-probe guest binary}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
note() { printf '%s\n' "$*"; }
fail() {
  printf 'ASSERTION FAILED: %s\n' "$*" >&2
  failures=$((failures + 1))
}
check_contains() {
  local file="$1" pattern="$2" description="$3"
  if grep -q -- "$pattern" "$file"; then
    note "  ok: $description"
  else
    fail "$description (expected to find '$pattern' in $file)"
  fi
}

# The guest's own bytes, exactly as they appeared between the markers.
guest_stdout() {
  awk '/guest-stdout-begin/{flag=1;next}/guest-stdout-end/{flag=0}flag' "$1"
}

# ---------------------------------------------------------------------------- the platform
note "== probe"
"$runner" probe | tee "$work/probe.log"
check_contains "$work/probe.log" "can_run_guest=1" "the host can execute AArch64 guest code"
check_contains "$work/probe.log" "host_page_size=16384" \
  "the host uses 16 KiB pages, which is the condition this whole design exists for"
check_contains "$work/probe.log" "rx_mapping=ok" "a read-only/executable mapping can be made"
# `write_execute_mapping` is reported by the probe because it is interesting (Apple silicon refuses W+X
# for an unentitled process), but it is NOT asserted: the runtime never asks for such a mapping, so
# either answer is compatible with the design. Asserting it would be a claim about the kernel, not
# about the code under test.
if ! grep -q -- "write_execute_mapping=" "$work/probe.log"; then
  fail "the probe did not report write_execute_mapping"
fi

# ---------------------------------------------------------------------------- hello, no libc
note "== hello (freestanding, raw syscalls)"
set +e
"$runner" run "$hello" >"$work/hello.log" 2>&1
hello_status=$?
set -e
cat "$work/hello.log"

[ "$hello_status" -eq 0 ] || fail "the guest's exit status was $hello_status, expected 0"
check_contains "$work/hello.log" "patched_syscall_sites=2" \
  "exactly the two syscall sites we wrote (write and exit_group) were patched"
check_contains "$work/hello.log" "exit=normal status=0" "the guest ran to exit_group"

actual="$(guest_stdout "$work/hello.log")"
if [ "$actual" = "hello from aarch64 linux" ]; then
  note "  ok: the guest's stdout arrived byte for byte"
else
  fail "guest stdout was '$actual'"
fi

# ---------------------------------------------------------------------------- the initial stack
note "== stack probe (argc/argv/envp/auxv)"
set +e
"$runner" run "$probe" alpha beta >"$work/stack.log" 2>&1
stack_status=$?
set -e
cat "$work/stack.log"

[ "$stack_status" -eq 0 ] || fail "the stack probe exited with $stack_status, expected 0"
check_contains "$work/stack.log" "exit=normal status=0" "the stack probe ran to exit_group"
check_contains "$work/stack.log" "argc=3" "argc is 3 (the program plus two arguments)"
check_contains "$work/stack.log" "argv0=$probe" "argv[0] is the path the runner was given"
check_contains "$work/stack.log" "envp_entries=4" "the environment the runner set is visible to the guest"
check_contains "$work/stack.log" "pagesz=4096" \
  "the guest is told 4096, not the host's 16384 — the 16 KiB problem is handled"
check_contains "$work/stack.log" "auxv_entries=18" "the auxiliary vector is complete"
check_contains "$work/stack.log" "phnum=" "AT_PHNUM is present"

# ---------------------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall guest-run assertions passed\n'
