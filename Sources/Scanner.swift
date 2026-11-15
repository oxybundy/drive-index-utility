import Foundation

/// One folder in a drive's tree. `files` is the size of the files directly inside it;
/// `size` also includes everything below. Sizes are nil when sizes are turned off.
final class Folder: Codable {
    var name: String
    var files: Int64?
    var size: Int64?
    var package: Bool?
    var children: [Folder]

    init(name: String, files: Int64? = nil, package: Bool = false, children: [Folder] = []) {
        self.name = name
        self.files = files
        self.package = package ? true : nil
        self.children = children
    }

    /// Recomputes `size` for this folder and everything below it.
    @discardableResult
    func total() -> Int64? {
        guard let files else {
            children.forEach { $0.total() }
            size = nil
            return nil
        }
        size = children.reduce(files) { $0 + ($1.total() ?? 0) }
        return size
    }

    func child(named name: String) -> Folder? { children.first { $0.name == name } }

    func copy() -> Folder {
        let f = Folder(name: name, files: files, package: package == true, children: children.map { $0.copy() })
        f.size = size
        return f
    }

    func sortChildren() {
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class ScanCancelled: Error {}

/// Reads folder trees with getattrlistbulk(2), which returns names, types and sizes for a whole
/// directory in a few system calls instead of one stat() per file.
final class Scanner {
    struct Progress {
        var current: String
        var done: Int
        var total: Int
    }

    let root: URL
    let withSizes: Bool
    let parallel: Int
    var onProgress: ((Progress) -> Void)?
    private let cancelled: () -> Bool
    private var rootDevice: Int32 = 0

    /// Top-level names macOS and Windows keep for themselves.
    static let ignoredAtRoot: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ".MobileBackups", ".PKInstallSandboxManager", ".HFS+ Private Directory Data\r", ".vol",
        "System Volume Information", "$RECYCLE.BIN", "RECYCLER",
    ]

    /// Folders that Finder shows as a single file. They're sized, but their insides aren't listed.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "photolibrary", "aplibrary",
        "migratedphotolibrary", "imovielibrary", "theater", "tvlibrary", "fcpbundle", "fcpxml", "logicx",
        "band", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace", "playground", "sparsebundle",
        "backupbundle", "pkg", "mpkg", "lrdata", "lrlibrary", "dvdmedia", "aep", "prproj-backup", "cosessiondb",
    ]

    init(root: URL, withSizes: Bool, parallel: Int, cancelled: @escaping () -> Bool) {
        self.root = root
        self.withSizes = withSizes
        self.parallel = max(1, parallel)
        self.cancelled = cancelled
    }

    // MARK: Full scan

    func scanAll() throws -> Folder {
        var st = stat()
        guard stat(root.path, &st) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        rootDevice = st.st_dev

        let rootFolder = Folder(name: "")
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        guard let entries = list(fd) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let dirs = entries.filter { $0.isDirectory && !Self.ignoredAtRoot.contains($0.name) }
        rootFolder.files = withSizes ? entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } : nil

        var results = [Folder?](repeating: nil, count: dirs.count)
        var done = 0
        let lock = NSLock()
        var failure: Error?

        let work = { (i: Int) in
            if self.cancelled() { return }
            let name = dirs[i].name
            lock.lock(); self.onProgress?(Progress(current: name, done: done, total: dirs.count)); lock.unlock()
            do {
                let folder = try self.scan(at: fd, name: name)
                lock.lock(); results[i] = folder; done += 1; lock.unlock()
            } catch {
                lock.lock(); failure = failure ?? error; lock.unlock()
            }
        }
        if parallel > 1 && dirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: dirs.count, execute: work)
        } else {
            for i in dirs.indices { work(i) }
        }
        if cancelled() { throw ScanCancelled() }
        if let failure { throw failure }

        rootFolder.children = results.compactMap { $0 }
        rootFolder.sortChildren()
        rootFolder.total()
        onProgress?(Progress(current: "", done: dirs.count, total: dirs.count))
        return rootFolder
    }

    /// Scans `name` inside the directory open at `parentFD`. Unreadable folders come back empty
    /// rather than failing the whole scan.
    private func scan(at parentFD: Int32, name: String) throws -> Folder {
        if cancelled() { throw ScanCancelled() }
        let isPackage = Self.packageExtensions.contains((name as NSString).pathExtension.lowercased())
        let folder = Folder(name: name, files: withSizes ? 0 : nil, package: isPackage)

        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return folder }
        defer { close(fd) }
        guard let entries = list(fd) else { return folder }

        var files: Int64 = 0
        for e in entries {
            if e.isDirectory {
                if e.device != rootDevice { continue } // another volume mounted inside this one
                folder.children.append(try scan(at: fd, name: e.name))
            } else {
                files += e.size
            }
        }
        if withSizes { folder.files = files }
        folder.sortChildren()
        return folder
    }

    // MARK: Incremental update

    /// Rescans one folder (path relative to the drive root). Subfolders that already exist in the
    /// tree are kept as they are unless `deep` is set; new ones are scanned in full.
    func refresh(_ relativePath: String, in tree: Folder, deep: Bool) throws {
        var st = stat()
        guard stat(root.path, &st) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        rootDevice = st.st_dev

        let parts = relativePath.split(separator: "/").map(String.init)
        if let first = parts.first, Self.ignoredAtRoot.contains(first) { return }

        // Walk down to the deepest folder that's already in the tree.
        var node = tree
        var depth = 0
        for part in parts {
            guard let next = node.child(named: part) else { break }
            node = next
            depth += 1
        }
        let path = ([root.path] + parts.prefix(depth)).joined(separator: "/")
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // The folder is gone; its parent's own event removes it from the tree.
            return
        }
        defer { close(fd) }
        guard let entries = list(fd) else { return }
        let isRoot = depth == 0

        var files: Int64 = 0
        var kept: [Folder] = []
        for e in entries {
            if e.isDirectory {
                if e.device != rootDevice { continue }
                if isRoot && Self.ignoredAtRoot.contains(e.name) { continue }
                if !deep, let existing = node.child(named: e.name) {
                    kept.append(existing)
                } else {
                    kept.append(try scan(at: fd, name: e.name))
                }
            } else {
                files += e.size
            }
        }
        if withSizes { node.files = files }
        node.children = kept
        node.sortChildren()
    }

    // MARK: getattrlistbulk

    struct Entry {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var device: Int32
    }

    private func list(_ fd: Int32) -> [Entry]? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
        attrs.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 { return entries.isEmpty ? nil : entries }
            if count == 0 { break }
            var p = buffer
            for _ in 0..<count {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                var field = p + 4 + MemoryLayout<attribute_set_t>.size

                let nameRef = field
                let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
                let name = String(cString: (nameRef + nameOffset).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                let device = field.loadUnaligned(as: Int32.self)
                field += MemoryLayout<dev_t>.size

                let type = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<fsobj_type_t>.size

                let size = field.loadUnaligned(as: Int64.self)

                switch type {
                case UInt32(VDIR.rawValue):
                    entries.append(Entry(name: name, isDirectory: true, size: 0, device: device))
                case UInt32(VREG.rawValue):
                    entries.append(Entry(name: name, isDirectory: false, size: withSizes ? size : 0, device: device))
                default:
                    break // symlinks, sockets, devices
                }
                p += length
            }
        }
        return entries
    }
}
