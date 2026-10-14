import Foundation
import XCTest

@testable import UbuntuPadCore

final class SyscallTableTests: XCTestCase {
    func testTableIsSelfConsistent() {
        var seenNumbers = Set<Int32>()
        var seenNames = Set<String>()
        for entry in SyscallTable.entries {
            XCTAssertTrue(
                seenNumbers.insert(entry.number).inserted,
                "duplicate syscall number \(entry.number) (\(entry.name))")
            XCTAssertTrue(
                seenNames.insert(entry.name).inserted,
                "duplicate syscall name \(entry.name)")
        }
    }

    func testLookupRoundTrips() {
        for entry in SyscallTable.entries {
            XCTAssertEqual(SyscallTable.name(for: entry.number), entry.name)
            XCTAssertEqual(SyscallTable.number(forName: entry.name), entry.number)
        }
        XCTAssertNil(SyscallTable.name(for: 9999))
        XCTAssertNil(SyscallTable.number(forName: "not_a_syscall"))
    }

    /// Phase 2 cannot start without these; fail loudly if a refactor drops one.
    func testRequiredPhaseTwoSyscallsArePresent() {
        let required = [
            "read", "write", "close", "openat", "mmap", "munmap", "mprotect", "brk",
            "exit", "exit_group", "clone", "execve", "futex", "wait4",
        ]
        for name in required {
            XCTAssertNotNil(SyscallTable.number(forName: name), "missing required syscall: \(name)")
        }
    }

    /// Pins the numbers exercised by the Phase 2 dispatcher to their documented values so a typo is
    /// caught in CI. Cross-checking against the kernel table is still a Phase 2 task.
    func testSpotCheckNumbers() {
        XCTAssertEqual(SyscallNumber.read, 63)
        XCTAssertEqual(SyscallNumber.write, 64)
        XCTAssertEqual(SyscallNumber.openat, 56)
        XCTAssertEqual(SyscallNumber.close, 57)
        XCTAssertEqual(SyscallNumber.mmap, 222)
        XCTAssertEqual(SyscallNumber.munmap, 215)
        XCTAssertEqual(SyscallNumber.mprotect, 226)
        XCTAssertEqual(SyscallNumber.brk, 214)
        XCTAssertEqual(SyscallNumber.exit, 93)
        XCTAssertEqual(SyscallNumber.exitGroup, 94)
        XCTAssertEqual(SyscallNumber.clone, 220)
        XCTAssertEqual(SyscallNumber.execve, 221)
        XCTAssertEqual(SyscallNumber.futex, 98)
        XCTAssertEqual(SyscallNumber.getpid, 172)
        XCTAssertEqual(SyscallNumber.wait4, 260)
    }
}
