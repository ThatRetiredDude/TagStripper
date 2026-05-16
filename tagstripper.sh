#!/usr/bin/env bash

# ==============================================
#     Media Cleanup Tool - Portable v8 Reversible
# ==============================================
#
# NEW IN v8:
#
# - No permanent deletes
# - Quarantines junk into ./junk for manual review
# - TRUE dry-run workflow with final destinations
# - Requires explicit y/N confirmation before any changes
# - Conservative tracker/indexer tag cleanup
# - Collision-safe quarantine and rename handling
# - Combined full-cleanup preview
#
# Workflow:
#
#   Scan → Preview → Confirm → Execute
#
# ==============================================

set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: TagStripper requires Bash 4 or newer." >&2
    echo "On macOS, install a newer Bash (for example with Homebrew) and run this script with it." >&2
    exit 1
fi

MEDIA_ROOT="${1:-$PWD}"

if [ ! -d "$MEDIA_ROOT" ]; then
    echo "Error: Media root directory '$MEDIA_ROOT' does not exist."
    exit 1
fi

MEDIA_ROOT="$(cd "$MEDIA_ROOT" && pwd)"
JUNK_DIR="$MEDIA_ROOT/junk"
TAGSTRIPPER_DIR="$MEDIA_ROOT/TagStripper"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLACKLIST_FILE="${BLACKLIST_FILE:-$SCRIPT_DIR/filetype-blacklist.txt}"

declare -a JUNK_SUFFIX_BLACKLIST=()
JUNK_PREPARED=0

# ==============================
# GLOBAL OPERATION QUEUES
# ==============================

declare -a QUARANTINE_SRC_QUEUE=()
declare -a QUARANTINE_DST_QUEUE=()
declare -a RENAME_SRC_QUEUE=()
declare -a RENAME_DST_QUEUE=()

# ==============================
# HELPERS
# ==============================

sanitize_name() {
    local name="$1"

    printf '%s\n' "$name" | perl -pe '
        s/[[:space:]._-]*\[(YTS(\.[A-Za-z]{2,})?|TGx|TorrentGalaxy|GalaxyRG|ETRG|EtHD|1337x|RARBG|YIFY|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS|LimeTorrents|KickassTorrents|KAT|ThePirateBay|TPB|PirateBay|TorLock|Zooqle|IsoHunt|TorrentDownloads|TorrentFunk|YourBittorrent|MagnetDL)\]//gi;
        s/[[:space:]._-]*(YTS\.[A-Za-z]{2,}|YIFYstatus|RARBG[.]?(COM|TO)?|MkvCage([.]ws)?)(?=([[:space:]._-]|$))//gi;
        s/[[:space:]_-]+(TGx|TorrentGalaxy|GalaxyRG|ETRG|RARBG|YIFY|1337x|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS)(?=([[:space:]_.-]|$))//gi;
        s/[.](YIFY|TGx|TorrentGalaxy|GalaxyRG|ETRG|RARBG|1337x|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS)(?=([.]|$))//gi;
        s/\.\.+/./g;
        s/-\.+/./g;
        s/\.-+/./g;
        s/[[:space:]]{2,}/ /g;
        s/[[:space:]._-]+$//g;
        s/^[[:space:]._-]+//g;
        s/\.+$//g;
        s/^\.+//g;
        s/^[[:space:]]+//;
        s/[[:space:]]+$//;
    '
}

has_tracker_noise() {
    local name="$1"

    printf '%s\n' "$name" | perl -ne '
        exit 0 if /[[:space:]._-]\[(YTS(\.[A-Za-z]{2,})?|TGx|TorrentGalaxy|GalaxyRG|ETRG|EtHD|1337x|RARBG|YIFY|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS|LimeTorrents|KickassTorrents|KAT|ThePirateBay|TPB|PirateBay|TorLock|Zooqle|IsoHunt|TorrentDownloads|TorrentFunk|YourBittorrent|MagnetDL)\]/i;
        exit 0 if /(^|[[:space:]._-])(YTS\.[A-Za-z]{2,}|YIFYstatus|RARBG[.]?(COM|TO)?|MkvCage([.]ws)?)([[:space:]._-]|$)/i;
        exit 0 if /[[:space:]_-]+(TGx|TorrentGalaxy|GalaxyRG|ETRG|RARBG|YIFY|1337x|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS)([[:space:]_.-]|$)/i;
        exit 0 if /[.](YIFY|TGx|TorrentGalaxy|GalaxyRG|ETRG|RARBG|1337x|ExtraTorrent|Demonoid|PSArips|ETTV|EZTV|GloDLS)([.]|$)/i;
        exit 1;
    '
}

is_rename_candidate_type() {
    local item="$1"
    local base
    local lower

    base="$(basename "$item")"
    [[ "$base" == ._* ]] && return 1

    [[ -d "$item" ]] && return 0

    lower="$(printf '%s\n' "$item" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *.mkv|*.mp4|*.avi|*.mov|*.m4v|*.wmv|*.webm|*.srt|*.ass|*.ssa|*.sub)
            return 0
            ;;
    esac

    return 1
}

is_strict_junk_sidecar() {
    local file="$1"
    local base
    local lower

    base="$(basename "$file")"
    lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        readme*.txt|*readme*.txt|*torrent*download*.txt|*downloaded*from*.txt|*www*.txt|*.url|*.website)
            return 0
            ;;
        rarbg.txt|rarbg.com.txt|yts.mx.txt|yify.txt|1337x.txt|torrentgalaxy.txt|tgx.txt|extratorrent.txt|demonoid.txt)
            return 0
            ;;
        rarbg.mp4|rarbg.mkv|sample.avi|sample.mkv|sample.mp4|proof.mkv|proof.mp4)
            return 0
            ;;
        _*.nfo)
            has_tracker_noise "$base" && return 0
            ;;
    esac

    return 1
}

# True if blacklist suffix should be ignored because it matches library media/playback files.
media_suffix_allowed() {
    local bl="$1"
    local ext
    local suf
    local blen
    local slen

    local -a ordered=(
        movpkg thumb avchd m2ts jpeg webm flac mpls bdmv bdjo clpi
        mkv mp4 avi mov m4v wmv flv ts vob cue
        mp3 m4a wav wma aif mpa mid aac opus
        srt ass ssa sub idx m3u
        jpg png gif bmp tif tiff svg thm
    )

    for ext in "${ordered[@]}"; do
        suf=".$ext"
        slen=${#suf}
        blen=${#bl}
        ((blen >= slen)) || continue
        [[ "${bl:blen - slen}" == "$suf" ]] && return 0
    done

    return 1
}

load_junk_suffix_blacklist() {
    local line
    local suffix
    declare -A seen=()
    declare -a raw=()

    if [[ -f "$BLACKLIST_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
            [[ "$line" != *\** ]] && continue

            if [[ "$line" =~ ^\*\.(.+)$ ]]; then
                suffix=".${BASH_REMATCH[1]}"
            else
                continue
            fi

            suffix="$(printf '%s\n' "$suffix" | tr '[:upper:]' '[:lower:]')"
            [[ "$suffix" == *" "* || "$suffix" == *'"'* ]] && continue

            raw+=("$suffix")
        done <"$BLACKLIST_FILE"
    else
        printf '%s\n' "Warning: blacklist file not found: $BLACKLIST_FILE" >&2
    fi

    local -a extras=(
        .nfo .txt .xml .json .pdf .log .md .readme .html .htm .csv
        .doc .docx .docm .dot .dotm .xls .xlsx .xlsm .xlsb .xlt .xltm .ppt .pptx .pptm .pps .ppsm .odt .rtf .epub .mobi
        .db .ini .conf .config
        .exe .msi .dmg .pkg .app .bat .cmd .ps1 .psm1 .vbs .vbe .vb .js .jse .jsx .jar .apk .com .scr .wsf .hta
        .py .pyc .pyo .pyz .python .sh .bash .zsh .csh .ksh .rb .ruby .pl .perl .php .java .c .cs .coffee .applescript .scpt .command
        .zip .rar .7z .tar .gz .iso .img
        .lnk .desktop .webloc .website .torrent
    )

    for suffix in "${extras[@]}"; do
        raw+=("$suffix")
    done

    for suffix in "${raw[@]}"; do
        media_suffix_allowed "$suffix" && continue
        [[ -n "${seen[$suffix]:-}" ]] && continue
        seen[$suffix]=1
    done

    mapfile -t JUNK_SUFFIX_BLACKLIST < <(
        for suffix in "${!seen[@]}"; do
            printf '%s\n' "$suffix"
        done | awk '{ print length($0) "\t" $0 }' | sort -t "$(printf '\t')" -nr -k1,1 | cut -f2-
    )
}

is_hidden_system_junk() {
    local path="$1"
    local base
    local lower

    base="$(basename "$path")"
    lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        .ds_store|.directory|.apdisk|.nomedia|desktop.ini|thumbs.db|ehthumbs.db|ehthumbs_vista.db)
            return 0
            ;;
    esac

    [[ "$base" == ._* ]] && return 0

    case "$lower" in
        __macosx|.spotlight-v100|.trashes|.fseventsd|.temporaryitems|.appledouble|@eadir)
            return 0
            ;;
    esac

    [[ "$lower" == '$recycle.bin' ]] && return 0
    [[ "$lower" == "system volume information" ]] && return 0

    [[ "$lower" == .trash-* ]] && return 0

    [[ "$lower" == .smbdelete* ]] && return 0

    [[ "$lower" == .~lock.* ]] && return 0

    case "$lower" in
        *.swp|*.swo|*.part|*.partial|*.crdownload|*.!qb)
            return 0
            ;;
    esac

    [[ "$lower" == *~ ]] && return 0

    return 1
}

is_partial_download_leftover() {
    local path="$1"
    local base
    local lower

    base="$(basename "$path")"
    lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        *.part|*.partial|*.crdownload|*.!qb)
            return 0
            ;;
    esac

    return 1
}

is_extension_blacklisted() {
    local base="$1"
    local lower="$2"
    local bl
    local blen
    local olen

    [[ -z "$lower" ]] && lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    for bl in "${JUNK_SUFFIX_BLACKLIST[@]}"; do
        olen=${#bl}
        blen=${#lower}
        ((blen >= olen)) || continue
        [[ "${lower:blen - olen}" == "$bl" ]] || continue
        return 0
    done

    return 1
}

prepare_junk_quarantine_environment() {
    [[ "$JUNK_PREPARED" == 1 ]] && return 0

    mkdir -p "$JUNK_DIR" || return 0
    chmod 700 "$JUNK_DIR" 2>/dev/null || true

    local readme="$JUNK_DIR/README_DO_NOT_OPEN_FILES.txt"

    if [[ ! -f "$readme" ]]; then
        cat >"$readme" <<'EOF'
Quarantined junk — may contain malware or unwanted downloads.
Do not open files here. Prefer deleting this folder after verifying your library.
EOF
    fi

    touch "$JUNK_DIR/.nomedia" 2>/dev/null || true

    if [[ "$(uname -s)" == Darwin ]]; then
        touch "$JUNK_DIR/.metadata_never_index" 2>/dev/null || true
    fi

    JUNK_PREPARED=1
}

harden_quarantined_item() {
    local dst="$1"

    [[ -e "$dst" ]] || return 0

    if [[ -f "$dst" ]]; then
        chmod a-x "$dst" 2>/dev/null || true
    elif [[ -d "$dst" ]]; then
        find "$dst" -type f -exec chmod a-x {} + 2>/dev/null || true
    fi

    local os
    os="$(uname -s)"

    if [[ "$os" == Darwin ]] && command -v xattr >/dev/null; then
        if [[ -f "$dst" ]]; then
            xattr -w com.apple.quarantine "0083;$(date +%s);TagStripper;" "$dst" 2>/dev/null || true
        elif [[ -d "$dst" ]]; then
            find "$dst" -type f -exec xattr -w com.apple.quarantine "0083;$(date +%s);TagStripper;" {} \; 2>/dev/null || true
        fi
    fi

    if [[ "$os" == Linux ]] && command -v setfattr >/dev/null; then
        if [[ -f "$dst" ]]; then
            setfattr -n user.tagstripper.quarantine -v true "$dst" 2>/dev/null || true
        elif [[ -d "$dst" ]]; then
            find "$dst" -type f -exec setfattr -n user.tagstripper.quarantine -v true {} \; 2>/dev/null || true
        fi
    fi

    if [[ "$(uname -r)" == *[Mm]icrosoft* ]] && command -v wslpath >/dev/null && [[ "$dst" == /mnt/* ]]; then
        local winpath

        winpath="$(wslpath -w "$dst" 2>/dev/null)" || winpath=""

        if [[ -n "$winpath" ]] && [[ -x "/mnt/c/Windows/System32/attrib.exe" ]]; then
            /mnt/c/Windows/System32/attrib.exe +H "$winpath" 2>/dev/null || true
        fi
    fi
}

is_in_junk() {
    local path="$1"

    [[ "$path" == "$JUNK_DIR" || "$path" == "$JUNK_DIR"/* ]]
}

is_in_tagstripper() {
    local path="$1"

    [[ "$path" == "$TAGSTRIPPER_DIR" || "$path" == "$TAGSTRIPPER_DIR"/* ]]
}

is_legitimate_nested_subfolder() {
    local folder="$1"
    local base
    local lower

    base="$(basename "$folder")"
    lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    [[ "$lower" == "trickplay" ]]
}

contains_video_file() {
    local folder="$1"
    local found

    found="$(find "$folder" -maxdepth 1 -type f \( \
        -iname "*.mkv" -o \
        -iname "*.mp4" -o \
        -iname "*.avi" -o \
        -iname "*.mov" -o \
        -iname "*.m4v" -o \
        -iname "*.wmv" \
    \) -print -quit)"

    [[ -n "$found" ]]
}

relative_to_media_root() {
    local path="$1"

    if [[ "$path" == "$MEDIA_ROOT"/* ]]; then
        printf '%s\n' "${path#"$MEDIA_ROOT"/}"
    else
        printf '%s\n' "$(basename "$path")"
    fi
}

destination_reserved() {
    local candidate="$1"
    local dst

    for dst in "${QUARANTINE_DST_QUEUE[@]}"; do
        [[ "$dst" == "$candidate" ]] && return 0
    done

    for dst in "${RENAME_DST_QUEUE[@]}"; do
        [[ "$dst" == "$candidate" ]] && return 0
    done

    return 1
}

unique_destination() {
    local candidate="$1"
    local suffix="$2"
    local unique="$candidate"
    local counter=1

    while [[ -e "$unique" ]] || destination_reserved "$unique"; do
        unique="${candidate}.${suffix}-${RUN_ID}-${counter}"
        ((counter+=1))
    done

    printf '%s\n' "$unique"
}

quarantine_destination_for() {
    local src="$1"
    local rel
    local candidate

    rel="$(relative_to_media_root "$src")"
    candidate="$JUNK_DIR/$rel"

    unique_destination "$candidate" "duplicate"
}

is_under_queued_quarantine_dir() {
    local path="$1"
    local src

    for src in "${QUARANTINE_SRC_QUEUE[@]}"; do
        if [[ -d "$src" && "$path" == "$src"/* ]]; then
            return 0
        fi
    done

    return 1
}

remove_queued_children_of() {
    local parent="$1"
    local new_src=()
    local new_dst=()
    local i

    for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
        if [[ "${QUARANTINE_SRC_QUEUE[$i]}" == "$parent"/* ]]; then
            continue
        fi

        new_src+=("${QUARANTINE_SRC_QUEUE[$i]}")
        new_dst+=("${QUARANTINE_DST_QUEUE[$i]}")
    done

    QUARANTINE_SRC_QUEUE=("${new_src[@]}")
    QUARANTINE_DST_QUEUE=("${new_dst[@]}")
}

queue_quarantine() {
    local src="$1"
    local dst

    is_in_junk "$src" && return
    is_in_tagstripper "$src" && return
    is_under_queued_quarantine_dir "$src" && return

    if [[ -d "$src" ]]; then
        remove_queued_children_of "$src"
    fi

    dst="$(quarantine_destination_for "$src")"

    QUARANTINE_SRC_QUEUE+=("$src")
    QUARANTINE_DST_QUEUE+=("$dst")
}

queue_rename() {
    local src="$1"
    local dst="$2"
    local unique_dst

    is_in_junk "$src" && return
    is_in_tagstripper "$src" && return
    is_under_queued_quarantine_dir "$src" && return

    unique_dst="$(unique_destination "$dst" "duplicate")"

    RENAME_SRC_QUEUE+=("$src")
    RENAME_DST_QUEUE+=("$unique_dst")
}

sort_quarantine_queue() {
    local entries=()
    local sorted=()
    local new_src=()
    local new_dst=()
    local i
    local entry
    local idx

    for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
        entries+=("$(printf '%08d\t%08d\t%s\n' "${#QUARANTINE_SRC_QUEUE[$i]}" "$i" "${QUARANTINE_SRC_QUEUE[$i]}")")
    done

    mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -r)

    for entry in "${sorted[@]}"; do
        idx="$(printf '%s\n' "$entry" | awk -F '\t' '{print $2 + 0}')"
        new_src+=("${QUARANTINE_SRC_QUEUE[$idx]}")
        new_dst+=("${QUARANTINE_DST_QUEUE[$idx]}")
    done

    QUARANTINE_SRC_QUEUE=("${new_src[@]}")
    QUARANTINE_DST_QUEUE=("${new_dst[@]}")
}

sort_rename_queue() {
    local entries=()
    local sorted=()
    local new_src=()
    local new_dst=()
    local i
    local entry
    local idx
    local kind

    for i in "${!RENAME_SRC_QUEUE[@]}"; do
        if [[ -d "${RENAME_SRC_QUEUE[$i]}" ]]; then
            kind=1
        else
            kind=0
        fi

        entries+=("$(printf '%01d\t%08d\t%08d\t%s\n' "$kind" "${#RENAME_SRC_QUEUE[$i]}" "$i" "${RENAME_SRC_QUEUE[$i]}")")
    done

    mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -t "$(printf '\t')" -k1,1n -k2,2r)

    for entry in "${sorted[@]}"; do
        idx="$(printf '%s\n' "$entry" | awk -F '\t' '{print $3 + 0}')"
        new_src+=("${RENAME_SRC_QUEUE[$idx]}")
        new_dst+=("${RENAME_DST_QUEUE[$idx]}")
    done

    RENAME_SRC_QUEUE=("${new_src[@]}")
    RENAME_DST_QUEUE=("${new_dst[@]}")
}

prepare_queues() {
    if [ ${#QUARANTINE_SRC_QUEUE[@]} -gt 0 ]; then
        sort_quarantine_queue
    fi

    if [ ${#RENAME_SRC_QUEUE[@]} -gt 0 ]; then
        sort_rename_queue
    fi
}

clear_queues() {
    QUARANTINE_SRC_QUEUE=()
    QUARANTINE_DST_QUEUE=()
    RENAME_SRC_QUEUE=()
    RENAME_DST_QUEUE=()
}

quarantine_queue_contains_partial_download() {
    local src

    for src in "${QUARANTINE_SRC_QUEUE[@]}"; do
        if [[ -f "$src" ]] && is_partial_download_leftover "$src"; then
            return 0
        fi
    done

    return 1
}

# ==============================
# PREVIEW SYSTEM
# ==============================

preview_folder_contents() {
    local folder="$1"
    local limit=25
    local total=0
    local shown=0
    local rel

    echo "  CONTENTS:"

    while IFS= read -r item; do
        ((total+=1))

        if [ "$shown" -lt "$limit" ]; then
            rel="${item#"$folder"/}"

            if [ -d "$item" ]; then
                echo "    [DIR]  $rel/"
            else
                echo "    [FILE] $rel"
            fi

            ((shown+=1))
        fi
    done < <(find "$folder" -mindepth 1 -maxdepth 2 ! -path "*/junk/*" | sort)

    if [ "$total" -eq 0 ]; then
        echo "    (empty folder)"
    elif [ "$total" -gt "$shown" ]; then
        echo "    ... $((total - shown)) more item(s) not shown"
    fi

    echo ""
}

show_preview() {
    echo ""
    echo "======================================"
    echo "           DRY RUN PREVIEW"
    echo "======================================"
    echo ""

    local total=0

    if [ ${#QUARANTINE_SRC_QUEUE[@]} -gt 0 ]; then
        echo "FILES/FOLDERS TO QUARANTINE:"
        echo "--------------------------------------"

        for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
            echo "QUARANTINE:"
            echo "  FROM: ${QUARANTINE_SRC_QUEUE[$i]}"
            echo "  TO:   ${QUARANTINE_DST_QUEUE[$i]}"

            if [ -d "${QUARANTINE_SRC_QUEUE[$i]}" ]; then
                preview_folder_contents "${QUARANTINE_SRC_QUEUE[$i]}"
            fi

            echo ""
            ((total+=1))
        done
    fi

    if [ ${#RENAME_SRC_QUEUE[@]} -gt 0 ]; then
        echo "ITEMS TO RENAME:"
        echo "--------------------------------------"

        for i in "${!RENAME_SRC_QUEUE[@]}"; do
            echo "RENAME:"
            echo "  OLD: ${RENAME_SRC_QUEUE[$i]}"
            echo "  NEW: ${RENAME_DST_QUEUE[$i]}"
            echo ""
            ((total+=1))
        done
    fi

    if [ "$total" -eq 0 ]; then
        echo "No operations queued."
        return 1
    fi

    echo "======================================"
    echo "TOTAL OPERATIONS: $total"
    echo "======================================"
    echo ""

    return 0
}

confirm_and_execute() {
    prepare_queues

    if ! show_preview; then
        return
    fi

    read -rp "Execute these operations? (y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo ""
        echo "Aborted."
        clear_queues
        return
    fi

    if quarantine_queue_contains_partial_download; then
        echo ""
        echo "WARNING: Partial download files are queued for quarantine."
        echo "Only continue if this is a completed/imported library, not an active downloader working directory."
        read -rp "Continue with partial-download quarantine? (y/N): " partial_confirm

        if [[ "$partial_confirm" != "y" && "$partial_confirm" != "Y" ]]; then
            echo ""
            echo "Aborted."
            clear_queues
            return
        fi
    fi

    if [ ${#QUARANTINE_SRC_QUEUE[@]} -gt 0 ]; then
        JUNK_PREPARED=0
        prepare_junk_quarantine_environment
    fi

    echo ""
    echo "Executing..."
    echo ""

    # QUARANTINE MOVES
    for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
        src="${QUARANTINE_SRC_QUEUE[$i]}"
        dst="${QUARANTINE_DST_QUEUE[$i]}"

        if [[ ! -e "$src" ]]; then
            echo "Skipping missing quarantine source: $src"
            continue
        fi

        mkdir -p "$(dirname "$dst")"

        echo "Quarantining:"
        echo "  $src"
        echo "  -> $dst"

        mv "$src" "$dst"

        harden_quarantined_item "$dst"
    done

    # RENAMES
    for i in "${!RENAME_SRC_QUEUE[@]}"; do
        src="${RENAME_SRC_QUEUE[$i]}"
        dst="${RENAME_DST_QUEUE[$i]}"

        if [[ ! -e "$src" ]]; then
            echo "Skipping missing rename source: $src"
            continue
        fi

        echo "Renaming:"
        echo "  $src"
        echo "  -> $dst"

        mv "$src" "$dst"
    done

    echo ""
    echo "Completed successfully."

    clear_queues
}

# ==============================
# CLEAN MAC FILES
# ==============================

clean_mac_hidden_files() {

    clear_queues
    build_mac_hidden_files_queue
    confirm_and_execute
}

build_mac_hidden_files_queue() {

    echo ""
    echo "Scanning for Mac hidden files..."

    mapfile -t MAC_FILES < <(
        find "$MEDIA_ROOT" \
            -type f \
            -name "._*" \
            ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR/*"
    )

    for file in "${MAC_FILES[@]}"; do
        queue_quarantine "$file"
    done
}

# ==============================
# CLEAN SAMPLE VIDEOS
# ==============================

clean_sample_videos() {

    clear_queues
    build_sample_videos_queue
    confirm_and_execute
}

build_sample_videos_queue() {

    mapfile -t SAMPLES < <(
        find "$MEDIA_ROOT" -type f \( \
            -iname "sample.avi" -o \
            -iname "sample.mkv" -o \
            -iname "sample.mp4" -o \
            -iname "proof.mkv" -o \
            -iname "proof.mp4" -o \
            -iname "proof.avi" -o \
            -iname "rarbg.mp4" -o \
            -iname "rarbg.mkv" \
        \) ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR/*"
    )

    for file in "${SAMPLES[@]}"; do
        queue_quarantine "$file"
    done
}

# ==============================
# CLEAN JUNK FOLDERS
# ==============================

clean_junk_folders() {

    clear_queues
    build_junk_folders_queue
    confirm_and_execute
}

build_junk_folders_queue() {

    mapfile -t FOLDERS < <(
        find "$MEDIA_ROOT" -type d \( \
            -iname "Screens" -o \
            -iname "Screenshots" -o \
            -iname "Proof" -o \
            -iname "Sample" -o \
            -iname "Other" \
        \) ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR" \
            ! -path "$TAGSTRIPPER_DIR/*"
    )

    for folder in "${FOLDERS[@]}"; do
        queue_quarantine "$folder"
    done
}

# ==============================
# CLEAN JUNK FILES
# ==============================

clean_junk() {

    clear_queues
    build_junk_queue
    confirm_and_execute
}

build_junk_queue() {
    local path
    local base
    local lower

    mapfile -t JUNK_PATHS < <(
        find "$MEDIA_ROOT" \( -type f -o -type d \) \
            ! -path "$JUNK_DIR" \
            ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR" \
            ! -path "$TAGSTRIPPER_DIR/*"
    )

    for path in "${JUNK_PATHS[@]}"; do
        base="$(basename "$path")"
        lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

        if [[ -f "$path" ]]; then
            if is_strict_junk_sidecar "$path"; then
                queue_quarantine "$path"
                continue
            fi

            if is_hidden_system_junk "$path"; then
                queue_quarantine "$path"
                continue
            fi

            if is_extension_blacklisted "$base" "$lower"; then
                queue_quarantine "$path"
            fi

            continue
        fi

        if [[ -d "$path" ]] && is_hidden_system_junk "$path"; then
            queue_quarantine "$path"
        fi
    done
}

# ==============================
# RENAME ITEMS
# ==============================

rename_items() {

    clear_queues
    build_rename_items_queue
    confirm_and_execute
}

build_rename_items_queue() {

    mapfile -t ITEMS < <(
        find "$MEDIA_ROOT" \( -type f -o -type d \) \
            ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR" \
            ! -path "$TAGSTRIPPER_DIR/*" \
            ! -name "._*" \
            ! -iname "*.txt" \
            ! -iname "*.jpg" \
            ! -iname "*.jpeg" \
            ! -iname "*.png" \
            ! -iname "*.nfo"
    )

    for item in "${ITEMS[@]}"; do
        if ! is_rename_candidate_type "$item"; then
            continue
        fi

        oldname="$(basename "$item")"
        dir="$(dirname "$item")"

        if ! has_tracker_noise "$oldname"; then
            continue
        fi

        newname="$(sanitize_name "$oldname")"

        if [[ -z "$newname" ]]; then
            continue
        fi

        if [[ "$oldname" == "$newname" ]]; then
            continue
        fi

        target="$dir/$newname"

        queue_rename "$item" "$target"

    done
}

# ==============================
# DETECT NESTED MOVIE FOLDERS
# ==============================

detect_nested_movie_folders() {

    clear_queues
    build_nested_movie_folders_queue
    confirm_and_execute
}

build_nested_movie_folders_queue() {
    local candidates=()
    local destinations=()

    build_nested_movie_folders_candidates candidates destinations

    if [ ${#candidates[@]} -eq 0 ]; then
        echo ""
        echo "No nested movie folders found."
        return
    fi

    select_nested_movie_folders candidates destinations
}

build_nested_movie_folders_candidates() {
    local -n out_candidates="$1"
    local -n out_destinations="$2"
    local folder
    local parent
    local grandparent
    local target

    echo ""
    echo "Scanning for movie folders nested inside other movie folders..."

    while IFS= read -r folder; do
        is_in_junk "$folder" && continue
        is_legitimate_nested_subfolder "$folder" && continue

        parent="$(dirname "$folder")"
        grandparent="$(dirname "$parent")"

        [[ "$parent" == "$MEDIA_ROOT" ]] && continue
        [[ "$grandparent" == "$MEDIA_ROOT" || "$grandparent" == "$MEDIA_ROOT"/* ]] || continue

        contains_video_file "$folder" || continue
        contains_video_file "$parent" || continue

        target="$grandparent/$(basename "$folder")"

        out_candidates+=("$folder")
        out_destinations+=("$target")
    done < <(
        find "$MEDIA_ROOT" -mindepth 2 -type d \
            ! -path "$JUNK_DIR" \
            ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR" \
            ! -path "$TAGSTRIPPER_DIR/*" \
            | sort
    )
}

select_nested_movie_folders() {
    local -n candidates="$1"
    local -n destinations="$2"
    local selection
    local token
    local start
    local end
    local index
    local i
    local selected=()

    echo ""
    echo "Nested movie folder candidates:"
    echo "--------------------------------------"

    for i in "${!candidates[@]}"; do
        printf '%3d. %s\n' "$((i + 1))" "${candidates[$i]}"
        printf '     -> %s\n' "${destinations[$i]}"
    done

    echo ""
    read -rp "Select folders to move up one branch (all/none/1,3,5-7): " selection

    selection="$(printf '%s\n' "$selection" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

    if [[ -z "$selection" || "$selection" == "none" || "$selection" == "n" ]]; then
        echo "No nested folders selected."
        return
    fi

    if [[ "$selection" == "all" || "$selection" == "a" ]]; then
        for i in "${!candidates[@]}"; do
            selected[$i]=1
        done
    else
        IFS=',' read -ra tokens <<< "$selection"

        for token in "${tokens[@]}"; do
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                index=$((token - 1))

                if [[ "$index" -ge 0 && "$index" -lt "${#candidates[@]}" ]]; then
                    selected[$index]=1
                else
                    echo "Ignoring out-of-range selection: $token"
                fi
            elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
                start="${token%-*}"
                end="${token#*-}"

                if [[ "$start" -gt "$end" ]]; then
                    echo "Ignoring invalid range: $token"
                    continue
                fi

                for ((index = start - 1; index <= end - 1; index++)); do
                    if [[ "$index" -ge 0 && "$index" -lt "${#candidates[@]}" ]]; then
                        selected[$index]=1
                    fi
                done
            else
                echo "Ignoring invalid selection: $token"
            fi
        done
    fi

    for i in "${!selected[@]}"; do
        [[ "${selected[$i]:-}" == "1" ]] || continue
        queue_rename "${candidates[$i]}" "${destinations[$i]}"
    done
}

# ==============================
# FULL CLEANUP
# ==============================

full_cleanup() {

    clear_queues

    build_mac_hidden_files_queue
    build_sample_videos_queue
    build_junk_folders_queue
    build_junk_queue
    build_rename_items_queue

    confirm_and_execute

}

# ==============================
# MENU
# ==============================

show_menu() {

    clear 2>/dev/null || true

    echo "======================================"
    echo "    MEDIA CLEANUP TOOL v8 REVERSIBLE"
    echo "======================================"
    echo ""
    echo "Media Root:"
    echo "  $MEDIA_ROOT"
    echo ""
    echo "Every operation uses:"
    echo "  DRY RUN -> CONFIRM -> EXECUTE"
    echo "Removal means quarantine to:"
    echo "  $JUNK_DIR"
    echo ""
    echo "1. Clean Mac hidden files"
    echo "2. Clean sample videos"
    echo "3. Clean junk folders"
    echo "4. Clean junk files"
    echo "5. Rename files/folders"
    echo "6. Detect nested movie folders"
    echo "7. Full cleanup"
    echo "8. Exit"
    echo ""
}

load_junk_suffix_blacklist

while true; do

    show_menu

    read -rp "Choose option [1-8]: " choice

    case "$choice" in
        1)
            clean_mac_hidden_files
            ;;
        2)
            clean_sample_videos
            ;;
        3)
            clean_junk_folders
            ;;
        4)
            clean_junk
            ;;
        5)
            rename_items
            ;;
        6)
            detect_nested_movie_folders
            ;;
        7)
            full_cleanup
            ;;
        8)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option."
            ;;
    esac

    echo ""
    read -rp "Press Enter to continue..."

done
