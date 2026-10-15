#!/usr/bin/env bash
# Asserts that a built `ubuntupad-run` really executes guest programs, on a real Apple-silicon host.
#
# The point of asserting on stdout *between the runner's markers* is that a passing exit code proves
# nothing here: a runner that never enters the guest, or that prints the message itself, would still
# exit 0. Every check below is about bytes that could only have come from guest code running on the
# guest's own stack, at the base the runtime placed it at.
#
# Usage: tools/assert-guest-run.sh <ubuntupad-run> <hello-pie> <stack-probe> <hello-fixed-address>
#
#   hello-pie           a position-independent (ET_DYN) freestanding hello — the case that runs
#   stack-probe         a position-independent probe of argc/argv/envp/auxv
#   hello-fixed-address an ET_EXEC hello, used to show the runtime *refuses* it with a reason
set -euo pipefail

runner="${1:?usage: assert-guest-run.sh <ubuntupad-run> <hello-pie> <stack-probe> <hello-fixed-address>}"
hello="${2:?missing the position-independent hello guest binary}"
probe="${3:?missing the stack-probe guest binary}"
fixed="${4:?missing the fixed-address hello guest binary}"

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
# The platform fact this whole phase is built around: the running process has reserved the low 4 GiB,
# so a Linux image linked inside it (almost all of them are) cannot be mapped where it was linked.
check_contains "$work/probe.log" "reserved_low_region_bytes=4294967296" \
  "this process reserves the low 4 GiB, which is why guest images are placed at a bias"

# ---------------------------------------------------------------------------- hello, biased
note "== hello (position-independent, relocated by the runtime)"
set +e
"$runner" run "$hello" >"$work/hello.log" 2>&1
hello_status=$?
set -e
cat "$work/hello.log"

[ "$hello_status" -eq 0 ] || fail "the guest's exit status was $hello_status, expected 0"
check_contains "$work/hello.log" "patched_syscall_sites=2" \
  "exactly the two syscall sites we wrote (write and exit_group) were patched"
check_contains "$work/hello.log" "image_placement=biased" \
  "the image was placed at a bias instead of its link-time addresses"
check_contains "$work/hello.log" "exit=normal status=0" "the guest ran to exit_group"

# The relocation pass ran and did real work: it is what makes the guest's own data pointers valid.
applied="$(awk -F'applied=' '/relative_relocations=/{split($2, a, " "); print a[1]; exit}' "$work/hello.log")"
if [ -n "${applied:-}" ] && [ "${applied:-0}" -ge 1 ] 2>/dev/null; then
  note "  ok: $applied relative relocation(s) were applied to the image before mapping"
else
  fail "expected at least one applied relative relocation, found '${applied:-none}'"
fi

actual="$(guest_stdout "$work/hello.log")"
if [ "$actual" = "hello from a position-independent aarch64 linux" ]; then
  note "  ok: the guest's stdout arrived byte for byte"
else
  fail "guest stdout was '$actual'"
fi

# ---------------------------------------------------------------------------- the control
#
# The same guest, run with the relocation pass deliberately skipped. If the pass were decorative this
# would still print the message; it cannot, because the pointer it prints through is only correct once
# the load base has been added to it.
note "== the same guest, relocation pass skipped (control)"
set +e
"$runner" run --skip-relocations "$hello" >"$work/hello-unrelocated.log" 2>&1
unrelocated_status=$?
set -e
cat "$work/hello-unrelocated.log"

if [ "$unrelocated_status" -eq 0 ]; then
  fail "the unrelocated run succeeded, so the relocation pass is not what makes this guest work"
fi
if guest_stdout "$work/hello-unrelocated.log" | grep -q "hello from a position-independent"; then
  fail "the unrelocated run printed the message anyway"
else
  note "  ok: without relocation the guest does not reach its own data (exit $unrelocated_status)"
fi

# ---------------------------------------------------------------------------- the refusal
#
# A fixed-address image cannot run on this platform at all, and the runtime says so in the guest's own
# terms instead of mapping it somewhere its pointers do not point.
note "== fixed-address image (must be refused, with a reason)"
set +e
"$runner" run "$fixed" >"$work/fixed.log" 2>&1
fixed_status=$?
set -e
cat "$work/fixed.log"

[ "$fixed_status" -ne 0 ] || fail "a fixed-address image was accepted; it cannot be mapped on this host"
check_contains "$work/fixed.log" "fixed-address (ET_EXEC)" \
  "the refusal names the reason (a fixed-address executable)"
check_contains "$work/fixed.log" "position-independent" \
  "the refusal says what would work instead"

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

# AT_PHDR and AT_ENTRY are addresses in the *running* guest, so they must carry the bias. The probe
# prints AT_ENTRY; it cannot be the small link-time value once the image has been moved.
entry="$(awk -F'entry=' '/entry=0x/{split($2, a, " "); print a[1]; exit}' "$work/stack.log")"
if [ -n "${entry:-}" ]; then
  value=$((entry))
  if [ "$value" -ge 4294967296 ]; then
    note "  ok: AT_ENTRY ($entry) is a biased address above the reserved low region"
  else
    fail "AT_ENTRY is $entry, below the 4 GiB the image must have been moved above"
  fi
else
  fail "the stack probe did not report AT_ENTRY"
fi

# ---------------------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall guest-run assertions passed\n'
