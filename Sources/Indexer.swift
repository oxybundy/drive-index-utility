import AppKit
import CoreServices

/// What's saved between runs for each drive, so later indexes only rescan folders that changed.
struct DriveCache: Codable {
    var id: String
    var name: String
    var indexed: Date
    var sizes: Bool
    /// The drive's change-log ID and the last event already reflected in `tree`.
    var store: String?
    var eventID: UInt64?
    var reportFolder: String?
    var reportBase: String?
    var tree: Folder
}

/// Watches one drive's change log. Events are delivered on the main queue.
final class ChangeWatcher {
    struct Change { var path: String; var deep: Bool }

    private var stream: FSEventStreamRef?
    private let onChanges: ([Change], UInt64) -> Void
    private let onHistoryDone: () -> Void

    init?(drive: Drive, since: UInt64?, onChanges: @escaping ([Change], UInt64) -> Void, onHistoryDone: @escaping () -> Void) {
        self.onChanges = onChanges
        self.onHistoryDone = onHistoryDone
        var st = stat()
        guard stat(drive.url.path, &st) == 0 else { return nil }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let me = Unmanaged<ChangeWatcher>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes: [Change] = []
            var historyDone = false
            var last: UInt64 = 0
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                last = max(last, ids[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; continue }
                if f & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { continue }
                let deep = f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagEventIdsWrapped) != 0
                changes.append(Change(path: list[i], deep: deep))
            }
            if !changes.isEmpty { me.onChanges(changes, last) }
            if historyDone { me.onHistoryDone() }
        }
        let start = since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let s = FSEventStreamCreateRelativeToDevice(
            nil, callback, &context, st.st_dev, [""] as CFArray, start, 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return nil
        }
        stream = s
        if since == nil { DispatchQueue.main.async { onHistoryDone() } }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    static func storeID(for drive: Drive) -> String? {
        var st = stat()
        guard stat(drive.url.path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

final class Indexer: ObservableObject {
    enum Activity: Equatable {
        case idle
        case scanning(String, Double?)
        case failed(String)
    }

    static let shared = Indexer()
    private let settings = Settings.shared

    @Published private(set) var drives: [Drive] = []
    @Published private(set) var activity: [String: Activity] = [:]
    @Published private(set) var lastIndexed: [String: Date] = [:]

    private var caches: [String: DriveCache] = [:]
    private var watchers: [String: ChangeWatcher] = [:]
    private var pending: [String: [ChangeWatcher.Change]] = [:]
    private var pendingEventID: [String: UInt64] = [:]
    private var catchingUp: Set<String> = []
    private var debounce: [String: DispatchWorkItem] = [:]
    private var queues: [String: DispatchQueue] = [:]
    private var cancelFlags: [String: Bool] = [:]
    private let cancelLock = NSLock()
    private var afterIndex: [String: [() -> Void]] = [:]

    /// How long a drive has to be quiet before its changes are written to the reports.
    private let quietPeriod: TimeInterval = 30

    private let cacheFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Drive Index Utility/Drives", isDirectory: true)
    }()

    var onChange: (() -> Void)?

    private init() {}

    func start() {
        loadCacheSummaries()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        center.addObserver(self, selector: #selector(willUnmount(_:)), name: NSWorkspace.willUnmountNotification, object: nil)
        reloadDrives(indexNew: true)
    }

    // MARK: Drives

    @objc private func volumesChanged(_ note: Notification) {
        reloadDrives(indexNew: note.name == NSWorkspace.didMountNotification)
    }

    @objc private func willUnmount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let drive = drives.first(where: { $0.url == url }) else { return }
        // Anything not yet applied stays in the drive's change log and is replayed next time it's connected.
        stopWatching(drive.id)
        pending[drive.id] = nil
        pendingEventID[drive.id] = nil
        cancel(drive.id)
    }

    private func reloadDrives(indexNew: Bool) {
        let old = Set(drives.map(\.id))
        drives = DriveDetector.mountedDrives()
        let current = Set(drives.map(\.id))

        for id in old.subtracting(current) {
            stopWatching(id)
            cancel(id)
        }
        if old != current { writeCatalog() }

        guard indexNew else { onChange?(); return }
        for drive in drives where !old.contains(drive.id) {
            if settings.indexOnConnect && settings.indexesAutomatically(drive) {
                index(drive)
            }
        }
        onChange?()
    }

    func drive(_ id: String) -> Drive? { drives.first { $0.id == id } }

    func isBusy(_ id: String) -> Bool {
        if case .scanning = activity[id] ?? .idle { return true }
        return false
    }

    // MARK: Indexing

    /// Brings a drive's index up to date: replays its change log when possible, otherwise scans it in full.
    func index(_ drive: Drive, full: Bool = false, then completion: (() -> Void)? = nil) {
        if let completion { afterIndex[drive.id, default: []].append(completion) }
        guard !isBusy(drive.id) else { return }

        let sizes = settings.includesSizes(drive)
        let cache = cachedTree(drive.id)
        let store = ChangeWatcher.storeID(for: drive)
        let canCatchUp = !full && drive.location != .network && cache != nil && cache?.sizes == sizes
            && store != nil && cache?.store == store && cache?.eventID != nil

        if canCatchUp, let cache {
            if watchers[drive.id] != nil {
                flushPending(drive.id)
            } else {
                catchUp(drive, cache: cache)
            }
        } else {
            fullScan(drive, sizes: sizes, store: store)
        }
    }

    func indexAndEject(_ drive: Drive) {
        index(drive) { [weak self] in
            guard let self, let current = self.drive(drive.id) else { return }
            self.stopWatching(drive.id)
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: current.url)
            } catch {
                self.activity[drive.id] = .failed("Couldn't eject: \(error.localizedDescription)")
            }
        }
    }

    func cancel(_ id: String) {
        cancelLock.lock(); cancelFlags[id] = true; cancelLock.unlock()
    }

    private func isCancelled(_ id: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelFlags[id] ?? false
    }

    private func queue(for id: String) -> DispatchQueue {
        if let q = queues[id] { return q }
        let q = DispatchQueue(label: "drive.\(id)", qos: .utility)
        queues[id] = q
        return q
    }

    private func fullScan(_ drive: Drive, sizes: Bool, store: String?) {
        cancelLock.lock(); cancelFlags[drive.id] = false; cancelLock.unlock()
        activity[drive.id] = .scanning(sizes ? "Starting…" : "Listing folders…", nil)
        stopWatching(drive.id)

        // Note the change-log position before scanning, then replay anything that happens during the scan.
        let startEvent = FSEventsGetCurrentEventId()
        if shouldWatch(drive) { watch(drive, since: nil) }

        let parallel = drive.medium == .ssd ? 4 : 1
        queue(for: drive.id).async { [weak self] in
            guard let self else { return }
            let scanner = Scanner(root: drive.url, withSizes: sizes, parallel: parallel) { [weak self] in
                self?.isCancelled(drive.id) ?? true
            }
            scanner.onProgress = { [weak self] p in
                DispatchQueue.main.async {
                    guard let self, self.isBusy(drive.id) else { return }
                    let text = p.current.isEmpty ? "Writing reports…"
                        : sizes ? "Measuring \(p.current) · \(p.done + 1) of \(p.total) folders" : "Listing \(p.current)"
                    self.activity[drive.id] = .scanning(text, p.total > 0 ? Double(p.done) / Double(p.total) : nil)
                }
            }
            do {
                let tree = try scanner.scanAll()
                let cache = DriveCache(id: drive.id, name: drive.name, indexed: Date(), sizes: sizes,
                                       store: store, eventID: store == nil ? nil : startEvent, tree: tree)
                DispatchQueue.main.async { self.finish(drive, cache: cache) }
            } catch is ScanCancelled {
                DispatchQueue.main.async {
                    self.activity[drive.id] = .idle
                    self.afterIndex[drive.id] = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.activity[drive.id] = .failed("Couldn't read the drive: \(error.localizedDescription)")
                    self.afterIndex[drive.id] = nil
                }
            }
        }
    }

    /// Replays the drive's change log since the last index, then rescans only the folders it names.
    private func catchUp(_ drive: Drive, cache: DriveCache) {
        activity[drive.id] = .scanning("Checking for changes…", nil)
        catchingUp.insert(drive.id)
        let keep = shouldWatch(drive)
        var temporary: ChangeWatcher?
        let watcher = ChangeWatcher(drive: drive, since: cache.eventID, onChanges: { [weak self] changes, last in
            self?.collect(drive.id, changes, last)
        }, onHistoryDone: { [weak self] in
            guard let self else { return }
            self.catchingUp.remove(drive.id)
            if !keep { temporary?.stop(); temporary = nil }
            self.flushPending(drive.id, force: true)
        })
        if keep { watchers[drive.id] = watcher } else { temporary = watcher }
        if watcher == nil {
            catchingUp.remove(drive.id)
            fullScan(drive, sizes: cache.sizes, store: nil)
        }
    }

    private func collect(_ id: String, _ changes: [ChangeWatcher.Change], _ last: UInt64) {
        pending[id, default: []].append(contentsOf: changes)
        pendingEventID[id] = max(pendingEventID[id] ?? 0, last)
        guard !catchingUp.contains(id), !isBusy(id) else { return }
        debounce[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPending(id) }
        debounce[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    /// Applies collected changes to the saved tree and rewrites the reports.
    private func flushPending(_ id: String, force: Bool = false) {
        debounce[id]?.cancel()
        debounce[id] = nil
        guard let drive = drive(id) else { return }
        if isBusy(id) && !force {
            // A full scan is running; it will pick these up when it finishes.
            return
        }
        let changes = pending[id] ?? []
        let lastEvent = pendingEventID[id]
        pending[id] = nil
        pendingEventID[id] = nil

        guard var cache = cachedTree(id) else { return }
        cache.tree = cache.tree.copy()
        if changes.isEmpty {
            if force { finish(drive, cache: cache, touched: false) } else { runAfterIndex(id) }
            return
        }
        if changes.contains(where: { $0.deep && $0.path.isEmpty }) {
            fullScan(drive, sizes: cache.sizes, store: ChangeWatcher.storeID(for: drive))
            return
        }

        activity[id] = .scanning("Updating changed folders…", nil)
        queue(for: id).async { [weak self] in
            guard let self else { return }
            let scanner = Scanner(root: drive.url, withSizes: cache.sizes, parallel: 1) { [weak self] in
                self?.isCancelled(id) ?? true
            }
            // Each changed folder is listed again, along with its parent (which notices added or removed folders).
            var targets: [String: Bool] = [:]
            for c in changes {
                let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
                targets[path] = (targets[path] ?? false) || c.deep
                let parent = (path as NSString).deletingLastPathComponent
                if targets[parent] == nil { targets[parent] = false }
            }
            do {
                for path in targets.keys.sorted(by: { $0.count < $1.count }) {
                    try scanner.refresh(path, in: cache.tree, deep: targets[path] ?? false)
                }
                cache.tree.total()
                cache.indexed = Date()
                if let lastEvent { cache.eventID = max(cache.eventID ?? 0, lastEvent) }
                DispatchQueue.main.async { self.finish(drive, cache: cache) }
            } catch {
                DispatchQueue.main.async { self.fullScan(drive, sizes: cache.sizes, store: ChangeWatcher.storeID(for: drive)) }
            }
        }
    }

    private func finish(_ drive: Drive, cache: DriveCache, touched: Bool = true) {
        var cache = cache
        let current = self.drive(drive.id) ?? drive
        cache.name = current.name
        do {
            try writeReports(current, cache: &cache)
            try saveCache(cache)
            lastIndexed[drive.id] = cache.indexed
            activity[drive.id] = .idle
        } catch {
            activity[drive.id] = .failed("Couldn't save the report: \(error.localizedDescription)")
        }
        writeCatalog()
        // Changes that arrived while scanning.
        if !(pending[drive.id] ?? []).isEmpty {
            collect(drive.id, [], pendingEventID[drive.id] ?? 0)
        }
        runAfterIndex(drive.id)
    }

    private func runAfterIndex(_ id: String) {
        let callbacks = afterIndex[id] ?? []
        afterIndex[id] = nil
        callbacks.forEach { $0() }
    }

    // MARK: Watching

    private func shouldWatch(_ drive: Drive) -> Bool {
        settings.keepUpdated && settings.indexesAutomatically(drive) && drive.location != .network
    }

    private func watch(_ drive: Drive, since: UInt64?) {
        stopWatching(drive.id)
        watchers[drive.id] = ChangeWatcher(drive: drive, since: since, onChanges: { [weak self] changes, last in
            self?.collect(drive.id, changes, last)
        }, onHistoryDone: {})
    }

    private func stopWatching(_ id: String) {
        watchers[id]?.stop()
        watchers[id] = nil
        debounce[id]?.cancel()
        debounce[id] = nil
    }

    /// Starts or stops watchers after a settings change.
    func settingsChanged() {
        for drive in drives {
            let watching = watchers[drive.id] != nil
            if shouldWatch(drive) && !watching, let cache = cachedTree(drive.id), cache.eventID != nil,
               cache.store == ChangeWatcher.storeID(for: drive) {
                catchUp(drive, cache: cache)
            } else if !shouldWatch(drive) && watching {
                stopWatching(drive.id)
            }
        }
        rewriteAllReports()
    }

    // MARK: Reports

    func reportURL(for id: String) -> URL? {
        guard let cache = caches[id], let base = cache.reportBase else { return nil }
        let url = settings.outputFolder.appendingPathComponent(base + ".txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var catalogURL: URL { settings.outputFolder.appendingPathComponent("Drive Catalog.html") }

    private func writeReports(_ drive: Drive, cache: inout DriveCache) throws {
        let folder = settings.outputFolder
        let report = DriveReport(drive: drive, tree: cache.tree, indexed: cache.indexed)
        let base = ReportWriter.chooseFileBase(for: report, in: folder)
        if cache.reportFolder == folder.path, let old = cache.reportBase, old != base {
            // The drive was renamed; its old report files would otherwise linger.
            ReportWriter.removeReports(base: old, in: folder)
        }
        try ReportWriter.write(report, base: base, to: folder, levels: settings.textLevels)
        cache.reportFolder = folder.path
        cache.reportBase = base
    }

    func writeCatalog() {
        guard settings.catalog else { return }
        let folder = settings.outputFolder
        let connected = Set(drives.map(\.id))
        DispatchQueue.global(qos: .utility).async {
            try? ReportWriter.writeCatalog(in: folder, connected: connected)
        }
    }

    /// Rewrites every report from saved trees, e.g. after the output folder or text depth changes.
    func rewriteAllReports() {
        for id in caches.keys {
            guard var cache = cachedTree(id), let drive = drive(id) else { continue }
            if (try? writeReports(drive, cache: &cache)) != nil { try? saveCache(cache) }
        }
        writeCatalog()
    }

    // MARK: Cache

    private func cacheURL(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return cacheFolder.appendingPathComponent(safe + ".json")
    }

    private func loadCacheSummaries() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let cache = try? DriveReport.decoder.decode(DriveCache.self, from: data) else { continue }
            caches[cache.id] = cache
            lastIndexed[cache.id] = cache.indexed
        }
    }

    private func cachedTree(_ id: String) -> DriveCache? { caches[id] }

    private func saveCache(_ cache: DriveCache) throws {
        caches[cache.id] = cache
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)
        try data.write(to: cacheURL(cache.id), options: .atomic)
    }
}
