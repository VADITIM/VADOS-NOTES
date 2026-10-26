import Foundation
import NotesCore
import UIKit

enum SyncStatus: Equatable {
    case notConnected
    case syncing
    case synced(Date)
    case paused
    case offline(queued: Int)
    case retrying(queued: Int)
    case failed(String)

    var label: String {
        switch self {
        case .notConnected: return "Not connected"
        case .syncing: return "Syncing"
        case .synced(let date): return "Synced \(Self.timeFormatter.string(from: date))"
        case .paused: return "Sync paused"
        case .offline(let queued): return "Offline · \(queued) queued"
        case .retrying(let queued): return "Retrying · \(queued) queued"
        case .failed: return "Sync failed"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .notConnected
    @Published private(set) var blockedCount = 0
    @Published var settings: SyncSettings

    var onStoreChanged: (() -> Void)?

    private let store: NotesStore
    private var policy: FlushPolicy
    private var flushTimer: Timer?
    private var pullTimer: Timer?
    private var isRunning = false
    private var isRunRequested = false
    private let pullIntervalSeconds: TimeInterval = 60
    private let retryIntervalSeconds: TimeInterval = 30
    private static let journalKey = "journal"

    init(store: NotesStore) {
        self.store = store
        settings = SyncSettings.load()
        let tokens = Tokens.shared.sync
        policy = FlushPolicy(idleInterval: tokens.idleSeconds, maximumAge: tokens.maxAgeSeconds)
        blockedCount = store.blockedPaths.count
        if !store.journal.isEmpty {
            policy.recordChange(page: Self.journalKey, at: Date())
        }
        refreshIdleStatus()
    }

    var isConfigured: Bool {
        settings.isComplete && Keychain.readToken() != nil
    }

    func configure(_ newSettings: SyncSettings, token: String?) {
        settings = newSettings
        newSettings.save()
        if let token {
            Keychain.saveToken(token)
        }
        refreshIdleStatus()
        flush()
    }

    func recordInput(page: String) {
        guard policy.isDirty else { return }
        policy.recordInput(page: page, at: Date())
        scheduleFlush()
    }

    func recordChange(page: String) {
        policy.recordChange(page: page, at: Date())
        scheduleFlush()
    }

    func appBecameActive() {
        startPulling()
        flush()
    }

    func appEnteredBackground() {
        pullTimer?.invalidate()
        pullTimer = nil
        guard isConfigured, !store.journal.isEmpty else { return }
        let backgroundTask = BackgroundTask()
        backgroundTask.identifier = UIApplication.shared.beginBackgroundTask(withName: "flush") {
            backgroundTask.end()
        }
        Task {
            await run()
            backgroundTask.end()
        }
    }

    func flush() {
        Task { await run() }
    }

    private func scheduleFlush() {
        flushTimer?.invalidate()
        guard let deadline = policy.nextDeadline() else { return }
        let interval = max(0.05, deadline.timeIntervalSinceNow)
        flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func startPulling() {
        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: pullIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func run() async {
        guard settings.isComplete, let token = Keychain.readToken() else {
            status = .notConnected
            return
        }
        if isRunning {
            isRunRequested = true
            return
        }
        isRunning = true
        status = .syncing
        let remote = GitHubRemote(address: RepositoryAddress(owner: settings.owner, name: settings.repository), token: token)
        let synchronizer = Synchronizer(store: store, remote: remote, branch: settings.branch, backoff: Tokens.shared.sync.backoffSeconds)
        policy.markFlushed()
        var didSucceed = false
        do {
            _ = try await synchronizer.synchronize()
            status = .synced(store.syncState.lastSynced ?? Date())
            didSucceed = true
        } catch SyncError.remote(.unauthorized) {
            status = .paused
        } catch SyncError.remote(.transport) {
            status = .offline(queued: store.journal.entries.count)
            scheduleRetry()
        } catch SyncError.gaveUp {
            status = .retrying(queued: store.journal.entries.count)
            scheduleRetry()
        } catch {
            status = .failed(String(describing: error))
            scheduleRetry()
        }
        blockedCount = store.blockedPaths.count
        let hasPushableEntries = store.journal.entries.contains { entry in
            store.path(for: entry.change).map { store.blockedPaths[$0] == nil } ?? false
        }
        if hasPushableEntries {
            policy.recordChange(page: Self.journalKey, at: Date())
            if didSucceed {
                scheduleFlush()
            }
        }
        isRunning = false
        onStoreChanged?()
        if isRunRequested {
            isRunRequested = false
            await run()
        }
    }

    private func scheduleRetry() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: retryIntervalSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func refreshIdleStatus() {
        if !isConfigured {
            status = .notConnected
        } else if let last = store.syncState.lastSynced {
            status = .synced(last)
        }
    }
}

final class BackgroundTask {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
