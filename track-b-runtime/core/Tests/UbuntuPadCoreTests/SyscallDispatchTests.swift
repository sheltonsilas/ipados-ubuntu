import Foundation
import XCTest

@testable import UbuntuPadCore

final class SyscallDispatchTests: XCTestCase {
    private var host: FakeGuestHost!

    override func setUp() {
        super.setUp()
        host = FakeGuestHost()
    }

    override func tearDown() {
        host = nil
        super.tearDown()
    }

    private func request(_ number: Int32, _ arguments: UInt64...) -> SyscallRequest {
        var values = arguments
        while values.count < SyscallRequest.argumentCount { values.append(0) }
        return SyscallRequest(rawNumber: Int64(number), arguments: values)
    }

    // MARK: - register decoding

    func testDecodesRegistersTheLinuxWayNumberInX8ArgumentsInX0ToX5() {
        var registers = GuestRegisterFile()
        registers[8] = 64  // write
        registers[0] = 1
        registers[1] = 0x40_1000
        registers[2] = 13

        let request = SyscallRequest(registers: registers)
        XCTAssertEqual(request.number, SyscallNumber.write)
        XCTAssertEqual(request.name, "write")
        XCTAssertEqual(request.argument(0), 1)
        XCTAssertEqual(request.argument(1), 0x40_1000)
        XCTAssertEqual(request.argument(2), 13)
        XCTAssertEqual(request.argument(3), 0)
    }

    func testWritesResultToX0() {
        var registers = GuestRegisterFile()
        registers[8] = UInt64(bitPattern: Int64(SyscallNumber.getpid))
        let dispatcher = SyscallDispatcher.standardPhase2()

        _ = dispatcher.handle(registers: &registers, host: host)
        XCTAssertEqual(registers[0], UInt64(host.processIdentifier))
    }

    func testFailureBecomesNegativeErrnoInX0() {
        var registers = GuestRegisterFile()
        registers[8] = UInt64(bitPattern: Int64(SyscallNumber.write))
        registers[0] = 9  // not a console fd
        registers[1] = FakeGuestHost.base
        registers[2] = 4
        let dispatcher = SyscallDispatcher.standardPhase2()

        let outcome = dispatcher.handle(registers: &registers, host: host)
        XCTAssertEqual(outcome, .failure(.EBADF))
        XCTAssertEqual(Int64(bitPattern: registers[0]), -9, "-EBADF is -9 in the guest")
    }

    // MARK: - write and read

    func testWriteSendsGuestMemoryToTheConsole() throws {
        host.store("hi\n", at: 0x100)
        let dispatcher = SyscallDispatcher.standardPhase2()

        let outcome = dispatcher.dispatch(
            request(SyscallNumber.write, 1, FakeGuestHost.base + 0x100, 3), host: host)

        XCTAssertEqual(outcome, .result(3))
        XCTAssertEqual(host.consoleText, "hi\n")
        XCTAssertEqual(dispatcher.trace.count(of: SyscallNumber.write), 1)
    }

    func testWriteToAFileDescriptorWeDoNotHave() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.write, 9, FakeGuestHost.base, 4), host: host),
            .failure(.EBADF))
    }

    func testWriteWithAnUnmappedBufferIsFaultedNotCrashing() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.write, 1, 0xdead_0000, 16), host: host),
            .failure(.EFAULT))
    }

    func testWriteOfZeroBytesSucceedsWithoutTouchingMemory() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.write, 1, 0xdead_0000, 0), host: host),
            .result(0))
    }

    func testAbsurdWriteLengthIsRefusedRatherThanWrapping() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(
                request(SyscallNumber.write, 1, FakeGuestHost.base, UInt64(1) << 40), host: host),
            .failure(.EINVAL))
    }

    func testReadReportsEndOfFileBecauseThereIsNoTerminalYet() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.read, 0, FakeGuestHost.base, 64), host: host),
            .result(0))
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.read, 3, FakeGuestHost.base, 64), host: host),
            .failure(.EBADF))
    }

    // MARK: - exit

    func testExitIsSignalledToTheHostNotReturnedToTheGuest() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        let outcome = dispatcher.dispatch(request(SyscallNumber.exitGroup, 7), host: host)

        XCTAssertEqual(outcome, .exit(status: 7))
        XCTAssertTrue(outcome.isExit)
        XCTAssertEqual(dispatcher.exitStatus, 7)
        XCTAssertNil(dispatcher.trace.unknownNumbers.first, "exit is implemented, not unknown")
    }

    func testExitStatusIsTruncatedToTheLowByteLikeLinux() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.exit, 0x1_01), host: host), .exit(status: 257))
    }

    // MARK: - memory syscalls

    func testAnonymousPrivateMmapIsSupported() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        // PROT_READ|PROT_WRITE = 3, MAP_PRIVATE|MAP_ANONYMOUS = 0x22
        let outcome = dispatcher.dispatch(request(SyscallNumber.mmap, 0, 0x1000, 3, 0x22), host: host)
        guard case let .result(address) = outcome else { return XCTFail("expected success: \(outcome)") }
        XCTAssertGreaterThan(address, 0)
        XCTAssertEqual(host.guestMappings.count, 1)
        XCTAssertEqual(host.guestMappings[0].protection, .readWrite)
    }

    func testMmapRefusesSharedAndFileBackedMappingsHonestly() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        // MAP_SHARED (0x1) with a file descriptor: there is no filesystem yet.
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mmap, 0, 0x1000, 3, 0x1, 3, 0), host: host),
            .failure(.EINVAL))
        // MAP_PRIVATE without MAP_ANONYMOUS is a file mapping too.
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mmap, 0, 0x1000, 3, 0x2, 3, 0), host: host),
            .failure(.EINVAL))
    }

    func testMmapRefusesAnUnknownProtectionBit() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        // PROT_GROWSDOWN (0x01000000) is a Linux flag we do not implement.
        XCTAssertEqual(
            dispatcher.dispatch(
                request(SyscallNumber.mmap, 0, 0x1000, 0x0100_0003, 0x22), host: host),
            .failure(.EINVAL))
    }

    func testMmapAndMprotectRejectZeroLength() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mmap, 0, 0, 3, 0x22), host: host), .failure(.EINVAL))
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mprotect, FakeGuestHost.base, 0, 1), host: host),
            .failure(.EINVAL))
    }

    func testMprotectOfUnmappedMemoryIsOutOfMemory() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mprotect, 0xdead_0000, 0x1000, 3), host: host),
            .failure(.ENOMEM))
    }

    func testMprotectUsesLinuxProtBitsNotELFFlags() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        // PROT_READ|PROT_EXEC = 5. If this were decoded as ELF flags it would mean write|read.
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.mprotect, FakeGuestHost.base, 0x1000, 5), host: host),
            .result(0))
        XCTAssertEqual(host.protectionRequests.first?.protection, .readExecute)
    }

    func testBrkReturnsTheBreakInEffect() {
        host.writableProgramBreak = 0x50_0000
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.brk, 0x50_0000), host: host), .result(0x50_0000))
        XCTAssertEqual(host.programBreak, 0x50_0000)
    }

    // MARK: - information syscalls

    func testUnameWritesSixSixtyFiveByteFields() throws {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.uname, FakeGuestHost.base + 0x200), host: host),
            .result(0))

        let bytes = host.load(offset: 0x200, count: 65 * 6)
        func field(_ index: Int) -> String {
            let slice = bytes[(index * 65)..<((index + 1) * 65)]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(field(0), "Linux")
        XCTAssertEqual(field(4), "aarch64")
        XCTAssertEqual(field(5), "(none)")
    }

    func testUnameFailsWhenTheStructIsNotMapped() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.uname, 0xdead_0000), host: host), .failure(.EFAULT))
    }

    func testClockGetTimeWritesSecondsAndNanoseconds() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        // CLOCK_MONOTONIC = 1
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.clockGetTime, 1, FakeGuestHost.base + 0x300), host: host),
            .result(0))

        XCTAssertEqual(host.loadLE(offset: 0x300), 0)
        XCTAssertEqual(host.loadLE(offset: 0x308), 123_456_789)

        // CLOCK_REALTIME = 0 uses the wall clock.
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.clockGetTime, 0, FakeGuestHost.base + 0x300), host: host),
            .result(0))
        XCTAssertEqual(host.loadLE(offset: 0x300), 1_700_000_000)
    }

    func testClockGetTimeRejectsAnUnknownClock() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.clockGetTime, 42, FakeGuestHost.base), host: host),
            .failure(.EINVAL))
    }

    func testGetrandomFillsTheGuestBuffer() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.getrandom, FakeGuestHost.base + 0x400, 8), host: host),
            .result(8))
        XCTAssertEqual(host.load(offset: 0x400, count: 8), [0, 1, 2, 3, 4, 5, 6, 7])
    }

    func testGetrandomFaultsOnUnmappedMemory() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.getrandom, 0xdead_0000, 8), host: host),
            .failure(.EFAULT))
    }

    func testGetcwdReportsTheSingleRootDirectory() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.getcwd, FakeGuestHost.base + 0x500, 16), host: host),
            .result(2))
        XCTAssertEqual(host.load(offset: 0x500, count: 2), Array("/\0".utf8))
        // ERANGE when the guest buffer cannot hold "/\0".
        XCTAssertEqual(
            dispatcher.dispatch(request(SyscallNumber.getcwd, FakeGuestHost.base + 0x500, 1), host: host),
            .failure(.ERANGE))
    }

    // MARK: - the ENOSYS contract

    func testUnknownSyscallFailsWithEnosysAndIsRecorded() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        let outcome = dispatcher.dispatch(request(9999), host: host)

        XCTAssertEqual(outcome, .failure(.ENOSYS))
        XCTAssertEqual(dispatcher.trace.unknownNumbers, [9999])
        XCTAssertTrue(dispatcher.trace.summary().contains("unimplemented=syscall 9999 (9999)"))
    }

    /// The work list for the next session is produced by running real programs: whatever answers
    /// ENOSYS is exactly what is missing.
    func testDeliberateNonGoalsAnswerEnosys() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        for number in [
            SyscallNumber.futex, SyscallNumber.clone, SyscallNumber.execve,
            SyscallNumber.openat, SyscallNumber.fstat, SyscallNumber.socket,
        ] {
            XCTAssertEqual(
                dispatcher.dispatch(request(number), host: host), .failure(.ENOSYS),
                "\(SyscallTable.name(for: number) ?? "\(number)") should be an explicit ENOSYS")
        }
        XCTAssertEqual(dispatcher.trace.unknownNumbers.count, 6)
    }

    /// Every implemented syscall must exist in the curated table, so the trace and the docs cannot
    /// drift from the code.
    func testEveryImplementedSyscallIsInTheTable() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        let known = Set(SyscallTable.entries.map(\.number))
        for number in dispatcher.implementedNumbers {
            XCTAssertTrue(known.contains(number), "syscall \(number) is implemented but not in SyscallTable")
        }
    }

    func testTraceSummaryListsCountsInDescendingOrder() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        _ = dispatcher.dispatch(request(SyscallNumber.getpid), host: host)
        _ = dispatcher.dispatch(request(SyscallNumber.getpid), host: host)
        _ = dispatcher.dispatch(request(SyscallNumber.gettid), host: host)

        let summary = dispatcher.trace.summary()
        XCTAssertTrue(summary.contains("syscall_total=3"))
        let getpidLine = summary.split(separator: "\n").first { $0.contains("getpid") }
        XCTAssertEqual(getpidLine.map(String.init), "syscall_count getpid (172) = 2")
        XCTAssertEqual(dispatcher.trace.total, 3)
    }

    func testTraceKeepsARingBufferOfRecentEvents() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        for _ in 0..<(SyscallTrace.ringCapacity + 10) {
            _ = dispatcher.dispatch(request(SyscallNumber.getpid), host: host)
        }
        XCTAssertEqual(dispatcher.trace.total, SyscallTrace.ringCapacity + 10)
        XCTAssertEqual(dispatcher.trace.events.count, SyscallTrace.ringCapacity)
        XCTAssertEqual(dispatcher.trace.events.first?.sequence, 11, "oldest event kept in the ring")
        XCTAssertEqual(dispatcher.trace.events.last?.sequence, SyscallTrace.ringCapacity + 10)
    }

    func testTraceRecordsOutcomeText() {
        let dispatcher = SyscallDispatcher.standardPhase2()
        _ = dispatcher.dispatch(request(SyscallNumber.write, 9, FakeGuestHost.base, 4), host: host)
        XCTAssertEqual(dispatcher.trace.events.last?.outcome, "= -EBADF")
    }
}
