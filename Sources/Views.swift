import AppKit
import SwiftUI

enum PathDisplay {
    /// "iCloud Drive › Drive Index" or "Documents › Drive Index".
    static func pretty(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        let path = url.path
        var parts: [String]
        if path.hasPrefix(iCloud) {
            parts = ["iCloud Drive"] + path.dropFirst(iCloud.count).split(separator: "/").map(String.init)
        } else if path.hasPrefix(home + "/") {
            parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        } else {
            parts = path.split(separator: "/").map(String.init)
        }
        return parts.joined(separator: " › ")
    }

    static func symbol(_ url: URL) -> String {
        url.path.contains("/Library/Mobile Documents/") || url.path.contains("/Library/CloudStorage/") ? "icloud" : "folder"
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Meter: View {
    var fraction: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor))
                if let fraction {
                    Capsule().fill(Color.accentColor).frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
        }
        .frame(height: 4)
    }
}

/// A native pop-up button at a fixed width, so pop-ups line up with each other and with the switches.
private struct PopUp<Value: Hashable>: NSViewRepresentable {
    let items: [(String, Value)]
    @Binding var selection: Value
    var width: CGFloat = 200

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.numberOfItems != items.count {
            button.removeAllItems()
            button.addItems(withTitles: items.map(\.0))
        }
        if let i = items.firstIndex(where: { $0.1 == selection }) { button.selectItem(at: i) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUp
        init(_ parent: PopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let i = sender.indexOfSelectedItem
            if parent.items.indices.contains(i) { parent.selection = parent.items[i].1 }
        }
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var indexer = Indexer.shared
    @ObservedObject var settings = Settings.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Drives")
            Card {
                if indexer.drives.isEmpty {
                    Text("Connect a drive to index it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        VStack(spacing: 0) {
                            ForEach(Array(indexer.drives.enumerated()), id: \.element.id) { i, drive in
                                if i > 0 { Divider().padding(.leading, 48) }
                                DriveRow(drive: drive)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: PathDisplay.symbol(settings.outputFolder))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(PathDisplay.pretty(settings.outputFolder))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Open Catalog") { NSWorkspace.shared.open(indexer.catalogURL) }
                    .disabled(!FileManager.default.fileExists(atPath: indexer.catalogURL.path))
                Button("Settings…", action: openSettings)
            }
            .controlSize(.small)
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 560)
    }
}

struct DriveRow: View {
    let drive: Drive
    @ObservedObject var indexer = Indexer.shared
    @ObservedObject var settings = Settings.shared

    private var activity: Indexer.Activity { indexer.activity[drive.id] ?? .idle }
    private var busy: Bool { if case .scanning = activity { return true } else { return false } }

    private var subtitle: (String, Color) {
        switch activity {
        case .scanning(let text, _): return (text, .accentColor)
        case .failed(let message): return (message, .red)
        case .idle:
            let space = "\(Format.size(drive.used)) of \(Format.size(drive.capacity))"
            if let date = indexer.lastIndexed[drive.id] {
                return ("\(space) · Indexed \(Format.relative(date))", .secondary)
            }
            return ("\(space) · \(settings.indexesAutomatically(drive) ? "Not indexed yet" : "Manual only")", .secondary)
        }
    }

    private var meter: Double? {
        switch activity {
        case .scanning(_, let fraction): return fraction ?? 0.04
        default: return drive.capacity > 0 ? Double(drive.used) / Double(drive.capacity) : nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: drive.symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(drive.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle.0)
                    .font(.system(size: 12))
                    .foregroundStyle(subtitle.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Meter(fraction: meter)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(drive.tag)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(width: 124, alignment: .trailing)

            Button(busy ? "Cancel" : "Index Now") {
                if busy { indexer.cancel(drive.id) } else { indexer.index(drive) }
            }
            .controlSize(.small)
            .frame(width: 84)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { DriveMenu(drive: drive) }
    }
}

struct DriveMenu: View {
    let drive: Drive
    @ObservedObject var settings = Settings.shared
    private var indexer: Indexer { Indexer.shared }

    var body: some View {
        Button("Index Now") { indexer.index(drive) }
        Button("Rescan Everything") { indexer.index(drive, full: true) }
        if drive.isEjectable {
            Button("Index and Eject") { indexer.indexAndEject(drive) }
        }
        Divider()
        Button("Open Report") { if let url = indexer.reportURL(for: drive.id) { NSWorkspace.shared.open(url) } }
            .disabled(indexer.reportURL(for: drive.id) == nil)
        Button("Show Drive in Finder") { NSWorkspace.shared.activateFileViewerSelecting([drive.url]) }
        Divider()
        Picker("Index Automatically", selection: Binding(
            get: { settings.rule(for: drive) },
            set: { settings.setRule($0, for: drive); indexer.settingsChanged() })) {
            ForEach(Settings.Rule.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    var chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Save reports to")
            Card {
                row {
                    Image(systemName: PathDisplay.symbol(settings.outputFolder))
                        .foregroundStyle(.secondary)
                    Text(PathDisplay.pretty(settings.outputFolder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("Choose…", action: chooseFolder).controlSize(.small)
                }
            }
            .padding(.bottom, 16)

            SectionHeader(title: "Index automatically")
            Card {
                checkboxes("Where") {
                    ForEach(Drive.Location.allCases, id: \.self) { loc in
                        Toggle(loc.title, isOn: Binding(get: { settings.locations.contains(loc) },
                                                        set: { settings.set(loc, $0); Indexer.shared.settingsChanged() }))
                    }
                }
                Divider()
                checkboxes("Type") {
                    ForEach(Drive.Medium.allCases, id: \.self) { m in
                        Toggle(m.title, isOn: Binding(get: { settings.media.contains(m) },
                                                      set: { settings.set(m, $0); Indexer.shared.settingsChanged() }))
                    }
                }
                Divider()
                row {
                    Text("When a drive is connected")
                    Spacer()
                    Toggle("When a drive is connected", isOn: $settings.indexOnConnect).labelsHidden()
                }
                Divider()
                row {
                    Text("Keep up to date while connected")
                    Spacer()
                    Toggle("Keep up to date while connected", isOn: Binding(
                        get: { settings.keepUpdated },
                        set: { settings.keepUpdated = $0; Indexer.shared.settingsChanged() })).labelsHidden()
                }
            }
            .padding(.bottom, 16)

            SectionHeader(title: "Reports")
            Card {
                row {
                    Text("Folder sizes")
                    Spacer()
                    PopUp(items: Settings.SizeMode.allCases.map { ($0.title, $0) }, selection: $settings.sizeMode)
                }
                Divider()
                row {
                    Text("Levels in text report")
                    Spacer()
                    PopUp(items: (1...6).map { ("\($0)", $0) } + [("All", 0)], selection: $settings.textLevels)
                }
                Divider()
                row {
                    Text("Drive catalog (HTML)")
                    Spacer()
                    Toggle("Drive catalog (HTML)", isOn: $settings.catalog).labelsHidden()
                }
            }
            .padding(.bottom, 16)

            SectionHeader(title: "App")
            Card {
                row {
                    Text("Open at login")
                    Spacer()
                    Toggle("Open at login", isOn: $settings.openAtLogin).labelsHidden()
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Show in menu bar")
                        Spacer()
                        Toggle("Show in menu bar", isOn: $settings.showInMenuBar).labelsHidden()
                    }
                    if !settings.showInMenuBar {
                        Text("Open Drive Index Utility from Applications to get back here. Drives are still indexed in the background.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
            }

            if !settings.status.isEmpty {
                Text(settings.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 560)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
    }

    private func checkboxes<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 20) { content() }
                .toggleStyle(.checkbox)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
