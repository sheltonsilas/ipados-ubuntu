import XCTest

@testable import UbuntuPadCore

final class GuestProcessTableTests: XCTestCase {
    func testRootHasIndependentLinuxResourceIdentities() {
        let table = GuestProcessTable(rootPID: 40)
        let root = table.task(40)
        XCTAssertEqual(root?.pid, 40)
        XCTAssertEqual(root?.threadGroupID, 40)
        XCTAssertEqual(root?.parentID, 0)
        XCTAssertEqual(root?.addressSpaceID, 40)
        XCTAssertEqual(root?.fileTableID, 40)
        XCTAssertEqual(root?.filesystemID, 40)
        XCTAssertEqual(root?.signalHandlersID, 40)
        XCTAssertEqual(table.liveTaskCount, 1)
    }

    func testForkLikeCloneGetsPrivateResourcesAndNewThreadGroup() throws {
        var table = GuestProcessTable(rootPID: 100)
        let child = try table.clone(parent: 100, flags: [])
        let parent = try XCTUnwrap(table.task(100))
        XCTAssertEqual(child.pid, 101)
        XCTAssertEqual(child.parentID, 100)
        XCTAssertEqual(child.threadGroupID, child.pid)
        XCTAssertNotEqual(child.addressSpaceID, parent.addressSpaceID)
        XCTAssertNotEqual(child.fileTableID, parent.fileTableID)
        XCTAssertNotEqual(child.filesystemID, parent.filesystemID)
        XCTAssertNotEqual(child.signalHandlersID, parent.signalHandlersID)
        XCTAssertTrue(child.pendingSignals.isEmpty)
        XCTAssertTrue(child.signalMask.isEmpty)
    }

    func testCloneVmSharesOnlyRequestedResources() throws {
        var table = GuestProcessTable(rootPID: 7)
        let flags: GuestCloneFlags = [.vm, .filesystem, .sighand]
        let child = try table.clone(parent: 7, flags: flags)
        let parent = try XCTUnwrap(table.task(7))
        XCTAssertEqual(child.addressSpaceID, parent.addressSpaceID)
        XCTAssertEqual(child.filesystemID, parent.filesystemID)
        XCTAssertEqual(child.signalHandlersID, parent.signalHandlersID)
        XCTAssertNotEqual(child.fileTableID, parent.fileTableID)
        XCTAssertNotEqual(child.threadGroupID, parent.threadGroupID)
    }

    func testThreadCloneSharesAddressSpaceAndGroupButCopiesFdTableUnlessRequested() throws {
        var table = GuestProcessTable(rootPID: 20)
        let flags: GuestCloneFlags = [.vm, .sighand, .thread]
        let thread = try table.clone(parent: 20, flags: flags)
        let parent = try XCTUnwrap(table.task(20))
        XCTAssertEqual(thread.addressSpaceID, parent.addressSpaceID)
        XCTAssertEqual(thread.threadGroupID, parent.threadGroupID)
        XCTAssertNotEqual(thread.fileTableID, parent.fileTableID)
        XCTAssertEqual(table.liveTaskCount, 2)
    }

    func testCloneFilesSharesTheDescriptorTableAndCloneSetTLSRecordsPointer() throws {
        var table = GuestProcessTable(rootPID: 1)
        let thread = try table.clone(
            parent: 1,
            flags: [.vm, .files, .sighand, .thread, .setTLS],
            tlsAddress: 0x7fff_1234)
        let parent = try XCTUnwrap(table.task(1))
        XCTAssertEqual(thread.fileTableID, parent.fileTableID)
        XCTAssertEqual(thread.tlsAddress, 0x7fff_1234)
    }

    func testCloneSetTLSWithoutFlagDoesNotInstallTLS() throws {
        var table = GuestProcessTable(rootPID: 1)
        let child = try table.clone(parent: 1, flags: [], tlsAddress: 0x7000)
        XCTAssertNil(child.tlsAddress)
    }

    func testInvalidThreadFlagCombinationsAreRejectedWithoutAddingTask() {
        var table = GuestProcessTable(rootPID: 1)
        XCTAssertThrowsError(try table.clone(parent: 1, flags: [.thread])) { error in
            XCTAssertEqual(error as? GuestProcessError, .invalidCloneFlags(GuestCloneFlags.thread.rawValue))
        }
        XCTAssertThrowsError(try table.clone(parent: 1, flags: [.vm, .thread]))
        XCTAssertThrowsError(try table.clone(parent: 1, flags: [.sighand]))
        XCTAssertEqual(table.tasks.count, 1)
    }

    func testUnsupportedCloneBitsAreRejectedRatherThanIgnored() {
        var table = GuestProcessTable(rootPID: 1)
        let unsupported: GuestCloneFlags = [.vm, GuestCloneFlags(rawValue: 0x0000_2000)] // CLONE_VFORK
        XCTAssertFalse(unsupported.isValid)
        XCTAssertThrowsError(try table.clone(parent: 1, flags: unsupported)) { error in
            XCTAssertEqual(error as? GuestProcessError, .invalidCloneFlags(unsupported.rawValue))
        }
        XCTAssertEqual(table.tasks.count, 1)
    }

    func testUnknownAndExitedParentsAreRejected() throws {
        var table = GuestProcessTable(rootPID: 3)
        XCTAssertThrowsError(try table.clone(parent: 9, flags: [])) {
            XCTAssertEqual($0 as? GuestProcessError, .unknownTask(9))
        }
        try table.exit(3, status: 0)
        XCTAssertThrowsError(try table.clone(parent: 3, flags: [])) {
            XCTAssertEqual($0 as? GuestProcessError, .taskAlreadyExited(3))
        }
    }

    func testExitedChildStaysZombieUntilDirectParentReapsIt() throws {
        var table = GuestProcessTable(rootPID: 10)
        let child = try table.clone(parent: 10, flags: [])
        try table.exit(child.pid, status: 257)
        XCTAssertEqual(table.task(child.pid)?.exitStatus, 1, "Linux exit status is the low byte")
        XCTAssertEqual(table.liveTaskCount, 1)
        XCTAssertNil(table.reap(parent: 99, child: child.pid))
        XCTAssertNil(table.reap(parent: 10, child: 10))
        XCTAssertEqual(table.reap(parent: 10, child: child.pid)?.pid, child.pid)
        XCTAssertNil(table.task(child.pid))
    }

    func testCannotExitTaskTwice() throws {
        var table = GuestProcessTable(rootPID: 5)
        try table.exit(5, status: 0)
        XCTAssertThrowsError(try table.exit(5, status: 1)) {
            XCTAssertEqual($0 as? GuestProcessError, .taskAlreadyExited(5))
        }
    }
}
