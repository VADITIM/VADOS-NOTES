import XCTest
@testable import NotesCore

final class GroupSyncTests: XCTestCase {
    let notebookId = "nb_01TEST"
    let pageId = "p_01TEST"
    let groupId = "g_01TEST"

    func makeStore(device: String) throws -> NotesStore {
        try NotesStore(directory: Fixtures.temporaryDirectory(), device: device)
    }

    func group(title: String = "Drafts", at seconds: Double = 0, device: String = "ipad-01", deleted: Bool = false) -> GroupRecord {
        GroupRecord(id: groupId, parent: notebookId, title: title, kind: .notes, order: 0, updated: Fixtures.time(seconds), device: device, deleted: deleted)
    }

    func testGroupRoundTripsThroughItsOwnFile() throws {
        let original = group()
        let decoded = try PageCodec.decodeGroup(try PageCodec.encodeGroup(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(RepositoryPath.group(groupId), "groups/g_01TEST.json")
        XCTAssertEqual(RepositoryPath.kind(of: "groups/g_01TEST.json"), .group(groupId: groupId))
    }

    func testRootGroupLeavesParentOut() throws {
        var root = group()
        root.parent = nil
        let text = String(decoding: try PageCodec.encodeGroup(root), as: UTF8.self)

        XCTAssertFalse(text.contains("parent"))
        XCTAssertNil(try PageCodec.decodeGroup(Data(text.utf8)).parent)
    }

    func testGroupWithWrongPrefixIsRejected() throws {
        var wrong = group()
        wrong.id = "nb_01TEST"

        XCTAssertThrowsError(try PageCodec.decodeGroup(try PageCodec.encodeGroup(wrong)))
    }

    func testPageHeaderCarriesItsGroupInSortedPlace() throws {
        var page = Fixtures.page()
        page.group = groupId
        let text = String(decoding: try PageCodec.encodePage(page), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)

        XCTAssertEqual(try PageCodec.decodePage(Data(text.utf8)).group, groupId)
        let groupLine = try XCTUnwrap(lines.firstIndex { $0.contains("\"group\"") })
        let idLine = try XCTUnwrap(lines.firstIndex { $0.contains("\"id\"") })
        XCTAssertLessThan(groupLine, idLine)
    }

    func testNewerGroupEditWinsAndDeletionWins() {
        let older = group(title: "Old", at: 1)
        let newer = group(title: "New", at: 2, device: "pc-01")
        let deleted = group(title: "Old", at: 0, deleted: true)

        XCTAssertEqual(Merge.group(older, newer).title, "New")
        XCTAssertEqual(Merge.group(newer, older).title, "New")
        XCTAssertTrue(Merge.group(newer, deleted).deleted)
    }

    func testHeaderMergeKeepsTheNewerMembership() {
        var older = Fixtures.page(at: 1).header
        older.group = groupId
        let newer = Fixtures.page(at: 2, device: "pc-01").header

        XCTAssertNil(Merge.header(older, newer).group)
        XCTAssertEqual(Merge.header(older, Fixtures.page(at: 0).header).group, groupId)
    }

    func testGroupAndMembershipReachAnotherDevice() async throws {
        let remote = MockRemote()
        let first = try makeStore(device: "ipad-01")
        try first.apply(.notebook(Notebook(id: notebookId, title: "Notes", updated: Fixtures.time(0), device: "ipad-01")))
        try first.apply(.group(group()))
        try first.apply(.page(PageHeader(id: pageId, notebook: notebookId, updated: Fixtures.time(0), device: "ipad-01", group: groupId)))

        let report = try await Synchronizer(store: first, remote: remote).synchronize()
        XCTAssertTrue(report.pushedPaths.contains("groups/g_01TEST.json"))

        let second = try makeStore(device: "pc-01")
        _ = try await Synchronizer(store: second, remote: remote).synchronize()

        XCTAssertEqual(second.liveGroups(in: notebookId).map(\.title), ["Drafts"])
        XCTAssertEqual(second.pages[pageId]?.group, groupId)
    }

    func testRenameOnOneDeviceAndUngroupOnAnotherBothLand() async throws {
        let remote = MockRemote()
        let first = try makeStore(device: "ipad-01")
        try first.apply(.notebook(Notebook(id: notebookId, title: "Notes", updated: Fixtures.time(0), device: "ipad-01")))
        try first.apply(.group(group()))
        _ = try await Synchronizer(store: first, remote: remote).synchronize()

        let second = try makeStore(device: "pc-01")
        _ = try await Synchronizer(store: second, remote: remote).synchronize()

        try first.apply(.group(group(title: "Renamed", at: 1)))
        try second.apply(.group(group(at: 2, device: "pc-01", deleted: true)))
        _ = try await Synchronizer(store: first, remote: remote).synchronize()
        _ = try await Synchronizer(store: second, remote: remote).synchronize()
        _ = try await Synchronizer(store: first, remote: remote).synchronize()

        XCTAssertEqual(first.liveGroups(in: notebookId), [])
        XCTAssertEqual(second.liveGroups(in: notebookId), [])
    }

    func testSnapshotReloadsGroupsFromDisk() async throws {
        let remote = MockRemote()
        let directory = Fixtures.temporaryDirectory()
        let store = try NotesStore(directory: directory, device: "ipad-01")
        try store.apply(.group(group()))
        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        let reopened = try NotesStore(directory: directory, device: "ipad-01")

        XCTAssertEqual(reopened.liveGroups(in: notebookId).map(\.id), [groupId])
    }
}
