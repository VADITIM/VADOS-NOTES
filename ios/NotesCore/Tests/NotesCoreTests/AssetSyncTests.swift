import XCTest
@testable import NotesCore

final class AssetSyncTests: XCTestCase {
    let notebookId = "nb_01TEST"
    let pageId = "p_01TEST"
    let document = Data("%PDF-1.7 worksheet".utf8)
    var pagePath: String { RepositoryPath.page(notebook: notebookId, page: pageId) }

    func makeStore(device: String, assetByteLimit: Int = .max) throws -> NotesStore {
        try NotesStore(directory: Fixtures.temporaryDirectory(), device: device, assetByteLimit: assetByteLimit)
    }

    func seed(_ store: NotesStore) throws {
        try store.apply(.notebook(Notebook(id: notebookId, title: "Notes", updated: Fixtures.time(0), device: store.device)))
        try store.apply(.page(PageHeader(id: pageId, notebook: notebookId, updated: Fixtures.time(0), device: store.device)))
    }

    func importElement(_ id: String, asset: String, at seconds: Double = 1, device: String = "ipad-01") -> Element {
        Element(
            id: id,
            type: .importPage,
            layer: .importLayer,
            order: 0,
            asset: asset,
            sourcePage: 0,
            sourceSizeMillimetres: [210, 297],
            placement: Placement(x: 0, y: 0, scale: 1),
            fit: .original,
            updated: Fixtures.time(seconds),
            device: device
        )
    }

    func testHashMatchesKnownVectors() {
        XCTAssertEqual(ContentHash.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ContentHash.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ContentHash.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(ContentHash.sha256(Data(repeating: UInt8(ascii: "a"), count: 1_000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testAssetPathsAcceptOnlyContentHashes() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertEqual(RepositoryPath.asset("sha256:\(hash)"), "assets/\(hash)")
        XCTAssertEqual(RepositoryPath.assetIdentifier(at: "assets/\(hash)"), "sha256:\(hash)")
        XCTAssertNil(RepositoryPath.asset("sha256:../../notebooks"))
        XCTAssertNil(RepositoryPath.asset("sha256:\(hash.uppercased())"))
        XCTAssertNil(RepositoryPath.assetIdentifier(at: "assets/\(hash)/extra"))
        XCTAssertNil(RepositoryPath.assetIdentifier(at: "notebooks/\(hash)"))
    }

    func testAssetIsUploadedInTheCommitThatFirstCarriesItsPage() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        let asset = try store.assets.add(document)
        try store.apply(.element(pageId: pageId, element: importElement("e_IMPORT", asset: asset)))
        let assetPath = try XCTUnwrap(RepositoryPath.asset(asset))

        let report = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(report.pushedPaths, [assetPath, pagePath])
        XCTAssertEqual(remote.file(assetPath), document)
        for commit in remote.commits.values {
            guard let pageSha = commit.files[pagePath], let page = try? PageCodec.decodePage(try XCTUnwrap(remote.blobs[pageSha])) else { continue }
            for element in page.liveElements {
                guard let referenced = element.asset else { continue }
                XCTAssertNotNil(commit.files[try XCTUnwrap(RepositoryPath.asset(referenced))], "a commit carries a page whose asset it lacks")
            }
        }
        XCTAssertEqual(store.syncState.blobs[assetPath], remote.commits[try XCTUnwrap(remote.branches["main"])]?.files[assetPath])
        XCTAssertNil(store.snapshot.data(at: assetPath))
    }

    func testMissingRemoteAssetIsFetched() async throws {
        let remote = MockRemote()
        let ipad = try makeStore(device: "ipad-01")
        try seed(ipad)
        let asset = try ipad.assets.add(document)
        try ipad.apply(.element(pageId: pageId, element: importElement("e_IMPORT", asset: asset)))
        _ = try await Synchronizer(store: ipad, remote: remote).synchronize()

        let computer = try makeStore(device: "pc-01")
        XCTAssertFalse(computer.assets.contains(asset))
        let report = try await Synchronizer(store: computer, remote: remote).synchronize()

        XCTAssertEqual(report.fetchedAssets, [asset])
        XCTAssertEqual(computer.assets.data(for: asset), document)

        let again = try await Synchronizer(store: computer, remote: remote).synchronize()
        XCTAssertEqual(again.fetchedAssets, [])
    }

    func testAssetsAreListedOnceForAStoreThatSyncedBeforeAssetsDid() async throws {
        let remote = MockRemote()
        let ipad = try makeStore(device: "ipad-01")
        try seed(ipad)
        let asset = try ipad.assets.add(document)
        try ipad.apply(.element(pageId: pageId, element: importElement("e_IMPORT", asset: asset)))
        _ = try await Synchronizer(store: ipad, remote: remote).synchronize()
        let computer = try makeStore(device: "pc-01")
        _ = try await Synchronizer(store: computer, remote: remote).synchronize()
        try FileManager.default.removeItem(at: try XCTUnwrap(computer.assets.fileURL(for: asset)))
        try computer.snapshot.update { state in
            state.blobs = state.blobs.filter { RepositoryPath.assetIdentifier(at: $0.key) == nil }
            state.assetsListed = nil
        }

        let report = try await Synchronizer(store: computer, remote: remote).synchronize()

        XCTAssertEqual(report.fetchedAssets, [asset])
        XCTAssertEqual(computer.syncState.assetsListed, true)
    }

    func testRemoteAssetWhoseBytesDoNotMatchItsNameIsNotStored() async throws {
        let remote = MockRemote()
        let ipad = try makeStore(device: "ipad-01")
        try seed(ipad)
        let asset = try ipad.assets.add(document)
        try ipad.apply(.element(pageId: pageId, element: importElement("e_IMPORT", asset: asset)))
        _ = try await Synchronizer(store: ipad, remote: remote).synchronize()
        remote.writeExternally(branch: "main", files: [try XCTUnwrap(RepositoryPath.asset(asset)): Data("tampered".utf8)])

        let computer = try makeStore(device: "pc-01")
        let report = try await Synchronizer(store: computer, remote: remote).synchronize()

        XCTAssertEqual(report.fetchedAssets, [])
        XCTAssertFalse(computer.assets.contains(asset))
    }

    func testReimportingTheSameFileIsDeduplicated() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        let first = try store.assets.add(document)
        try store.apply(.element(pageId: pageId, element: importElement("e_FIRST", asset: first)))
        _ = try await Synchronizer(store: store, remote: remote).synchronize()

        let second = try store.assets.add(document)
        try store.apply(.page(PageHeader(id: "p_01SECOND", notebook: notebookId, updated: Fixtures.time(2), device: "ipad-01")))
        try store.apply(.element(pageId: "p_01SECOND", element: importElement("e_SECOND", asset: second, at: 3)))
        let report = try await Synchronizer(store: store, remote: remote).synchronize()

        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.assets.directory.path).count, 1)
        XCTAssertEqual(report.pushedPaths, [RepositoryPath.page(notebook: notebookId, page: "p_01SECOND")])
        let assetPaths = remote.commits[try XCTUnwrap(remote.branches["main"])]?.files.keys.filter { RepositoryPath.assetIdentifier(at: $0) != nil }
        XCTAssertEqual(assetPaths, [try XCTUnwrap(RepositoryPath.asset(first))])
    }

    func testAssetOverTheLimitIsRefused() throws {
        let store = try makeStore(device: "ipad-01", assetByteLimit: 8)

        XCTAssertThrowsError(try store.assets.add(document)) { error in
            XCTAssertEqual(error as? AssetError, .tooLarge(bytes: document.count, limit: 8))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.assets.directory.path), [])
    }

    func testAssetOfAPageAlreadyOnTheRemoteIsUploadedOnItsOwn() async throws {
        let remote = MockRemote()
        let store = try makeStore(device: "ipad-01")
        try seed(store)
        let asset = AssetStore.identifier(for: document)
        try store.apply(.element(pageId: pageId, element: importElement("e_IMPORT", asset: asset)))
        _ = try await Synchronizer(store: store, remote: remote).synchronize()
        XCTAssertTrue(store.journal.isEmpty)

        try store.assets.add(document)
        let report = try await Synchronizer(store: store, remote: remote).synchronize()

        let assetPath = try XCTUnwrap(RepositoryPath.asset(asset))
        XCTAssertEqual(report.pushedPaths, [assetPath])
        XCTAssertEqual(remote.file(assetPath), document)
    }
}
