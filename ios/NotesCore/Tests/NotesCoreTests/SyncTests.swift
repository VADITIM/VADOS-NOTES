import XCTest
@testable import NotesCore

final class SyncTests: XCTestCase {
    let notebookId = "nb_01TEST"
    let pageId = "p_01TEST"
    var pagePath: String { RepositoryPath.page(notebook: notebookId, page: pageId) }

    func makeStore(device: String) throws -> NotesStore {
        try NotesStore(directory: Fixtures.temporaryDirectory(), device: device)
    }

    func seed(_ store: NotesStore) throws {
        try store.apply(.notebook(Notebook(id: notebookId, title: "Notes", updated: Fixtures.time(0), device: store.device)))
        try store.apply(.page(PageHeader(id: pageId, notebook: notebookId, updated: Fixtures.time(0), device: store.device)))
    }

    func testFirstSyncInitialisesTheBranchAndPushesEveryChangedFile() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))

        let report = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(report.pushedPaths, [RepositoryPath.notebook(notebookId), pagePath])
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.map(\.id), ["e_A"])
        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertEqual(store.syncState.head, remote.branches["main"])
        XCTAssertNotNil(store.syncState.lastSynced)
    }

    func testAllDirtyPagesLandInOneCommit() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        try store.apply(.page(PageHeader(id: "p_01SECOND", notebook: notebookId, updated: Fixtures.time(0), device: "ipad-01")))
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))
        try store.apply(.element(pageId: "p_01SECOND", element: Fixtures.stroke("e_B", at: 1)))

        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        let head = try XCTUnwrap(remote.branches["main"])
        XCTAssertEqual(remote.commits[head]?.files.count, 3)
        XCTAssertEqual(remote.commits.count, 2)
    }

    func testNothingToPushMakesNoCommit() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        let synchronizer = Synchronizer(store: store, remote: remote)
        _ = try await synchronizer.synchronize()
        let head = remote.branches["main"]

        let report = try await synchronizer.synchronize()

        XCTAssertEqual(report.pushedPaths, [])
        XCTAssertEqual(remote.branches["main"], head)
    }

    func testRejectedPushBacksOffPullsAndRetries() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))
        remote.rejectionsRemaining = 2
        var sleeps: [Double] = []

        let report = try await Synchronizer(store: store, remote: remote, sleep: { sleeps.append($0) }).synchronize()

        XCTAssertEqual(sleeps, [1, 2])
        XCTAssertEqual(report.attempts, 3)
        XCTAssertNotNil(remote.file(pagePath))
        XCTAssertTrue(store.journal.isEmpty)
    }

    func testEditsFromAnotherDeviceArePulledAndMerged() async throws {
        let remote = MockRemote()
        let ipad = try makeStore(device: "ipad-01")
        try seed(ipad)
        _ = try await Synchronizer(store: ipad, remote: remote).synchronize()

        let computer = try makeStore(device: "pc-01")
        _ = try await Synchronizer(store: computer, remote: remote).synchronize()
        try computer.apply(.element(pageId: pageId, element: Fixtures.stroke("e_PC", at: 5, device: "pc-01")))

        try ipad.apply(.element(pageId: pageId, element: Fixtures.stroke("e_IPAD", at: 6)))
        let computerSynchronizer = Synchronizer(store: computer, remote: remote)
        _ = try await computerSynchronizer.synchronize()

        let report = try await Synchronizer(store: ipad, remote: remote).synchronize()
        _ = try await computerSynchronizer.synchronize()

        XCTAssertEqual(report.pulledPaths, [pagePath])
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.map(\.id).sorted(), ["e_IPAD", "e_PC"])
        XCTAssertEqual(ipad.pages[pageId]?.liveElements.map(\.id).sorted(), ["e_IPAD", "e_PC"])
        XCTAssertEqual(computer.pages[pageId]?.liveElements.map(\.id).sorted(), ["e_IPAD", "e_PC"])
    }

    func testRaceBetweenCommitAndRefUpdateIsRetriedWithBothChanges() async throws {
        let remote = MockRemote()
        let ipad = try makeStore(device: "ipad-01")
        try seed(ipad)
        _ = try await Synchronizer(store: ipad, remote: remote).synchronize()
        try ipad.apply(.element(pageId: pageId, element: Fixtures.stroke("e_IPAD", at: 6)))

        var remotePage = try XCTUnwrap(ipad.pages[pageId])
        remotePage.elements = [Fixtures.stroke("e_PC", at: 5, device: "pc-01")]
        let remoteData = try PageCodec.encodePage(remotePage)
        remote.beforeMove = { [pagePath] in
            remote.writeExternally(branch: "main", files: [pagePath: remoteData])
        }
        var sleeps: [Double] = []

        let report = try await Synchronizer(store: ipad, remote: remote, sleep: { sleeps.append($0) }).synchronize()

        XCTAssertEqual(sleeps, [1])
        XCTAssertEqual(report.attempts, 2)
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.map(\.id).sorted(), ["e_IPAD", "e_PC"])
        XCTAssertTrue(ipad.journal.isEmpty)
    }

    func testRepeatedRejectionsGiveUpAndKeepTheJournal() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        remote.rejectionsRemaining = 100

        do {
            _ = try await Synchronizer(store: store, remote: remote, backoff: [1, 2], sleep: { _ in }).synchronize()
            XCTFail("Expected to give up")
        } catch {
            XCTAssertEqual(error as? SyncError, .gaveUp(attempts: 3))
        }
        XCTAssertEqual(store.journal.entries.count, 2)
    }

    func testRevokedTokenPausesWithoutLosingTheJournal() async throws {
        let remote = MockRemote()
        remote.isUnauthorized = true
        let store = try makeStore(device: "ipad-01")
        try seed(store)

        do {
            _ = try await Synchronizer(store: store, remote: remote).synchronize()
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? SyncError, .remote(.unauthorized))
        }
        XCTAssertEqual(store.journal.entries.count, 2)
    }

    func testChangesMadeDuringAPushStayInTheJournal() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))
        remote.beforeMove = { [pageId] in
            try? store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_DURING", at: 2, order: 1)))
        }

        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(store.journal.entries.count, 1)
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.map(\.id), ["e_A"])
        XCTAssertEqual(store.pages[pageId]?.liveElements.map(\.id), ["e_A", "e_DURING"])

        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.map(\.id), ["e_A", "e_DURING"])
    }

    func testCorruptRemotePageIsFlaggedAndNeverOverwritten() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        let corrupt = Data("{ \"schema_version\": 1, broken".utf8)
        remote.writeExternally(branch: "main", files: [pagePath: corrupt])
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_B", at: 2, order: 1)))

        let report = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(report.blockedPaths, [pagePath])
        XCTAssertEqual(store.blockedPaths[pagePath], .corruptRemote)
        XCTAssertEqual(remote.file(pagePath), corrupt)
        XCTAssertEqual(store.pages[pageId]?.liveElements.map(\.id), ["e_A", "e_B"])
        XCTAssertEqual(store.journal.entries.count, 1)
        XCTAssertTrue(store.isReadOnly(pageId: pageId))
    }

    func testUnknownSchemaVersionIsReadOnlyAndNeverOverwritten() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        let future = Data(#"{"schema_version": 2, "id": "p_01TEST", "layers": []}"#.utf8)
        remote.writeExternally(branch: "main", files: [pagePath: future])
        try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_A", at: 1)))

        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(store.blockedPaths[pagePath], .unsupportedVersion)
        XCTAssertEqual(remote.file(pagePath), future)
    }

    func testFixedRemoteFileIsUnblocked() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        remote.writeExternally(branch: "main", files: [pagePath: Data("garbage".utf8)])
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        XCTAssertNotNil(store.blockedPaths[pagePath])

        let repaired = try PageCodec.encodePage(Fixtures.page(pageId, notebook: notebookId, elements: [Fixtures.stroke("e_FIXED", at: 9, device: "pc-01")], at: 9, device: "pc-01"))
        remote.writeExternally(branch: "main", files: [pagePath: repaired])
        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertNil(store.blockedPaths[pagePath])
        XCTAssertEqual(store.pages[pageId]?.liveElements.map(\.id), ["e_FIXED"])
    }

    func testOfflineWorkQueuesAndSyncsOnReconnect() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        remote.isUnauthorized = true
        for index in 0..<20 {
            try store.apply(.element(pageId: pageId, element: Fixtures.stroke("e_\(index)", at: Double(index), order: index)))
            _ = try? await Synchronizer(store: store, remote: remote).synchronize()
        }
        XCTAssertEqual(store.journal.entries.count, 20)

        remote.isUnauthorized = false
        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertEqual(try PageCodec.decodePage(try XCTUnwrap(remote.file(pagePath))).liveElements.count, 20)
    }
}
