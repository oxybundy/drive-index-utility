# Changelog

## 2.1.0

- New **When a drive is ejected** setting: changes made just before ejecting are added to the index before the drive goes, whether you eject from Finder, the menu bar or the Terminal
- The drive type checkboxes now only apply to external and internal drives; network drives and disk images follow the Where checkboxes alone
- "Unknown" drive type is now called "Other", and every checkbox explains itself on hover
- A drive that was indexed before now catches up from its change log when connected, instead of sometimes being rescanned in full

## 2.0.0

Rewritten as a native app.

- Window listing connected drives, with their type, free space and when they were last indexed
- Menu bar menu with **Index Now**, **Index and Eject** and **Open Report** for each drive
- Indexes drives when they're connected and keeps the index current while they stay connected
- Choose which kinds of drives are indexed automatically, and override it per drive
- Choose where reports are saved
- Records every folder level; the text report shows as many levels as you pick
- New JSON report and a searchable HTML catalog of all drives
- Much faster scanning, and later scans only revisit folders that changed
- Startup disk is no longer offered for indexing
- Folder names with characters like `|`, `[`, `$` or quotes no longer break the report
- A failed scan no longer wipes the previous report
- Drives with the same name no longer overwrite each other's reports
- Sizes use one unit system throughout (1 GB = 1,000,000,000 bytes, as in Finder)
- New app icon

## 1.1

- Drive details in the report header: identifier, volume UUID, file system, connection and space used
- Sizes for each top-level folder

## 1.0

- Two-level folder listing of a chosen drive, saved to a text file in Documents
