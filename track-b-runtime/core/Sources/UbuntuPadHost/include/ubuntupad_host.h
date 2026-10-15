/*
 * ubuntupad_host.h — the unavoidable machine-level part of Track B.
 *
 * Everything here exists because Swift cannot express it: `mmap`, switching the stack pointer, and
 * reacting to a hardware breakpoint trap from inside a POSIX signal handler. The policy that decides
 * what each syscall *means* lives in Swift (`SyscallDispatcher`); this file only carries it out.
 *
 * Design: the guest's `svc #0` instructions are replaced with `brk #0x123` before the guest runs (see
 * `AArch64Instruction.breakpointSentinel`). The trap lands in `up_handle_trap`, which reads the guest
 * registers out of the signal context, calls the Swift callback, writes the result back into x0,
 * advances the program counter past the breakpoint, and returns — resuming the guest as if nothing
 * had happened. No generated code, no JIT, no writable-and-executable pages.
 */
#ifndef UBUNTUPAD_HOST_H
#define UBUNTUPAD_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Plain macros rather than enums: this is the C/Swift boundary, and Swift's import of a C enum type
 * (as an enum or as a raw-value struct) has changed between toolchain versions. Integer macros import
 * unambiguously, and the Swift side wraps each one in `Int32(...)` so the constant's width cannot
 * change the meaning.
 */

/* Reasons `up_guest_run` returns. The status code itself is a plain int. */
/* The guest called exit/exit_group; `*status` holds its status. */
#define UP_EXIT_NORMAL 0
/* The guest took a fatal signal (bad memory access, illegal instruction); `*status` is the signal. */
#define UP_EXIT_SIGNAL 1
/* The guest executed a `brk` that was not one of our syscall sites. */
#define UP_EXIT_BREAKPOINT 2
/* This host cannot run guest code (not Apple silicon, or not implemented). */
#define UP_EXIT_UNSUPPORTED 3

/* Infrastructure failures returned by `up_guest_run` instead of a reason. */
#define UP_STATUS_MMAP_FAILED (-1)
#define UP_STATUS_MPROTECT_FAILED (-2)
#define UP_STATUS_NOT_ARM64 (-3)
#define UP_STATUS_SIGNAL_FAILED (-5)

/* ------------------------------------------------------------------ memory */

/* The host's own page size (16384 on Apple silicon, 4096 on most Linux). */
size_t up_page_size(void);

/* Total physical memory in bytes, or 0 when unknown. */
uint64_t up_total_memory(void);

/*
 * Reserves `length` bytes of anonymous, readable and writable memory, asking for `address`.
 *
 *   UP_RESERVE_HINT  the address is a hint. If it is occupied the mapping lands elsewhere and
 *                    `*address_out` says where. Nothing is ever silent: the caller compares
 *                    `*address_out` with what it asked for and refuses to continue on a mismatch.
 *
 * There is deliberately no `MAP_FIXED` mode. The only place forcing an address would ever have helped
 * is the host's reserved low region, and locking an address there does not work: the kernel reserves
 * that range for the whole process, so a forced mapping in it fails (and shrinking the reservation at
 * link time produces a binary the kernel kills at startup). The runtime instead places the guest image
 * somewhere it *can* live — see `ImagePlacement` in UbuntuPadCore and DECISIONS.md decision 0019.
 *
 * Returns NULL on failure; `up_last_mapping_errno()` then explains why.
 */
#define UP_RESERVE_HINT 0
void *up_reserve(uint64_t address, size_t length, int mode, uint64_t *address_out);

/*
 * The size of the host's reserved low memory region — macOS arm64 lays out a 4 GiB `__PAGEZERO` at the
 * bottom of every arm64 process, which is why a Linux executable linked at its usual 0x400000 cannot be
 * mapped at its own addresses. The placement planner consumes this number; the host layer only reports
 * it. Returns 0 when the host has no such region (Linux).
 */
uint64_t up_reserved_low_region_size(void);

/* errno from the last failed up_reserve/up_protect/up_release call. */
int up_last_mapping_errno(void);

/* Changes protection on already-reserved memory. `bits` are POSIX PROT_READ/WRITE/EXEC values. */
int up_protect(uint64_t address, size_t length, int bits);

/* Releases reserved memory. Returns 0 on success. */
int up_release(uint64_t address, size_t length);

/* Cryptographic-quality random bytes. Returns 0 on success. */
int up_random_bytes(void *destination, size_t length);

/* Nanoseconds from the host's monotonic and wall clocks. */
uint64_t up_monotonic_nanoseconds(void);
uint64_t up_wall_clock_nanoseconds(void);

/* 1 when this host can execute AArch64 guest code. */
int up_can_run_guest(void);

/* ------------------------------------------------------------------ guest registers */

/*
 * The AArch64 general-purpose register file: x0...x30 (31 entries), then SP and PC. x29 is the frame
 * pointer and x30 the link register, which is why there are 31 and not 32.
 */
typedef struct {
    uint64_t x[31];
    uint64_t sp;
    uint64_t pc;
} up_registers_t;

/*
 * Register access by index (0...30), for callers that cannot index a C array — Swift imports a
 * `uint64_t x[31]` as a 31-element tuple, which is unusable in a loop.
 */
uint64_t up_guest_register(const up_registers_t *registers, int index);
void up_set_guest_register(up_registers_t *registers, int index, uint64_t value);

/*
 * The Swift syscall service. It receives the guest registers and must write the syscall result into
 * x0 (index 0) — an already-encoded value, negative for errors — or call up_exit_guest() to end the
 * program.
 *
 * This runs inside a signal handler: it must not allocate in a way that could block, and it must not
 * return normally after calling up_exit_guest (which does not return).
 */
typedef void (*up_syscall_fn)(up_registers_t *registers, void *context);

void up_set_syscall_handler(up_syscall_fn function, void *context);

/* Ends the guest program from inside the syscall handler. Does not return. */
void up_exit_guest(int status) __attribute__((noreturn));

/* The signal and address of the last fatal guest fault, for diagnostics (0 when none). */
int up_last_fault_signal(void);
uint64_t up_last_fault_address(void);

/* The last guest program counter seen by the trap handler. */
uint64_t up_last_trap_pc(void);

/*
 * Runs the guest: installs the trap handlers, switches to `stack_top`, and branches to `entry`.
 * Returns one of the UP_EXIT_* reasons on a normal end, or a negative UP_STATUS_* value when the
 * runtime itself failed to start. The guest's exit status (or fatal signal) is written to `*status`.
 * Only call this once per process.
 */
int up_guest_run(uint64_t entry, uint64_t stack_top, int *status, int *reason);

#ifdef __cplusplus
}
#endif

#endif /* UBUNTUPAD_HOST_H */
