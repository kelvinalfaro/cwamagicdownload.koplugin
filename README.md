# CWA Magic Downloads for KOReader

Download selected Calibre-Web-Automated OPDS shelves into local KOReader folders.

The plugin can discover and sync:

- Calibre-Web-Automated Magic Shelves from `/opds/magicshelfindex`
- Regular shelves from `/opds/shelfindex`
- Built-in OPDS feeds for unread books, read books, and recently added books

## Install

Copy the `cwamagicdownload.koplugin` folder to:

```text
koreader/plugins/
```

Restart KOReader, then open:

```text
Tools -> More tools -> Plugin management
```

Enable `CWA Magic Downloads` if needed.

## Configure

Open:

```text
Tools -> More tools -> CWA Magic Downloads
```

Set:

- `Server login`: your Calibre-Web-Automated base URL, username, and password.
- `Refresh shelf list from CWA`: fetches live regular and magic shelves.
- `Shelves to sync`: choose one or more shelves.
- `Read status filter`: choose unread only, read only, or all books.
- `Per-shelf read filters`: override the global read filter for a specific shelf or use that feed's default.
- `Show shelf icons`: toggles leading emoji/icons in shelf names for devices that render them as `?`.
- `Limit`: maximum matching books per selected shelf.
- `Download folder`: defaults to KOReader's home folder.

## Notes

- Files are downloaded into one subfolder per selected shelf.
- Existing files are skipped.
- Downloaded and skipped files are timestamped from CWA OPDS metadata when available, so KOReader date sorting can reflect CWA's added/updated date rather than download time.
- Temporary OPDS files are written under KOReader's own `cache` directory instead of an Android-specific app path, so Kindle/Tolino builds can write them too.
- `Remove books that no longer match` deletes files from the plugin's shelf folders when they no longer match the selected shelf and read-status filter.
- When shelf icons are hidden, shelf menu labels and local shelf folders use iconless names. Existing icon-prefixed folders are renamed during sync when possible.
- For unread-filtered shelves, books marked complete in local KOReader metadata are treated as read and removed during cleanup even if CWA's OPDS read shelf has not updated.
- When a book file is removed, its matching KOReader `.sdr` sidecar folder is removed too.
- With `Remove books that no longer match` enabled, sync also removes folders for shelves that were previously selected and then explicitly unselected.
- The plugin uses KOReader's LuaSocket/LuaSec HTTP stack first, then falls back to KOReader/system `curl` when available.
- A progress dialog is shown during shelf sync so long downloads no longer look frozen.
- If no live CWA shelves are cached yet, opening the shelf menus will refresh the list automatically.

## Requirements

- KOReader with plugin support.
- A Calibre-Web-Automated instance with OPDS enabled.

## License

AGPL-3.0-or-later. KOReader itself is AGPL-3.0, so this plugin uses the same license family for community compatibility.

