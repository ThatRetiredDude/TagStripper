# TagStripper

TagStripper is a portable Bash cleanup tool for media libraries. It removes common torrent/indexer artifacts, strips noisy release tags from file and folder names, quarantines junk for review, and keeps every destructive action behind a dry-run preview and confirmation prompt.

It is filesystem-first: no Sonarr, Radarr, qBittorrent, Plex, or other API integration is required.

## Quick Start

Keep the `TagStripper` project folder inside the media root you want to clean, alongside folders such as `Movies`, `Shows`, and `Music`:

```text
Media/
  Movies/
  Shows/
  Music/
  TagStripper/
    tagstripper.sh
    filetype-blacklist.txt
```

```bash
git clone https://github.com/ThatRetiredDude/TagStripper.git
cd TagStripper
chmod +x tagstripper.sh
bash ./tagstripper.sh /path/to/your/media/root
```

If no media root is provided, TagStripper uses the current directory:

```bash
bash ./tagstripper.sh
```

## Safety Model

Every operation follows the same flow:

```text
Scan -> Preview -> Confirm -> Execute
```

TagStripper does not permanently delete files. Cleanup actions move junk into a `junk/` folder under the selected media root so you can review it later.

Renames and moves are collision-safe. If a destination already exists, TagStripper creates a unique duplicate-suffixed destination instead of overwriting existing files.

## Menu Options

TagStripper currently supports:

- Clean Mac hidden files such as `._*`.
- Clean sample/proof videos.
- Clean junk folders such as `Screens`, `Screenshots`, `Proof`, `Sample`, and `Other`.
- Clean junk files using a vendored extension blacklist ([ojwc/filetype-blacklist](https://github.com/ojwc/filetype-blacklist)), minus core media/playback types (video, audio, subtitles, artwork, and selected Blu-ray metadata such as `.mpls` / `.clpi`).
- Remove imported `.nfo` files along with other document/config/script/archive sidecars (your *arr apps can regenerate metadata).
- Apply best-effort hardening on `junk/` after confirmed moves (`chmod 700`, warning readme, strip execute bits, optional Spotlight and Linux markers; optional macOS quarantine xattrs).
- Rename files and folders by removing common tracker/indexer release tags.
- Detect movie folders nested inside other movie folders and selectively move them up one branch.
- Run a combined full cleanup preview for the lower-risk cleanup and rename actions.

Nested movie folder detection intentionally stays outside full cleanup because moving whole movie folders is higher risk and should be explicitly selected.

## What TagStripper Is

TagStripper is a hybrid of four systems:

1. A media renamer, similar in spirit to FileBot.
   - Uses `sanitize_name()`.
   - Removes release groups and tracker tags.
   - Normalizes filenames and folder names.

2. A torrent artifact cleaner, similar in spirit to Cleanuperr.
   - Detects tracker/sample junk plus extension blacklist entries loaded from `filetype-blacklist.txt`.
   - Quarantines junk instead of deleting it.
   - Treats imported docs, scripts, archives, configs, and `.nfo` sidecars as removable junk while preserving core media/playback files.

3. A filesystem janitor.
   - Routes junk into a reviewable `junk/` folder.
   - Traverses directories recursively.
   - Ignores safe zones such as the quarantine folder.

4. A manual safety layer.
   - Shows dry-run previews.
   - Requires explicit confirmation.
   - Supports interactive selection for higher-risk moves.
   - Shows old and new paths before execution.

## Is There Something Identical?

Not as a single tool.

The closest match is a stack of separate tools:

- Cleanuperr for backend cleanup logic.
- FileBot for renaming intelligence.
- qbit_manage for torrent automation rules.
- Miscellaneous torrent cleaners for partial junk removal.

TagStripper is basically:

```text
FileBot + Cleanuperr + manual control layer + portable Bash glue
```

## Why This Is Useful

Many existing tools either automate everything or require integration with a specific download client or media manager.

TagStripper is different because it:

- Works directly on the filesystem.
- Is not tied to qBittorrent, Sonarr, Radarr, or any other API.
- Works on any folder structure.
- Keeps a human in the loop with dry-run previews and confirmation.
- Can be used as a one-off cleanup tool from any shell.

That combination is rare.

## Requirements

- Bash 4+ (`mapfile`, associative arrays)
- `find`
- `sort`
- `awk`
- `perl`
- Standard Unix utilities available on macOS and most Linux systems

Optional hardening uses `xattr` / `setfattr` / `wslpath` + Windows `attrib.exe` when available.

macOS note: the system `/bin/bash` is often Bash 3.2. Install a newer Bash and run TagStripper with that shell if you see a Bash version error.

Do not run cleanup against active downloader working directories. If partial download files such as `.part`, `.partial`, `.crdownload`, or `.!qB` are queued, TagStripper shows an extra confirmation prompt.

## License

Apache License 2.0. See [LICENSE](LICENSE).
