/*
 * hello-nostdlib.c — the Phase 2 end-to-end probe: the smallest possible static AArch64 Linux program.
 *
 * It is freestanding (`-nostdlib`, no libc) on purpose. Every syscall it makes is written out in the
 * kernel's own calling convention, so when it prints its message the runtime has proved that it
 * patched a real `svc #0`, decoded a real syscall number and arguments, and resumed the guest at the
 * right instruction — with nothing between us and the CPU to hide a mistake.
 *
 * It also verifies the pointer: `write` is handed the address of a string that lives in the program's
 * own read-only data, which is only reachable if the guest was mapped where its link addresses say.
 *
 * Exit status is chosen so the runner can distinguish outcomes:
 *   0  wrote the whole message
 *   1  write returned something else (partial write or error)
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define MESSAGE_LENGTH 25
static const char message[] = "hello from aarch64 linux\n";

/*
 * `_start` is the ELF entry point. It has no frame and no libc: the kernel (and therefore our runtime)
 * hands control here with SP pointing at argc, and nothing else set up.
 */
__attribute__((naked, noreturn)) void _start(void) {
    __asm__ __volatile__(
        "adrp x1, message\n"
        "add  x1, x1, :lo12:message\n"
        "mov  x0, #1\n"          /* fd 1 = stdout */
        "mov  x2, #25\n"         /* sizeof(message) - 1 */
        "mov  x8, #64\n"         /* SYS_write */
        "svc  #0\n"
        "mov  x2, x0\n"          /* remember the result */
        "mov  x0, #0\n"          /* exit 0 */
        "cmp  x2, #25\n"
        "b.eq 1f\n"
        "mov  x0, #1\n"          /* short write: exit 1 */
        "1:\n"
        "mov  x8, #94\n"         /* SYS_exit_group */
        "svc  #0\n"
        "brk  #0\n");            /* unreachable */
}

/* Keeps the compiler from dropping the string when optimising. */
__attribute__((used)) static const char *keep_message(void) { return message; }
