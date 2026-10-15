/*
 * hello-pie-nostdlib.c — the Phase 2 end-to-end probe for the *position-independent* path.
 *
 * `hello-nostdlib.c` is linked at a fixed address, which is exactly what cannot run on Apple silicon:
 * the low 4 GiB is `__PAGEZERO` there, and an ET_EXEC image has no relocation information that would
 * let it live anywhere else. Ubuntu's own binaries are position-independent (ET_DYN/PIE), so that is
 * the path real programs take, and this probe is what CI actually executes.
 *
 * The point of this program is that printing the message *requires* the runtime's relocation pass:
 *
 *   - `message_pointer` is a global pointer holding the address of `message`, an absolute address the
 *     linker cannot know in a PIE. It therefore emits an `R_AARCH64_RELATIVE` relocation, and the value
 *     in the file is only correct once the load base is added to it.
 *   - the pointer is `volatile`, so the compiler has to load it from memory instead of folding it away.
 *
 * Run this image with the relocation pass skipped and it dereferences a small unmapped address instead
 * of its own data — which is how CI shows the pass is load-bearing rather than decorative. That is also
 * why nothing here is written in assembly: the load through the pointer must be the compiler's.
 *
 * Exit status, so the runner can tell outcomes apart:
 *   0  wrote the whole message
 *   1  write returned something else (partial write or error)
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define SYS_write 64
#define SYS_exit_group 94

static const char message[] = "hello from a position-independent aarch64 linux\n";

/* The relocated global: an absolute pointer that is wrong until the load base is added. */
static const char *volatile message_pointer = message;

static long write_message(void) {
    const char *text = message_pointer;
    long length = 0;
    while (text[length] != '\0') {
        length++;
    }

    register long x0 __asm__("x0") = 1; /* fd 1 = stdout */
    register const char *x1 __asm__("x1") = text;
    register long x2 __asm__("x2") = length;
    register long x8 __asm__("x8") = SYS_write;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

/*
 * The ELF entry point. It has no frame and no libc: the kernel (and therefore our runtime) hands
 * control here with SP pointing at argc, and nothing else set up.
 */
__attribute__((noreturn)) void _start(void) {
    const long written = write_message();

    register long x0 __asm__("x0") = (written == (long)(sizeof(message) - 1)) ? 0 : 1;
    register long x8 __asm__("x8") = SYS_exit_group;
    __asm__ __volatile__("svc #0" : : "r"(x0), "r"(x8) : "memory");
    __builtin_unreachable();
}
