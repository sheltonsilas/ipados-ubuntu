/*
 * stack-probe-nostdlib.c — Phase 2's second probe: does the guest see the process the runtime built
 * for it?
 *
 * A program that only prints a constant proves the loader works. This one proves the *process state*
 * works: it walks SP exactly as the Linux ABI specifies (argc, argv, NULL, envp, NULL, auxv pairs) and
 * prints what it found. If the initial stack were built wrongly — misaligned, missing the NULL
 * terminators, or with AT_PAGESZ reporting the host's 16 KiB page size instead of the guest's 4 KiB —
 * this prints the wrong thing or crashes, and the difference is visible in the output.
 *
 * No libc: formatting and the syscalls are written out by hand.
 */

typedef unsigned long u64;
typedef long i64;

#define SYS_write 64
#define SYS_exit_group 94

/* AT_* keys (see UbuntuPadCore.AuxiliaryVectorKey). */
#define AT_PHNUM 5
#define AT_PAGESZ 6
#define AT_ENTRY 9

static char output[256];

static long raw_syscall3(long number, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = number;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

__attribute__((noreturn)) static void raw_exit(long status) {
    register long x8 __asm__("x8") = SYS_exit_group;
    register long x0 __asm__("x0") = status;
    __asm__ __volatile__("svc #0" : : "r"(x8), "r"(x0) : "memory");
    __builtin_unreachable();
}

static int append_text(int position, const char *text) {
    while (*text) {
        output[position++] = *text++;
    }
    return position;
}

static int append_decimal(int position, u64 value) {
    char digits[24];
    int count = 0;
    if (value == 0) {
        output[position++] = '0';
        return position;
    }
    while (value > 0) {
        digits[count++] = (char)('0' + (value % 10));
        value /= 10;
    }
    while (count > 0) {
        output[position++] = digits[--count];
    }
    return position;
}

static int append_hexadecimal(int position, u64 value) {
    static const char alphabet[] = "0123456789abcdef";
    char digits[16];
    int count = 0;
    position = append_text(position, "0x");
    if (value == 0) {
        output[position++] = '0';
        return position;
    }
    while (value > 0) {
        digits[count++] = alphabet[value & 0xf];
        value >>= 4;
    }
    while (count > 0) {
        output[position++] = digits[--count];
    }
    return position;
}

void stack_probe(u64 *stack_pointer) {
    const u64 argc = stack_pointer[0];
    u64 *arguments = stack_pointer + 1;
    u64 *environment = arguments + argc + 1; /* argv is NULL-terminated */

    u64 *cursor = environment;
    while (*cursor != 0) {
        cursor++;
    }
    u64 *auxiliary = cursor + 1;

    u64 page_size = 0;
    u64 program_header_count = 0;
    u64 entry_point = 0;
    int auxiliary_entries = 0;
    for (u64 *entry = auxiliary; entry[0] != 0; entry += 2) {
        auxiliary_entries++;
        if (entry[0] == AT_PAGESZ) page_size = entry[1];
        if (entry[0] == AT_PHNUM) program_header_count = entry[1];
        if (entry[0] == AT_ENTRY) entry_point = entry[1];
    }

    int environment_count = 0;
    for (u64 *entry = environment; *entry != 0; entry++) {
        environment_count++;
    }

    int position = 0;
    position = append_text(position, "argc=");
    position = append_decimal(position, argc);
    position = append_text(position, " argv0=");
    position = append_text(position, (const char *)arguments[0]);
    position = append_text(position, " envp_entries=");
    position = append_decimal(position, (u64)environment_count);
    position = append_text(position, " pagesz=");
    position = append_decimal(position, page_size);
    position = append_text(position, " phnum=");
    position = append_decimal(position, program_header_count);
    position = append_text(position, " auxv_entries=");
    position = append_decimal(position, (u64)auxiliary_entries);
    position = append_text(position, " entry=");
    position = append_hexadecimal(position, entry_point);
    position = append_text(position, "\n");

    raw_syscall3(SYS_write, 1, (long)output, position);
    raw_exit(0);
}

/* The ELF entry point: hand SP to the probe, which never returns. */
__attribute__((naked, noreturn)) void _start(void) {
    __asm__ __volatile__(
        "mov x0, sp\n"
        "b   stack_probe\n");
}
