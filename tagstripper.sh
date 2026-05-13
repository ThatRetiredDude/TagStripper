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

MEDIA_ROOT="${1:-$PWD}"

if [ ! -d "$MEDIA_ROOT" ]; then
    echo "Error: Media root directory '$MEDIA_ROOT' does not exist."
    exit 1
fi

MEDIA_ROOT="$(cd "$MEDIA_ROOT" && pwd)"
JUNK_DIR="$MEDIA_ROOT/junk"
TAGSTRIPPER_DIR="$MEDIA_ROOT/TagStripper"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

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
        *.mkv|*.mp4|*.avi|*.mov|*.m4v|*.wmv|*.srt|*.ass|*.ssa|*.sub)
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

    mapfile -t FILES < <(
        find "$MEDIA_ROOT" -type f \
            ! -path "$JUNK_DIR/*" \
            ! -path "$TAGSTRIPPER_DIR/*" \
            ! -iname "movie.nfo" \
            ! -iname "season.nfo" \
            ! -iname "tvshow.nfo"
    )

    for file in "${FILES[@]}"; do
        if is_strict_junk_sidecar "$file"; then
            queue_quarantine "$file"
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
