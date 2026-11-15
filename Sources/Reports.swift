import Foundation

/// The per-drive JSON file. It's also what the catalog is built from, so other Macs writing to the
/// same folder show up in the catalog too.
struct DriveReport: Codable {
    struct DriveInfo: Codable {
        var name: String
        var volumeID: String
        var type: String
        var fileSystem: String
        var device: String?
        var capacity: Int64
        var used: Int64
    }

    struct Node: Codable {
        var name: String
        var size: Int64?
        var package: Bool?
        var folders: [Node]
    }

    var format = "drive-index"
    var version = 1
    var indexed: Date
    var computer: String?
    var drive: DriveInfo
    var sizesIncluded: Bool
    var folders: [Node]

    init(drive: Drive, tree: Folder, indexed: Date) {
        self.indexed = indexed
        self.computer = Host.current().localizedName
        self.drive = DriveInfo(name: drive.name, volumeID: drive.id, type: drive.kind, fileSystem: drive.fileSystem,
                               device: drive.device, capacity: drive.capacity, used: drive.used)
        self.sizesIncluded = tree.files != nil
        func node(_ f: Folder) -> Node {
            Node(name: f.name, size: f.size, package: f.package, folders: f.package == true ? [] : f.children.map(node))
        }
        self.folders = tree.children.map(node)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum Format {
    /// Finder-style decimal units, always one decimal place so columns line up.
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        for (unit, div) in units where Double(bytes) >= div {
            return String(format: "%.1f %@", Double(bytes) / div, unit)
        }
        return "\(bytes) B"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// "just now", "2 min ago", "3 hr ago", "yesterday", then "Nov 12".
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600)) hr ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMMd" : "yMMMd")
        return f.string(from: date)
    }
}

enum ReportWriter {
    // MARK: Text

    static func text(_ r: DriveReport, levels: Int) -> String {
        var lines: [String] = []
        lines.append(r.drive.name)
        lines.append(String(repeating: "=", count: max(3, r.drive.name.count)))
        let percent = r.drive.capacity > 0 ? Int((Double(r.drive.used) / Double(r.drive.capacity) * 100).rounded()) : 0
        var rows: [(String, String)] = [
            ("Indexed", Format.stamp.string(from: r.indexed)),
            ("Capacity", Format.size(r.drive.capacity)),
            ("Used", "\(Format.size(r.drive.used)) (\(percent)%)"),
            ("Free", Format.size(r.drive.capacity - r.drive.used)),
            ("Type", r.drive.type.replacingOccurrences(of: " · ", with: ", ")),
            ("Format", r.drive.fileSystem),
        ]
        if let device = r.drive.device { rows.append(("Device", device)) }
        rows.append(("Volume ID", r.drive.volumeID))
        if let computer = r.computer { rows.append(("Indexed on", computer)) }
        for (k, v) in rows { lines.append(k.padding(toLength: 11, withPad: " ", startingAt: 0) + v) }
        lines.append("")

        if r.sizesIncluded {
            lines.append("    Size  Folder")
            lines.append("--------  " + String(repeating: "-", count: 30))
        } else {
            lines.append("Folder")
            lines.append(String(repeating: "-", count: 30))
        }

        func walk(_ n: DriveReport.Node, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            // A newline or tab in a folder name would break the layout.
            let name = String(String.UnicodeScalarView(n.name.unicodeScalars.map {
                $0.properties.generalCategory == .control ? "?" : $0
            }))
            let label = indent + name + "/"
            if r.sizesIncluded {
                let s = Format.size(n.size)
                lines.append(String(repeating: " ", count: max(0, 8 - s.count)) + s + "  " + label)
            } else {
                lines.append(label)
            }
            if levels == 0 || depth + 1 < levels { n.folders.forEach { walk($0, depth: depth + 1) } }
        }
        for (i, top) in r.folders.enumerated() {
            if i > 0 { lines.append("") }
            walk(top, depth: 0)
        }
        if r.folders.isEmpty { lines.append("(no folders)") }
        lines.append("")
        if levels > 0 {
            lines.append("Showing \(levels) folder level\(levels == 1 ? "" : "s"). Every level is in")
            lines.append("\(fileBase(r)).json and Drive Catalog.html.")
        }
        return asciiOnly(lines.joined(separator: "\n") + "\n")
    }

    /// Plain ASCII opens correctly everywhere, including viewers that guess the wrong encoding.
    static func asciiOnly(_ s: String) -> String {
        let folded = s.applyingTransform(.toLatin, reverse: false)?
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US")) ?? s
        return String(String.UnicodeScalarView(folded.unicodeScalars.map { $0.isASCII ? $0 : "?" }))
    }

    // MARK: Files

    /// Report file name for a drive. Two different drives with the same name get the start of their
    /// volume ID added so they don't overwrite each other.
    static func fileBase(_ r: DriveReport) -> String {
        sanitize(r.drive.name)
    }

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        return s.isEmpty ? "Untitled" : s
    }

    static func chooseFileBase(for report: DriveReport, in folder: URL) -> String {
        let base = sanitize(report.drive.name)
        let existing = folder.appendingPathComponent(base + ".json")
        guard let data = try? Data(contentsOf: existing),
              let other = try? DriveReport.decoder.decode(DriveReport.self, from: data),
              other.drive.volumeID != report.drive.volumeID else { return base }
        let short = report.drive.volumeID.replacingOccurrences(of: "-", with: "").prefix(6)
        return "\(base) (\(short))"
    }

    /// Writes the text and JSON reports. Each file is written to a temporary file first and moved into
    /// place, so a failed run never leaves a half-written report behind.
    static func write(_ report: DriveReport, base: String, to folder: URL, levels: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = try DriveReport.encoder.encode(report)
        try json.write(to: folder.appendingPathComponent(base + ".json"), options: .atomic)
        let txt = text(report, levels: levels).replacingOccurrences(of: "\(fileBase(report)).json", with: "\(base).json")
        try Data(txt.utf8).write(to: folder.appendingPathComponent(base + ".txt"), options: .atomic)
    }

    static func removeReports(base: String, in folder: URL) {
        for ext in ["txt", "json"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(base).\(ext)"))
        }
    }

    // MARK: Catalog

    static func loadReports(in folder: URL) -> [DriveReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var newest: [String: DriveReport] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let r = try? DriveReport.decoder.decode(DriveReport.self, from: data),
                  r.format == "drive-index" else { continue }
            if let seen = newest[r.drive.volumeID], seen.indexed >= r.indexed { continue }
            newest[r.drive.volumeID] = r
        }
        return newest.values.sorted { $0.drive.name.localizedStandardCompare($1.drive.name) == .orderedAscending }
    }

    static func writeCatalog(in folder: URL, connected: Set<String>) throws {
        let reports = loadReports(in: folder)
        let html = catalogHTML(reports, connected: connected)
        try Data(html.utf8).write(to: folder.appendingPathComponent("Drive Catalog.html"), options: .atomic)
    }

    static func catalogHTML(_ reports: [DriveReport], connected: Set<String>) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func tree(_ nodes: [DriveReport.Node], total: Int64, sizes: Bool, depth: Int) -> String {
            var out = ""
            for n in nodes {
                var row = "<span class=\"nm\">\(esc(n.name))</span>"
                if sizes {
                    let pct = total > 0 ? max(0.5, Double(n.size ?? 0) / Double(total) * 100) : 0
                    row += "<span class=\"bar\"><i style=\"width:\(String(format: "%.1f", pct))%\"></i></span>"
                    row += "<span class=\"sz\">\(Format.size(n.size))</span>"
                }
                if n.folders.isEmpty {
                    out += "<div class=\"leaf\">\(row)</div>"
                } else {
                    out += "<details\(depth == 0 ? " open" : "")><summary>\(row)</summary><div class=\"kids\">"
                        + tree(n.folders, total: total, sizes: sizes, depth: depth + 1) + "</div></details>"
                }
            }
            return out
        }

        var cards = ""
        for r in reports {
            let isConnected = connected.contains(r.drive.volumeID)
            let pct = r.drive.capacity > 0 ? Int(Double(r.drive.used) / Double(r.drive.capacity) * 100) : 0
            let status = isConnected ? "Connected" : "Last seen"
            let computer = r.computer.map { " on \(esc($0))" } ?? ""
            cards += """
            <section class="drive \(r.sizesIncluded ? "" : "nosize")">
              <header>
                <div>
                  <h2>\(esc(r.drive.name))</h2>
                  <p class="meta">\(esc(r.drive.type)) · \(esc(r.drive.fileSystem)) · \(Format.size(r.drive.used)) of \(Format.size(r.drive.capacity)) used</p>
                </div>
                <p class="when"><span class="dot\(isConnected ? " on" : "")"></span>\(status) · Indexed \(Format.stamp.string(from: r.indexed))\(computer)</p>
              </header>
              <div class="cap"><i style="width:\(pct)%"></i></div>
              <div class="tree">\(tree(r.folders, total: r.drive.used, sizes: r.sizesIncluded, depth: 0))</div>
            </section>

            """
        }
        let updated = Format.stamp.string(from: Date())
        let count = "\(reports.count) drive\(reports.count == 1 ? "" : "s")"
        return catalogTemplate
            .replacingOccurrences(of: "{{SUBTITLE}}", with: "\(count) · Updated \(updated)")
            .replacingOccurrences(of: "{{DRIVES}}", with: cards.isEmpty ? "<p class=\"empty\" style=\"display:block\">No drives indexed yet.</p>" : cards)
    }

    private static let catalogTemplate = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Drive Catalog</title>
    <style>
    :root { --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #e3e3e8;
      --accent: #0a84ff; --track: #ececf0; --hit: #fff2a8; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c;
        --track: #3a3a3c; --hit: #5c4d00; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--text);
      font: 14px/20px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    main { max-width: 760px; margin: 0 auto; padding: 32px 16px 48px; }
    h1 { font-size: 24px; line-height: 30px; font-weight: 600; margin: 0; }
    .sub { color: var(--muted); margin: 4px 0 20px; }
    input[type=search] { width: 100%; height: 36px; padding: 0 12px; border-radius: 8px; border: 1px solid var(--line);
      background: var(--card); color: var(--text); font: inherit; margin-bottom: 20px; }
    .drive { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin-bottom: 16px; }
    .drive header { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
    h2 { font-size: 17px; line-height: 22px; font-weight: 600; margin: 0; }
    .meta, .when { color: var(--muted); font-size: 12px; line-height: 16px; margin: 2px 0 0; }
    .when { display: flex; align-items: center; gap: 6px; margin: 3px 0 0; }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--line); }
    .dot.on { background: #30d158; }
    .cap { height: 4px; border-radius: 2px; background: var(--track); margin: 12px 0 8px; }
    .cap i { display: block; height: 100%; border-radius: 2px; background: var(--accent); }
    summary, .leaf { display: grid; grid-template-columns: minmax(0, 1fr) 120px 72px; gap: 12px; align-items: center;
      min-height: 32px; padding: 0 4px 0 20px; position: relative; border-radius: 6px; }
    .nosize summary, .nosize .leaf { grid-template-columns: minmax(0, 1fr); }
    summary { list-style: none; cursor: pointer; }
    summary::-webkit-details-marker { display: none; }
    summary::before { content: ""; position: absolute; left: 6px; top: 50%; width: 5px; height: 5px; margin-top: -4px;
      border-right: 1.5px solid var(--muted); border-bottom: 1.5px solid var(--muted); transform: rotate(-45deg); transition: transform .15s; }
    details[open] > summary::before { transform: rotate(45deg); margin-top: -5px; }
    summary:hover, .leaf:hover { background: var(--bg); }
    .kids { margin-left: 16px; border-left: 1px solid var(--line); padding-left: 4px; }
    .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar { height: 4px; border-radius: 2px; background: var(--track); }
    .bar i { display: block; height: 100%; border-radius: 2px; background: var(--accent); opacity: .55; }
    .sz { text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; font-size: 13px; }
    mark { background: var(--hit); color: inherit; border-radius: 3px; }
    .empty { color: var(--muted); text-align: center; padding: 24px 0; display: none; }
    @media (max-width: 520px) { summary, .leaf { grid-template-columns: minmax(0, 1fr) 64px; } .bar { display: none; } }
    </style>
    </head>
    <body>
    <main>
      <h1>Drive Catalog</h1>
      <p class="sub">{{SUBTITLE}}</p>
      <input type="search" id="q" placeholder="Search folders on every drive" autocomplete="off">
      {{DRIVES}}
      <p class="empty" id="none">No folders match.</p>
    </main>
    <script>
    const q = document.getElementById('q');
    const drives = [...document.querySelectorAll('.drive')];
    const names = [...document.querySelectorAll('.nm')];
    names.forEach(n => n.dataset.t = n.textContent);
    const saved = new Map();
    q.addEventListener('input', () => {
      const s = q.value.trim().toLowerCase();
      if (s && saved.size === 0) document.querySelectorAll('details').forEach(d => saved.set(d, d.open));
      names.forEach(n => {
        const t = n.dataset.t, i = s ? t.toLowerCase().indexOf(s) : -1;
        n.textContent = '';
        if (i >= 0) {
          const m = document.createElement('mark');
          m.textContent = t.slice(i, i + s.length);
          n.append(t.slice(0, i), m, t.slice(i + s.length));
        } else n.textContent = t;
      });
      let any = !s;
      drives.forEach(d => {
        if (!s) { d.hidden = false; return; }
        const hit = d.querySelector('mark') !== null;
        d.hidden = !hit;
        any = any || hit;
        d.querySelectorAll('details').forEach(x => x.open = x.querySelector('.kids mark') !== null);
      });
      if (!s) { saved.forEach((open, d) => d.open = open); saved.clear(); }
      document.getElementById('none').style.display = any ? 'none' : 'block';
    });
    </script>
    </body>
    </html>

    """
}
