# TagStripper

TagStripper is a portable Bash cleanup tool for media libraries. It removes common torrent/indexer artifacts, strips noisy release tags from file and folder names, quarantines junk for review, and keeps every destructive action behind a dry-run preview and confirmation prompt.

It is filesystem-first: no Sonarr, Radarr, qBittorrent, Plex, or other API integration is required.

## Quick Start

```bash
git clone https://github.com/ThatRetiredDude/TagStripper.git
cd TagStripper
chmod +x tagstripper.sh
./tagstripper.sh /path/to/your/media/root
```

If no media root is provided, TagStripper uses the current directory:

```bash
./tagstripper.sh
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
- Clean strict junk sidecar files such as tracker text files and download breadcrumbs.
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
   - Detects `.txt`, sample, proof, and tracker junk files.
   - Quarantines strict junk instead of deleting it.
   - Avoids broad guesses that could remove useful metadata.

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

- Bash
- `find`
- `sort`
- `awk`
- `perl`
- Standard Unix utilities available on macOS and most Linux systems

## License

Apache License 2.0. See [LICENSE](LICENSE).
