# CWA Magic Downloads for KOReader

Download selected Calibre-Web-Automated OPDS shelves into local KOReader folders.

The plugin can discover and sync:

- Calibre-Web-Automated Magic Shelves from `/opds/magicshelfindex`
- Regular shelves from `/opds/shelfindex`
- Built-in OPDS feeds for unread books and recently added books

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
- `Limit`: maximum matching books per selected shelf.
- `Download folder`: defaults to KOReader's home folder.

## Notes

- Files are downloaded into one subfolder per selected shelf.
- Existing files are skipped.
- Downloaded and skipped files are timestamped from CWA OPDS metadata when available, so KOReader date sorting can reflect CWA's added/updated date rather than download time.
- `Remove books that no longer match` deletes files from the plugin's shelf folders when they no longer match the selected shelf and read-status filter.

## Requirements

- KOReader with plugin support.
- A Calibre-Web-Automated instance with OPDS enabled.
- Android builds need `/system/bin/curl` available for downloads.

## License

AGPL-3.0-or-later. KOReader itself is AGPL-3.0, so this plugin uses the same license family for community compatibility.

