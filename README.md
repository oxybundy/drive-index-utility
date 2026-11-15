# Drive Index Utility

Keeps a record of what's on each of your drives: every folder and its size, saved as plain text and as a searchable catalog you can open on any device.

- Indexes a drive when you connect it and keeps the index current while it's connected
- **Index and Eject** from the menu bar
- Choose which drives are indexed automatically: external, internal, network or disk images; SSDs, spinning disks or memory cards
- Saves reports to any folder. Pick one in iCloud Drive, Dropbox or Google Drive to read them on your phone
- macOS 13 or later, Apple Silicon and Intel

## Install

1. **[Download DriveIndexUtility.dmg](https://github.com/oxybundy/drive-index-utility/releases/latest/download/DriveIndexUtility.dmg)**
2. Open it and drag **Drive Index Utility** onto the **Applications** folder next to it.
3. Eject the disk image and open Drive Index Utility from Applications or Spotlight.

### "Apple could not verify…" the first time

The app isn't notarized by Apple, so macOS blocks the first launch:

- **macOS 15 (Sequoia) and later:** try to open it once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
- **macOS 13–14:** right-click the app → **Open** → **Open**.

## Reports

Each drive gets two files in the folder you choose, plus one catalog for all of them:

| File | What it's for |
|---|---|
| `Drive Name.txt` | Plain text: drive details and folders with sizes. Opens on anything, including a phone. |
| `Drive Name.json` | Every folder at every level, for the catalog or your own scripts. |
| `Drive Catalog.html` | All your drives in one page, with search and expandable folders. Drives that aren't connected stay listed with when they were last seen. |

If you run the app on more than one Mac and point them at the same synced folder, the catalog includes drives from all of them.

## How indexing works

Folder sizes mean adding up every file on the drive, so the first index of a large drive can take a few minutes. After that the app uses the drive's own change log (the same one Spotlight and Time Machine use) to rescan only the folders that changed, which usually takes seconds. Scans run at low disk priority so copying to or from the drive isn't slowed down.

Network drives are slow to scan because every folder is a round trip to the other computer, so by default they're listed without sizes. For a drive attached to another Mac, it's much faster to run the app on that Mac.

Right-click a drive in the list to rescan it from scratch or to override the automatic setting for just that drive.

## Build from source

Needs the Xcode command-line tools (`xcode-select --install`).

```sh
./build.sh          # build/Drive Index Utility.app
./build.sh dmg      # build/DriveIndexUtility.dmg
./build.sh install  # build and copy into /Applications
```

Every push to `main` builds the DMG on GitHub Actions and publishes it as a release tagged with the version in `Resources/Info.plist`. For a new release, bump `CFBundleShortVersionString` and add a matching section to `CHANGELOG.md`; that section becomes the release notes.

`design/AppIcon.svg` is the icon source; `Resources/AppIcon.iconset` is rendered from it.
