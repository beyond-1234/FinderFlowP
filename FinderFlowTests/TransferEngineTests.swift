import XCTest

/// Tests for the transfer engine, focused on the cases that used to corrupt data or
/// abort a whole operation: symlinks, packages, cancellation cleanup and metadata.
final class TransferEngineTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func job() -> OperationJob {
        OperationJob(title: "test", detail: "")
    }

    private func transfer(_ sources: [URL], to destination: URL, mode: TransferEngine.Mode) throws -> [URL] {
        try TransferEngine.transfer(sources,
                                    to: destination,
                                    mode: mode,
                                    job: job(),
                                    pathAllocator: { $0 })
    }

    // MARK: Symlinks

    /// A link to a directory must be recreated as a link, not followed. Following it
    /// used to copy the whole target tree into the destination.
    func testCopiesDirectorySymlinkAsLink() throws {
        let target = root.appendingPathComponent("realFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "payload".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let link = root.appendingPathComponent("linkToFolder")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: target.path)

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        _ = try transfer([link], to: dest, mode: .copy)

        let copied = dest.appendingPathComponent("linkToFolder")
        let values = try copied.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        XCTAssertEqual(values.isSymbolicLink, true, "link must still be a link")
        XCTAssertNotEqual(values.isDirectory, true, "link must not become a real directory")

        // Verify the link *points* at the original rather than that its contents were
        // copied. `fileExists` follows links, so it cannot distinguish the two.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copied.path),
                       target.path,
                       "link must keep its original destination")
    }

    /// A dangling link used to abort the entire transfer because `fileExists` follows
    /// links and reported the source as missing.
    func testCopiesDanglingSymlinkWithoutFailing() throws {
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "/nonexistent/target")

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        XCTAssertNoThrow(try transfer([link], to: dest, mode: .copy))

        let copied = dest.appendingPathComponent("dangling")
        let values = try copied.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copied.path),
                       "/nonexistent/target")
    }

    // MARK: Metadata

    func testPreservesModificationDateAndPermissions() throws {
        let source = root.appendingPathComponent("file.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: date,
                                               .posixPermissions: 0o640],
                                              ofItemAtPath: source.path)

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let created = try transfer([source], to: dest, mode: .copy)

        let values = try XCTUnwrap(created.first)
            .resourceValues(forKeys: [.contentModificationDateKey, .posixPermissionsKey])
        XCTAssertEqual(values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                       1_000_000, accuracy: 1)
        XCTAssertEqual(values.posixPermissions, 0o640)
    }

    func testPreservesExtendedAttributes() throws {
        let source = root.appendingPathComponent("tagged.txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let name = "com.apple.metadata:_kMDItemUserTags"
        let payload = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30])
        let wrote = payload.withUnsafeBytes { buffer in
            setxattr(source.path, name, buffer.baseAddress, payload.count, 0, 0)
        }
        XCTAssertEqual(wrote, 0, "test setup failed to set an extended attribute")

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let created = try transfer([source], to: dest, mode: .copy)

        let copied = try XCTUnwrap(created.first).path
        let size = getxattr(copied, name, nil, 0, 0, 0)
        XCTAssertEqual(size, payload.count, "extended attribute must be carried over")
    }

    // MARK: Cancellation

    /// Cancelling mid-copy must not leave a partial file behind.
    func testCancelLeavesNoPartialFile() throws {
        let source = root.appendingPathComponent("big.bin")
        let data = Data(repeating: 0x41, count: 12 * 1024 * 1024)
        try data.write(to: source)

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let running = job()
        running.cancel()   // cancelled before the first chunk

        XCTAssertThrowsError(
            try TransferEngine.transfer([source], to: dest, mode: .copy,
                                        job: running, pathAllocator: { $0 })
        ) { error in
            guard case TransferEngine.TransferError.cancelled = error else {
                return XCTFail("expected .cancelled, got \(error)")
            }
        }

        let leftover = dest.appendingPathComponent("big.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "a cancelled copy must not leave a partial file")
    }

    // MARK: Move

    func testMoveRemovesSourceAndKeepsContent() throws {
        let source = root.appendingPathComponent("move-me.txt")
        try "content".write(to: source, atomically: true, encoding: .utf8)

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let created = try transfer([source], to: dest, mode: .move)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "source must be gone after a move")
        let moved = try XCTUnwrap(created.first)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "content")
    }

    func testMoveOfSymlinkRemovesLinkNotTarget() throws {
        let target = root.appendingPathComponent("real.txt")
        try "real".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: target.path)

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        _ = try transfer([link], to: dest, mode: .move)

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "moving a link must not delete what it points at")
    }

    // MARK: Sizing

    func testTotalSizeCountsNestedFiles() throws {
        let dir = root.appendingPathComponent("tree", isDirectory: true)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 2500).write(to: nested.appendingPathComponent("b.bin"))

        XCTAssertEqual(TransferEngine.totalSize(of: [dir]), 3500)
    }
}
