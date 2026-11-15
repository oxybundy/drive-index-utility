import AppKit
import ServiceManagement

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private var syncingLogin = false

    enum SizeMode: String, CaseIterable, Identifiable {
        case exceptNetwork, all, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exceptNetwork: return "All except network"
            case .all: return "All drives"
            case .never: return "Never"
            }
        }
    }

    enum Rule: String, CaseIterable, Identifiable {
        case auto, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Use settings"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    var onMenuBarChange: (() -> Void)?
    var onChange: (() -> Void)?

    @Published var outputFolder: URL { didSet { defaults.set(outputFolder.path, forKey: "outputFolder"); onChange?() } }
    @Published var locations: Set<Drive.Location> { didSet { save(locations.map(\.rawValue), "autoLocations") } }
    @Published var media: Set<Drive.Medium> { didSet { save(media.map(\.rawValue), "autoMedia") } }
    @Published var indexOnConnect: Bool { didSet { defaults.set(indexOnConnect, forKey: "indexOnConnect") } }
    @Published var keepUpdated: Bool { didSet { defaults.set(keepUpdated, forKey: "keepUpdated"); onChange?() } }
    @Published var indexOnEject: Bool { didSet { defaults.set(indexOnEject, forKey: "indexOnEject") } }
    @Published var sizeMode: SizeMode { didSet { defaults.set(sizeMode.rawValue, forKey: "sizeMode") } }
    /// Folder levels in the text report; 0 means all.
    @Published var textLevels: Int { didSet { defaults.set(textLevels, forKey: "textLevels"); onChange?() } }
    @Published var catalog: Bool { didSet { defaults.set(catalog, forKey: "catalog"); onChange?() } }
    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar"); onMenuBarChange?() } }
    @Published var openAtLogin: Bool { didSet { if !syncingLogin && openAtLogin != oldValue { applyLoginItem() } } }
    @Published var rules: [String: Rule] { didSet { defaults.set(rules.mapValues(\.rawValue), forKey: "driveRules") } }
    @Published var status = ""

    static var defaultOutputFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { return iCloud.appendingPathComponent("Drive Index") }
        return home.appendingPathComponent("Documents/Drive Index")
    }

    private init() {
        defaults.register(defaults: [
            "indexOnConnect": true, "keepUpdated": true, "indexOnEject": true, "sizeMode": SizeMode.exceptNetwork.rawValue,
            "textLevels": 3, "catalog": true, "showInMenuBar": true,
            "autoLocations": [Drive.Location.external.rawValue],
            "autoMedia": Drive.Medium.allCases.map(\.rawValue),
        ])
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) } ?? Self.defaultOutputFolder
        locations = Set((defaults.stringArray(forKey: "autoLocations") ?? []).compactMap(Drive.Location.init))
        media = Set((defaults.stringArray(forKey: "autoMedia") ?? []).compactMap(Drive.Medium.init))
        indexOnConnect = defaults.bool(forKey: "indexOnConnect")
        keepUpdated = defaults.bool(forKey: "keepUpdated")
        indexOnEject = defaults.bool(forKey: "indexOnEject")
        sizeMode = SizeMode(rawValue: defaults.string(forKey: "sizeMode") ?? "") ?? .exceptNetwork
        textLevels = defaults.integer(forKey: "textLevels")
        catalog = defaults.bool(forKey: "catalog")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        openAtLogin = SMAppService.mainApp.status == .enabled
        rules = ((defaults.dictionary(forKey: "driveRules") as? [String: String]) ?? [:]).compactMapValues(Rule.init)
    }

    private func save(_ values: [String], _ key: String) {
        defaults.set(values.sorted(), forKey: key)
    }

    func rule(for drive: Drive) -> Rule { rules[drive.id] ?? .auto }

    func setRule(_ rule: Rule, for drive: Drive) {
        rules[drive.id] = rule == .auto ? nil : rule
    }

    /// Whether a drive should be indexed without being asked.
    func indexesAutomatically(_ drive: Drive) -> Bool {
        switch rule(for: drive) {
        case .always: return true
        case .never: return false
        case .auto:
            guard locations.contains(drive.location) else { return false }
            // Type only applies to physical drives; network drives and disk images have no hardware type.
            switch drive.location {
            case .network, .diskImage: return true
            case .external, .internal: return media.contains(drive.medium)
            }
        }
    }

    func includesSizes(_ drive: Drive) -> Bool {
        switch sizeMode {
        case .all: return true
        case .never: return false
        case .exceptNetwork: return drive.location != .network
        }
    }

    func set(_ location: Drive.Location, _ on: Bool) {
        if on { locations.insert(location) } else { locations.remove(location) }
    }

    func set(_ medium: Drive.Medium, _ on: Bool) {
        if on { media.insert(medium) } else { media.remove(medium) }
    }

    private func applyLoginItem() {
        do {
            if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Couldn't change the login item: \(error.localizedDescription)"
        }
        syncingLogin = true
        openAtLogin = SMAppService.mainApp.status == .enabled
        syncingLogin = false
    }
}
