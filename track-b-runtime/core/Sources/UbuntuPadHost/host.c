/*
 * host.c — implementation of the machine-level half of Track B.
 *
 * See ubuntupad_host.h for the design. The short version: the guest's syscall instructions have been
 * replaced with `brk #0x123`, so a syscall shows up as a breakpoint trap; the handler reads the guest
 * registers out of the signal context, lets Swift decide what the syscall means, writes the result
 * into x0, skips the breakpoint and resumes the guest.
 */

#include "ubuntupad_host.h"

#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__) && defined(__arm64__)

#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/arm/thread_status.h>
#include <mach/mach.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* The breakpoint planted over every Linux syscall instruction: brk #0x123. */
#define UP_BREAKPOINT_SENTINEL 0xD4202460u

#define UP_GUEST_STACK_SIZE (256 * 1024)

static sigjmp_buf g_guest_return;
static volatile sig_atomic_t g_in_guest = 0;
static up_syscall_fn g_syscall_handler = NULL;
static void *g_syscall_context = NULL;
static int g_exit_status = 0;
static int g_exit_reason = UP_EXIT_NORMAL;
static int g_fault_signal = 0;
static uint64_t g_fault_address = 0;
static uint64_t g_last_trap_pc = 0;
static uint64_t g_last_trap_word = 0;

/* ------------------------------------------------------------------ primitives */

size_t up_page_size(void) {
    long value = sysconf(_SC_PAGESIZE);
    return value > 0 ? (size_t)value : 16384;
}

uint64_t up_total_memory(void) {
    uint64_t memory = 0;
    size_t size = sizeof(memory);
    int mib[2] = {CTL_HW, HW_MEMSIZE};
    if (sysctl(mib, 2, &memory, &size, NULL, 0) != 0) {
        return 0;
    }
    return memory;
}

static int g_mapping_errno = 0;

int up_last_mapping_errno(void) { return g_mapping_errno; }

void *up_reserve(uint64_t address, size_t length, int mode, uint64_t *address_out) {
    g_mapping_errno = 0;
    void *hint = address != 0 ? (void *)(uintptr_t)address : NULL;
    int flags = MAP_ANON | MAP_PRIVATE | (mode == UP_RESERVE_REPLACE ? MAP_FIXED : 0);
    void *mapping = mmap(hint, length, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (mapping == MAP_FAILED) {
        g_mapping_errno = errno;
        if (address_out) *address_out = 0;
        return NULL;
    }
    if (address_out) *address_out = (uint64_t)(uintptr_t)mapping;
    return mapping;
}

/*
 * The `__PAGEZERO` segment of the main executable: the kernel reserves it, so a plain mapping can never
 * land there. Read from the loaded image rather than assumed, because it is a property of how the
 * running binary was linked.
 */
uint64_t up_reserved_low_region_size(void) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (header == NULL || header->magic != MH_MAGIC_64) return 0;

    const struct load_command *command =
        (const struct load_command *)((const char *)header + sizeof(struct mach_header_64));
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__PAGEZERO", 16) == 0) {
                return segment->vmsize;
            }
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    return 0;
}

int up_protect(uint64_t address, size_t length, int bits) {
    int native = 0;
    if (bits & 1) native |= PROT_READ;
    if (bits & 2) native |= PROT_WRITE;
    if (bits & 4) native |= PROT_EXEC;
    int result = mprotect((void *)(uintptr_t)address, length, native);
    if (result != 0) g_mapping_errno = errno;
    return result;
}

int up_release(uint64_t address, size_t length) {
    int result = munmap((void *)(uintptr_t)address, length);
    if (result != 0) g_mapping_errno = errno;
    return result;
}

int up_random_bytes(void *destination, size_t length) {
    if (length == 0) return 0;
    /* Darwin's kernel-backed generator; no entropy file needed and it cannot block. */
    arc4random_buf(destination, length);
    return 0;
}

uint64_t up_monotonic_nanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

uint64_t up_wall_clock_nanoseconds(void) {
    struct timeval now;
    if (gettimeofday(&now, NULL) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_usec * 1000ull;
}

int up_can_run_guest(void) { return 1; }

int up_last_fault_signal(void) { return g_fault_signal; }
uint64_t up_last_fault_address(void) { return g_fault_address; }
uint64_t up_last_trap_pc(void) { return g_last_trap_pc; }

uint64_t up_guest_register(const up_registers_t *registers, int index) {
    if (registers == NULL || index < 0 || index > 30) return 0;
    return registers->x[index];
}

void up_set_guest_register(up_registers_t *registers, int index, uint64_t value) {
    if (registers == NULL || index < 0 || index > 30) return;
    registers->x[index] = value;
}

void up_set_syscall_handler(up_syscall_fn function, void *context) {
    g_syscall_handler = function;
    g_syscall_context = context;
}

void up_exit_guest(int status) {
    g_exit_status = status;
    g_exit_reason = UP_EXIT_NORMAL;
    siglongjmp(g_guest_return, 1);
}

/* ------------------------------------------------------------------ registers */

/*
 * The guest's own values are read and written as plain machine words on purpose. Guest code comes
 * from a Linux ELF compiled without pointer authentication, so `__pc`, `__fp` and `__lr` carry no
 * signature to strip — unlike the host's own pointers, which is why the SDK's arm_thread_state64_get_*
 * helpers exist for debuggers and are unnecessary (and would be misleading) here.
 */
static void up_read_registers(arm_thread_state64_t *state, up_registers_t *out) {
    for (int index = 0; index < 29; index++) {
        out->x[index] = state->__x[index];
    }
    out->x[29] = state->__fp;
    out->x[30] = state->__lr;
    out->sp = state->__sp;
    out->pc = state->__pc;
}

static void up_write_register_x0(arm_thread_state64_t *state, uint64_t value) {
    state->__x[0] = value;
}

/* ------------------------------------------------------------------ the trap handler */

static void up_handle_trap(int signal_number, siginfo_t *info, void *context) {
    ucontext_t *ucontext = (ucontext_t *)context;
    if (ucontext == NULL || ucontext->uc_mcontext == NULL) {
        return;
    }
    arm_thread_state64_t *state = &ucontext->uc_mcontext->__ss;
    uint64_t pc = state->__pc;
    g_last_trap_pc = pc;

    if (!g_in_guest) {
        /* A fault in our own code: restore the default behaviour instead of hiding a host bug. */
        signal(signal_number, SIG_DFL);
        raise(signal_number);
        _exit(128 + signal_number);
    }

    if (signal_number == SIGTRAP) {
        uint32_t word = *(uint32_t *)(uintptr_t)pc;
        g_last_trap_word = word;
        if (word != UP_BREAKPOINT_SENTINEL) {
            /* A genuine guest breakpoint (or a syscall instruction we failed to patch). Stop with a
             * reason that says so, rather than interpreting it as one of ours. */
            g_exit_reason = UP_EXIT_BREAKPOINT;
            g_exit_status = 0;
            siglongjmp(g_guest_return, 1);
        }

        up_registers_t registers;
        up_read_registers(state, &registers);
        if (g_syscall_handler != NULL) {
            /* The handler either calls up_exit_guest() (which does not return) or computes the
             * syscall result, which we place in x0 below. */
            g_syscall_handler(&registers, g_syscall_context);
        } else {
            registers.x[0] = (uint64_t)-38; /* -ENOSYS */
        }
        up_write_register_x0(state, registers.x[0]);
        /* `brk` reports the address of the breakpoint; the next instruction is the resumption point. */
        state->__pc = pc + 4;
        return;
    }

    /* Any other guest signal is fatal as far as Phase 2 is concerned: record where, and stop. */
    if (signal_number == SIGSEGV || signal_number == SIGBUS || signal_number == SIGILL
        || signal_number == SIGFPE) {
        g_fault_signal = signal_number;
        g_fault_address = (uint64_t)(uintptr_t)(info != NULL ? info->si_addr : NULL);
        g_exit_reason = UP_EXIT_SIGNAL;
        g_exit_status = signal_number;
        siglongjmp(g_guest_return, 1);
    }
}

/* The signals the guest can raise. Each one's previous disposition is saved separately, so the
 * process is put back exactly as it was even if only some of the installs succeeded. */
static const int up_guest_signals[] = {SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE};
#define UP_GUEST_SIGNAL_COUNT 5

static int up_install_handlers(struct sigaction *saved) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = up_handle_trap;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&action.sa_mask);

    for (int index = 0; index < UP_GUEST_SIGNAL_COUNT; index++) {
        if (sigaction(up_guest_signals[index], &action, &saved[index]) != 0) {
            for (int done = index - 1; done >= 0; done--) {
                sigaction(up_guest_signals[done], &saved[done], NULL);
            }
            return -1;
        }
    }
    return 0;
}

static void up_restore_handlers(struct sigaction *saved) {
    for (int index = 0; index < UP_GUEST_SIGNAL_COUNT; index++) {
        sigaction(up_guest_signals[index], &saved[index], NULL);
    }
}

/*
 * The switch into guest mode. A naked function so nothing of the C frame (not even the compiler's idea
 * of the stack) survives the jump: x0 holds the entry point and x1 the guest stack top.
 */
__attribute__((naked)) static void up_enter_guest(void) {
    __asm__ __volatile__("mov sp, x1\n"
                         "br x0\n");
}

int up_guest_run(uint64_t entry, uint64_t stack_top, int *status, int *reason) {
    struct sigaction saved[UP_GUEST_SIGNAL_COUNT];
    stack_t saved_stack;
    void *alternate = NULL;

    g_exit_status = 0;
    g_exit_reason = UP_EXIT_NORMAL;
    g_fault_signal = 0;
    g_fault_address = 0;

    /* The trap handler needs its own stack: the guest owns SP, and the handler must not write over the
     * guest's frames. */
    alternate = up_reserve(0, UP_GUEST_STACK_SIZE, UP_RESERVE_HINT, NULL);
    if (alternate == NULL) {
        if (status) *status = 0;
        if (reason) *reason = UP_EXIT_UNSUPPORTED;
        return UP_STATUS_MMAP_FAILED;
    }

    stack_t alternate_stack;
    alternate_stack.ss_sp = alternate;
    alternate_stack.ss_size = UP_GUEST_STACK_SIZE;
    alternate_stack.ss_flags = 0;
    if (sigaltstack(&alternate_stack, &saved_stack) != 0) {
        up_release((uint64_t)(uintptr_t)alternate, UP_GUEST_STACK_SIZE);
        if (status) *status = 0;
        if (reason) *reason = UP_EXIT_UNSUPPORTED;
        return UP_STATUS_SIGNAL_FAILED;
    }

    if (up_install_handlers(saved) != 0) {
        sigaltstack(&saved_stack, NULL);
        up_release((uint64_t)(uintptr_t)alternate, UP_GUEST_STACK_SIZE);
        if (status) *status = 0;
        if (reason) *reason = UP_EXIT_UNSUPPORTED;
        return UP_STATUS_SIGNAL_FAILED;
    }

    /* savemask = 1: siglongjmp must also restore the signal mask that was in effect here, otherwise
     * the guest's run would permanently change how the host process handles signals. */
    if (sigsetjmp(g_guest_return, 1) == 0) {
        g_in_guest = 1;
        up_enter_guest(entry, stack_top);
        /* up_enter_guest does not return. */
    }
    g_in_guest = 0;

    /* Restore the process's handlers and stack discipline before returning to Swift. */
    up_restore_handlers(saved);
    sigaltstack(&saved_stack, NULL);
    up_release((uint64_t)(uintptr_t)alternate, UP_GUEST_STACK_SIZE);

    if (status) *status = g_exit_status;
    if (reason) *reason = g_exit_reason;
    return g_exit_reason;
}

#else /* not Apple silicon: build the API, but nothing can run */

#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

size_t up_page_size(void) {
    long value = sysconf(_SC_PAGESIZE);
    return value > 0 ? (size_t)value : 4096;
}

uint64_t up_total_memory(void) { return 0; }

static int g_mapping_errno = 0;

int up_last_mapping_errno(void) { return g_mapping_errno; }

void *up_reserve(uint64_t address, size_t length, int mode, uint64_t *address_out) {
    g_mapping_errno = 0;
    int flags = MAP_ANON | MAP_PRIVATE | (mode == UP_RESERVE_REPLACE ? MAP_FIXED : 0);
    void *mapping =
        mmap(address != 0 ? (void *)(uintptr_t)address : NULL, length, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (mapping == MAP_FAILED) {
        g_mapping_errno = errno;
        if (address_out) *address_out = 0;
        return NULL;
    }
    if (address_out) *address_out = (uint64_t)(uintptr_t)mapping;
    return mapping;
}

/* Every Linux host here is 4 GiB of page zero at most; the meaningful answer is "no reserved region". */
uint64_t up_reserved_low_region_size(void) { return 0; }

int up_protect(uint64_t address, size_t length, int bits) {
    int native = 0;
    if (bits & 1) native |= PROT_READ;
    if (bits & 2) native |= PROT_WRITE;
    if (bits & 4) native |= PROT_EXEC;
    int result = mprotect((void *)(uintptr_t)address, length, native);
    if (result != 0) g_mapping_errno = errno;
    return result;
}

int up_release(uint64_t address, size_t length) {
    int result = munmap((void *)(uintptr_t)address, length);
    if (result != 0) g_mapping_errno = errno;
    return result;
}

int up_random_bytes(void *destination, size_t length) {
    if (length == 0) return 0;
    FILE *source = fopen("/dev/urandom", "rb");
    if (source == NULL) return -1;
    size_t read_bytes = fread(destination, 1, length, source);
    fclose(source);
    return read_bytes == length ? 0 : -1;
}

uint64_t up_monotonic_nanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

uint64_t up_wall_clock_nanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

/* Guest execution is Apple-silicon only in Phase 2; the runner reports this as "unrun". */
int up_can_run_guest(void) { return 0; }

int up_last_fault_signal(void) { return 0; }
uint64_t up_last_fault_address(void) { return 0; }
uint64_t up_last_trap_pc(void) { return 0; }

uint64_t up_guest_register(const up_registers_t *registers, int index) {
    if (registers == NULL || index < 0 || index > 30) return 0;
    return registers->x[index];
}

void up_set_guest_register(up_registers_t *registers, int index, uint64_t value) {
    if (registers == NULL || index < 0 || index > 30) return;
    registers->x[index] = value;
}

void up_set_syscall_handler(up_syscall_fn function, void *context) {
    (void)function;
    (void)context;
}

void up_exit_guest(int status) {
    (void)status;
    _exit(70);
}

int up_guest_run(uint64_t entry, uint64_t stack_top, int *status, int *reason) {
    (void)entry;
    (void)stack_top;
    if (status) *status = 0;
    if (reason) *reason = UP_EXIT_UNSUPPORTED;
    return UP_STATUS_NOT_ARM64;
}

#endif
