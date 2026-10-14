/*
 * hello.c — the Track B probe program.
 *
 * Phase 0: CI cross-compiles this statically for aarch64 with gcc-aarch64-linux-gnu and points
 *          UBUNTUPAD_TEST_BINARY at it so the ELF parser is tested against a real Ubuntu binary
 *          rather than only a synthetic fixture.
 * Phase 2: this is the first program the runtime should execute end to end; `swift test` will
 *          assert that its stdout arrives through our own `write` implementation.
 *
 * It is written to use only the syscalls Phase 2 implements first: write(2) and exit.
 */

#include <unistd.h>

int main(void) {
    static const char message[] = "hello from aarch64 linux\n";
    const size_t length = sizeof(message) - 1;
    ssize_t written = write(1, message, length);
    if (written != (ssize_t)length) {
        return 1;
    }
    return 0;
}
