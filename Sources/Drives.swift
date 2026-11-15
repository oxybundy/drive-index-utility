import AppKit
import DiskArbitration
import IOKit

/// A mounted volume and what kind of hardware it lives on.
struct Drive: Identifiable, Equatable {
    enum Location: String, CaseIterable, Codable {
        case external, `internal`, network, diskImage

        var title: String {
            switch self {
            case .external: return "External"
            case .internal: return "Internal"
            case .network: return "Network"
            case .diskImage: return "Disk images"
            }
        }

        var help: String {
            switch self {
            case .external: return "Drives connected over USB, Thunderbolt and similar."
            case .internal: return "Other drives inside this Mac. The startup disk is never indexed."
            case .network: return "Shared folders on other computers and servers."
            case .diskImage: return "Mounted disk image files, such as .dmg files."
            }
        }
    }

    enum Medium: String, CaseIterable, Codable {
        case ssd, spinning, card, unknown

        var title: String {
            switch self {
            case .ssd: return "SSD"
            case .spinning: return "Spinning"
            case .card: return "Memory cards"
            case .unknown: return "Other"
            }
        }

        var help: String {
            switch self {
            case .ssd: return "Solid-state drives."
            case .spinning: return "Hard drives with spinning disks."
            case .card: return "SD, CFast, CFexpress and other memory cards."
            case .unknown: return "Drives that don't say whether they're an SSD or a spinning disk. Some USB enclosures hide this."
            }
        }
    }

    /// Volume UUID when the file system has one, otherwise a stable stand-in.
    let id: String
    let url: URL
    let name: String
    let capacity: Int64
    let available: Int64
    let location: Location
    let medium: Medium
    /// "SD card", "CFexpress card", … when `medium == .card`.
    let cardType: String?
    /// "USB", "Thunderbolt", "SMB", …
    let connection: String?
    let fileSystem: String
    let device: String?
    let isEjectable: Bool

    var used: Int64 { max(0, capacity - available) }

    /// Short description shown next to the drive, e.g. "External · SSD · USB".
    var kind: String {
        switch location {
        case .network:
            return ["Network", connection].compactMap { $0 }.joined(separator: " · ")
        case .diskImage:
            return "Disk image"
        default:
            if medium == .card {
                let reader = location == .internal ? "Built-in reader" : "\(connection ?? "External") reader"
                return "\(cardType ?? "Memory card") · \(reader)"
            }
            var parts = [location.title]
            if medium != .unknown { parts.append(medium == .ssd ? "SSD" : "Spinning") }
            if let connection { parts.append(connection) }
            return parts.joined(separator: " · ")
        }
    }

    /// Short label for the tag in the drive list.
    var tag: String {
        switch location {
        case .network: return "Network"
        case .diskImage: return "Disk image"
        default:
            if medium == .card { return cardType ?? "Memory card" }
            switch medium {
            case .ssd: return "\(location.title) · SSD"
            case .spinning: return "\(location.title) · Spinning"
            default: return location.title
            }
        }
    }

    var symbol: String {
        switch location {
        case .network: return "server.rack"
        case .diskImage: return "opticaldisc"
        case .internal: return medium == .card ? "sdcard" : "internaldrive"
        case .external: return medium == .card ? "sdcard" : "externaldrive"
        }
    }

    var usesSpinningDisk: Bool { medium == .spinning }
}

enum DriveDetector {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    private static let session = DASessionCreate(kCFAllocatorDefault)

    /// Every user-visible mounted volume except the startup disk.
    static func mountedDrives() -> [Drive] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(drive(at:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func drive(at url: URL) -> Drive? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if v.volumeIsRootFileSystem == true || v.volumeIsBrowsable == false { return nil }
        if url.path == "/" || !url.path.hasPrefix("/Volumes/") { return nil }

        let name = v.volumeName ?? url.lastPathComponent
        let isLocal = v.volumeIsLocal ?? true
        let fsName = fileSystemName(at: url)
        let id = v.volumeUUIDString ?? fallbackID(url: url, name: name, capacity: v.volumeTotalCapacity)

        var location: Drive.Location = (v.volumeIsInternal ?? false) ? .internal : .external
        var medium: Drive.Medium = .unknown
        var cardType: String?
        var connection: String?
        var device: String?

        if !isLocal {
            location = .network
            connection = networkProtocol(fsName)
        } else if let info = hardwareInfo(for: url) {
            device = info.product
            connection = info.interconnect
            if info.isDiskImage {
                location = .diskImage
                connection = nil
            } else if info.interconnect == "Secure Digital" {
                medium = .card
                cardType = "SD card"
                location = .internal
                connection = nil
            } else if info.isRemovableMedia {
                medium = .card
                cardType = cardName(from: [info.product, info.mediaName].compactMap { $0 }.joined(separator: " "))
            } else if let m = info.mediumType {
                medium = m
            }
        }

        return Drive(
            id: id, url: url, name: name,
            capacity: Int64(v.volumeTotalCapacity ?? 0),
            available: Int64(v.volumeAvailableCapacity ?? 0),
            location: location, medium: medium, cardType: cardType, connection: connection,
            fileSystem: v.volumeLocalizedFormatDescription ?? fsName.uppercased(),
            device: device,
            isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !isLocal || location == .diskImage)
    }

    // MARK: Helpers

    private static func fileSystemName(at url: URL) -> String {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return "" }
        return withUnsafeBytes(of: &s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func networkProtocol(_ fs: String) -> String? {
        switch fs {
        case "smbfs": return "SMB"
        case "afpfs": return "AFP"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        default: return nil
        }
    }

    private static func fallbackID(url: URL, name: String, capacity: Int?) -> String {
        // FAT and some network volumes have no UUID; name + size is the best stable key available.
        "\(name)-\(capacity ?? 0)"
    }

    /// Reader and media names usually say which card format it is.
    private static func cardName(from text: String) -> String {
        let t = text.lowercased()
        if t.contains("cfexpress") { return "CFexpress card" }
        if t.contains("cfast") { return "CFast card" }
        if t.contains("compactflash") || t.contains(" cf ") || t.hasSuffix(" cf") { return "CF card" }
        if t.contains("microsd") { return "microSD card" }
        if t.contains("sd") { return "SD card" }
        if t.contains("xqd") { return "XQD card" }
        return "Memory card"
    }

    private struct HardwareInfo {
        var interconnect: String?
        var mediumType: Drive.Medium?
        var isRemovableMedia = false
        var isDiskImage = false
        var product: String?
        var mediaName: String?
    }

    /// Walks up the I/O Registry from the volume to the physical device.
    private static func hardwareInfo(for url: URL) -> HardwareInfo? {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }

        var info = HardwareInfo()
        info.mediaName = desc[kDADiskDescriptionMediaNameKey] as? String
        let model = (desc[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
        let proto = desc[kDADiskDescriptionDeviceProtocolKey] as? String
        if model == "Disk Image" || proto == "Disk Image" { info.isDiskImage = true }

        let service = DADiskCopyIOMedia(disk)
        guard service != 0 else { return info }
        defer { IOObjectRelease(service) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        }

        if let proto = search("Protocol Characteristics") as? [String: Any] {
            let interconnect = proto["Physical Interconnect"] as? String
            if interconnect == "Virtual Interface" { info.isDiskImage = true }
            info.interconnect = interconnect.map(prettyInterconnect)
        }
        if let chars = search("Device Characteristics") as? [String: Any] {
            switch chars["Medium Type"] as? String {
            case "Solid State": info.mediumType = .ssd
            case "Rotational": info.mediumType = .spinning
            default: break
            }
            let vendor = (chars["Vendor Name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let product = (chars["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces)
            info.product = [vendor, product].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            if info.product?.isEmpty == true { info.product = nil }
        }
        if info.product == nil { info.product = model }
        info.isRemovableMedia = physicalMediaIsRemovable(from: service)
        return info
    }

    /// True when the physical media reports itself as removable, as card readers do. APFS volumes sit on
    /// synthesized whole disks, so this keeps walking until it finds media attached to a real storage driver.
    private static func physicalMediaIsRemovable(from start: io_registry_entry_t) -> Bool {
        func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
        }
        var entry = start
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<40 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            let isPhysicalWhole = IOObjectConformsTo(entry, "IOMedia") != 0 && bool(entry, "Whole")
                && IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0
            if isPhysicalWhole {
                IOObjectRelease(parent)
                return bool(entry, "Removable")
            }
            IOObjectRelease(entry)
            entry = parent
        }
        return false
    }

    private static func prettyInterconnect(_ s: String) -> String {
        switch s {
        case "USB": return "USB"
        case "Thunderbolt": return "Thunderbolt"
        case "PCI-Express", "PCI": return "PCIe"
        case "SATA": return "SATA"
        case "FireWire": return "FireWire"
        case "Secure Digital": return "Secure Digital"
        default: return s
        }
    }
}
