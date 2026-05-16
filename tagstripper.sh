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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 0 ]]; then
    MEDIA_ROOT="$1"
elif [[ "$(basename "$SCRIPT_DIR")" == "TagStripper" ]]; then
    MEDIA_ROOT="$(dirname "$SCRIPT_DIR")"
else
    MEDIA_ROOT="$PWD"
fi

if [ ! -d "$MEDIA_ROOT" ]; then
    echo "Error: Media root directory '$MEDIA_ROOT' does not exist."
    exit 1
fi

MEDIA_ROOT="$(cd "$MEDIA_ROOT" && pwd)"
JUNK_DIR="$MEDIA_ROOT/junk"
TAGSTRIPPER_DIR="$MEDIA_ROOT/TagStripper"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
SCAN_MAX_DEPTH="${SCAN_MAX_DEPTH:-8}"
PREVIEW_LIMIT="${PREVIEW_LIMIT:-200}"

BLACKLIST_FILE="${BLACKLIST_FILE:-$SCRIPT_DIR/filetype-blacklist.txt}"
TRACKER_TAG_FILE="${TRACKER_TAG_FILE:-$SCRIPT_DIR/tracker-tag-blacklist.txt}"

declare -a JUNK_SUFFIX_BLACKLIST=()
declare -A JUNK_SUFFIX_BLACKLIST_SET=()
declare -a TRACKER_TAGS=()
TRACKER_TAG_REGEX=""
JUNK_PREPARED=0

# ==============================
# GLOBAL OPERATION QUEUES
# ==============================

declare -a QUARANTINE_SRC_QUEUE=()
declare -a QUARANTINE_DST_QUEUE=()
declare -a QUARANTINE_DIR_SRC_QUEUE=()
declare -a RENAME_SRC_QUEUE=()
declare -a RENAME_DST_QUEUE=()
declare -A RESERVED_DESTINATION_SET=()

# ==============================
# HELPERS
# ==============================

build_tracker_tag_regex() {
    if [ ${#TRACKER_TAGS[@]} -eq 0 ]; then
        TRACKER_TAG_REGEX=""
        return
    fi

    TRACKER_TAG_REGEX="$(
        printf '%s\n' "${TRACKER_TAGS[@]}" | perl -ne '
            chomp;
            next unless length;
            $seen{lc($_)}++ and next;
            push @tags, quotemeta($_);
            END {
                print join "|", sort { length($b) <=> length($a) || lc($a) cmp lc($b) } @tags;
            }
        '
    )"
}

load_tracker_tags() {
    local line
    local key
    declare -A seen=()

    TRACKER_TAGS=()

    if [[ ! -f "$TRACKER_TAG_FILE" ]]; then
        printf '%s\n' "Warning: tracker tag blacklist not found: $TRACKER_TAG_FILE" >&2
        TRACKER_TAG_REGEX=""
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

        key="$(printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]')"
        [[ -n "${seen[$key]:-}" ]] && continue

        seen[$key]=1
        TRACKER_TAGS+=("$line")
    done <"$TRACKER_TAG_FILE"

    build_tracker_tag_regex
}

save_tracker_tags() {
    {
        echo "# Tracker/release tags removed from file and folder names."
        echo "# One tag per line. Blank lines and comments are ignored."
        printf '%s\n' "${TRACKER_TAGS[@]}" | sort -f
    } >"$TRACKER_TAG_FILE"
}

valid_tracker_tag() {
    local tag="$1"

    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]
}

sanitize_name() {
    local name="$1"

    printf '%s\n' "$name" | TRACKER_TAG_REGEX="$TRACKER_TAG_REGEX" perl -CSD -pe '
        BEGIN {
            $tracker_re = $ENV{TRACKER_TAG_REGEX} // "";
        }
        # UIndex spam prefix: strip leading www.UIndex.org plus any following separators (spaces, dashes, punctuation).
        # Handles en/em-dashes, NBSP, multiple spaces, etc. common in torrent folder names.
        s/^(?:https?:\/\/)?(?iu)www\.uindex\.org[\s\p{Pd}\p{P}._-]*//;
        if (length $tracker_re) {
            s/[[:space:]._-]*\[($tracker_re)\]//gi;
            s/(^|[[:space:]._-]+)($tracker_re)(?=([[:space:]._-]|$))//gi;
        }
        s/[[:space:]]*\([[:space:]]*FIRST[[:space:]]+TRY[[:space:]]*\)//gi;
        if (/[[:space:]._-]bone\.[^.]+\z/i) {
            s/([[:space:]._-])bone(\.[^.]+)\z/$2/gi;
        } elsif (/[[:space:]._-]bone\z/i) {
            s/[[:space:]._-]bone\z//gi;
        }
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

    printf '%s\n' "$name" | TRACKER_TAG_REGEX="$TRACKER_TAG_REGEX" perl -CSD -ne '
        BEGIN {
            $tracker_re = $ENV{TRACKER_TAG_REGEX} // "";
        }
        exit 0 if /^(?iu)(?:https?:\/\/)?www\.uindex\.org/;
        exit 0 if /\([[:space:]]*FIRST[[:space:]]+TRY[[:space:]]*\)/i;
        exit 0 if /[[:space:]._-]bone(?:\.[^.]+)?\z/i;
        exit 0 if length($tracker_re) && /(^|[[:space:]._-])\[($tracker_re)\]/i;
        exit 0 if length($tracker_re) && /(^|[[:space:]._-]+)($tracker_re)([[:space:]._-]|$)/i;
        exit 1;
    '
}

is_rename_candidate_type() {
    local item="$1"
    local base
    local lower

    base="${item##*/}"
    [[ "$base" == ._* ]] && return 1

    [[ -d "$item" ]] && return 0

    lower="${item,,}"
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

    base="${file##*/}"
    lower="${base,,}"

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
    esac

    return 1
}

is_automated_library_nfo() {
    local base="$1"
    local lower="${base,,}"

    case "$lower" in
        movie.nfo|tvshow.nfo|season.nfo|album.nfo|artist.nfo|video_ts.nfo)
            return 0
            ;;
    esac

    return 1
}

is_video_or_audio_extension() {
    local lower="$1"

    case "$lower" in
        *.mkv|*.mp4|*.avi|*.mov|*.m4v|*.wmv|*.webm|*.flv|*.ts|*.vob|*.m2ts|*.mpg|*.mpeg|*.ogv|*.3gp|*.3g2|*.f4v|*.divx|*.xvid)
            return 0
            ;;
        *.mp3|*.m4a|*.wav|*.wma|*.aif|*.aiff|*.mpa|*.mid|*.midi|*.aac|*.opus|*.flac|*.ogg|*.oga|*.alac|*.ape|*.dsf|*.dff)
            return 0
            ;;
    esac

    return 1
}

is_companion_nfo_for_media() {
    local file="$1"
    local dir
    local base
    local stem
    local item
    local item_base
    local item_lower
    local item_stem

    base="${file##*/}"
    [[ "${base,,}" == *.nfo ]] || return 1

    stem="${base%.*}"
    dir="${file%/*}"

    for item in "$dir"/*; do
        [[ -f "$item" ]] || continue

        item_base="${item##*/}"
        item_lower="${item_base,,}"
        is_video_or_audio_extension "$item_lower" || continue

        item_stem="${item_base%.*}"
        [[ "$item_stem" == "$stem" ]] && return 0
    done

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
            [[ "$suffix" == ".nfo" ]] && continue

            raw+=("$suffix")
        done <"$BLACKLIST_FILE"
    else
        printf '%s\n' "Warning: blacklist file not found: $BLACKLIST_FILE" >&2
    fi

    local -a extras=(
        .txt .xml .json .pdf .log .md .readme .html .htm .csv
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

    JUNK_SUFFIX_BLACKLIST_SET=()

    for suffix in "${JUNK_SUFFIX_BLACKLIST[@]}"; do
        JUNK_SUFFIX_BLACKLIST_SET["$suffix"]=1
    done
}

is_hidden_system_junk() {
    local path="$1"
    local base
    local lower

    base="${path##*/}"
    lower="${base,,}"

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

    base="${path##*/}"
    lower="${base,,}"

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
    local rest
    local suffix

    [[ -z "$lower" ]] && lower="$(printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]')"

    rest="$lower"

    while [[ "$rest" == *.* ]]; do
        suffix=".${rest#*.}"

        if [[ -n "${JUNK_SUFFIX_BLACKLIST_SET[$suffix]:-}" ]]; then
            return 0
        fi

        rest="${rest#*.}"
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

    [[ "$path" == "$TAGSTRIPPER_DIR" || "$path" == "$TAGSTRIPPER_DIR"/* || "$path" == "$SCRIPT_DIR" || "$path" == "$SCRIPT_DIR"/* ]]
}

queued_operation_count() {
    printf '%s\n' "$((${#QUARANTINE_SRC_QUEUE[@]} + ${#RENAME_SRC_QUEUE[@]}))"
}

report_queue_delta() {
    local label="$1"
    local before="$2"
    local after
    local delta

    after="$(queued_operation_count)"
    delta=$((after - before))

    if [ "$delta" -eq 0 ]; then
        echo "No matching $label found outside junk/."
    else
        echo "Queued $delta $label operation(s)."
    fi
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
        printf '%s\n' "${path##*/}"
    fi
}

destination_reserved() {
    local candidate="$1"

    [[ -n "${RESERVED_DESTINATION_SET[$candidate]:-}" ]]
}

destination_exists() {
    local candidate="$1"
    local parent

    parent="${candidate%/*}"

    [[ "$parent" != "$candidate" && -d "$parent" && -e "$candidate" ]]
}

rebuild_reserved_destinations() {
    local dst

    RESERVED_DESTINATION_SET=()

    for dst in "${QUARANTINE_DST_QUEUE[@]}"; do
        RESERVED_DESTINATION_SET["$dst"]=1
    done

    for dst in "${RENAME_DST_QUEUE[@]}"; do
        RESERVED_DESTINATION_SET["$dst"]=1
    done
}

unique_destination() {
    local candidate="$1"
    local suffix="$2"
    local unique="$candidate"
    local counter=1

    while destination_exists "$unique" || destination_reserved "$unique"; do
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

    for src in "${QUARANTINE_DIR_SRC_QUEUE[@]}"; do
        if [[ "$path" == "$src"/* ]]; then
            return 0
        fi
    done

    return 1
}

remove_queued_children_of() {
    local parent="$1"
    local new_src=()
    local new_dst=()
    local new_dirs=()
    local i

    for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
        if [[ "${QUARANTINE_SRC_QUEUE[$i]}" == "$parent"/* ]]; then
            continue
        fi

        new_src+=("${QUARANTINE_SRC_QUEUE[$i]}")
        new_dst+=("${QUARANTINE_DST_QUEUE[$i]}")

        if [[ -d "${QUARANTINE_SRC_QUEUE[$i]}" ]]; then
            new_dirs+=("${QUARANTINE_SRC_QUEUE[$i]}")
        fi
    done

    QUARANTINE_SRC_QUEUE=("${new_src[@]}")
    QUARANTINE_DST_QUEUE=("${new_dst[@]}")
    QUARANTINE_DIR_SRC_QUEUE=("${new_dirs[@]}")
    rebuild_reserved_destinations
}

queue_quarantine() {
    local src="$1"
    local dst

    is_in_junk "$src" && return
    is_in_tagstripper "$src" && return
    is_under_queued_quarantine_dir "$src" && return

    if [[ -d "$src" ]]; then
        remove_queued_children_of "$src"
        QUARANTINE_DIR_SRC_QUEUE+=("$src")
    fi

    dst="$(quarantine_destination_for "$src")"

    QUARANTINE_SRC_QUEUE+=("$src")
    QUARANTINE_DST_QUEUE+=("$dst")
    RESERVED_DESTINATION_SET["$dst"]=1
}

queue_rename() {
    local src="$1"
    local dst="$2"
    local unique_dst
    local q

    for q in "${RENAME_SRC_QUEUE[@]}"; do
        [[ "$q" == "$src" ]] && return
    done

    is_in_junk "$src" && return
    is_in_tagstripper "$src" && return
    is_under_queued_quarantine_dir "$src" && return

    unique_dst="$(unique_destination "$dst" "duplicate")"

    RENAME_SRC_QUEUE+=("$src")
    RENAME_DST_QUEUE+=("$unique_dst")
    RESERVED_DESTINATION_SET["$unique_dst"]=1
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
        IFS=$'\t' read -r _ idx _ <<< "$entry"
        idx=$((10#$idx))
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
        IFS=$'\t' read -r _ _ idx _ <<< "$entry"
        idx=$((10#$idx))
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
    QUARANTINE_DIR_SRC_QUEUE=()
    RENAME_SRC_QUEUE=()
    RENAME_DST_QUEUE=()
    RESERVED_DESTINATION_SET=()
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
    local shown=0
    local omitted=0

    if [ ${#QUARANTINE_SRC_QUEUE[@]} -gt 0 ]; then
        echo "FILES/FOLDERS TO QUARANTINE:"
        echo "--------------------------------------"

        for i in "${!QUARANTINE_SRC_QUEUE[@]}"; do
            ((total+=1))

            if ((PREVIEW_LIMIT == 0 || shown < PREVIEW_LIMIT)); then
                echo "QUARANTINE:"
                echo "  FROM: ${QUARANTINE_SRC_QUEUE[$i]}"
                echo "  TO:   ${QUARANTINE_DST_QUEUE[$i]}"

                if [ -d "${QUARANTINE_SRC_QUEUE[$i]}" ]; then
                    preview_folder_contents "${QUARANTINE_SRC_QUEUE[$i]}"
                fi

                echo ""
                ((shown+=1))
            else
                ((omitted+=1))
            fi
        done
    fi

    if [ ${#RENAME_SRC_QUEUE[@]} -gt 0 ]; then
        echo "ITEMS TO RENAME:"
        echo "--------------------------------------"

        for i in "${!RENAME_SRC_QUEUE[@]}"; do
            ((total+=1))

            if ((PREVIEW_LIMIT == 0 || shown < PREVIEW_LIMIT)); then
                echo "RENAME:"
                echo "  OLD: ${RENAME_SRC_QUEUE[$i]}"
                echo "  NEW: ${RENAME_DST_QUEUE[$i]}"
                echo ""
                ((shown+=1))
            else
                ((omitted+=1))
            fi
        done
    fi

    if [ "$total" -eq 0 ]; then
        echo "No operations queued."
        return 1
    fi

    if [ "$omitted" -gt 0 ]; then
        echo "... $omitted more operation(s) not shown."
        echo "Set PREVIEW_LIMIT=0 to show every operation."
        echo ""
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
    local before
    local file
    local scanned=0

    echo ""
    echo "Scanning for hidden files..."

    before="$(queued_operation_count)"

    while IFS= read -r file; do
        ((scanned+=1))
        if ((scanned % 1000 == 0)); then
            echo "  Queued $scanned hidden file candidate(s)..."
        fi

        queue_quarantine "$file"
    done < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            -type f \
            -name ".*" \
            -print
    )

    report_queue_delta "hidden file" "$before"
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
    local before

    echo ""
    echo "Scanning for sample/proof videos..."

    before="$(queued_operation_count)"

    mapfile -t SAMPLES < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            -type f \
            \( -iname "*sample*" -o -iname "*proof*" -o -iname "rarbg.*" \) \
            \( -iname "*.avi" -o -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.webm" \) \
            -print
    )

    for file in "${SAMPLES[@]}"; do
        queue_quarantine "$file"
    done

    report_queue_delta "sample/proof video" "$before"
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
    local before

    echo ""
    echo "Scanning for junk folders..."

    before="$(queued_operation_count)"

    mapfile -t FOLDERS < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            -type d \
            \( -iname "Screens" -o -iname "Screenshots" -o -iname "Proof" -o -iname "Sample" -o -iname "Other" \) \
            -print
    )

    for folder in "${FOLDERS[@]}"; do
        queue_quarantine "$folder"
    done

    report_queue_delta "junk folder" "$before"
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
    local before
    local scanned=0

    echo ""
    echo "Scanning for junk files..."

    before="$(queued_operation_count)"

    while IFS= read -r path; do
        ((scanned+=1))
        if ((scanned % 1000 == 0)); then
            echo "  Scanned $scanned junk candidate path(s)..."
        fi

        base="${path##*/}"
        lower="${base,,}"

        if [[ -f "$path" ]]; then
            [[ "$lower" == *.nfo ]] && continue

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
    done < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -print -prune \) -o \
            \( -type f -o -type d \) \
            -print
    )

    report_queue_delta "junk file/folder" "$before"
}

# ==============================
# CLEAN .NFO FILES (standalone)
# ==============================

build_nfo_queue() {
    local mode="$1"
    local before
    local path
    local base
    local scanned=0

    echo ""

    case "$mode" in
        all)
            echo "Scanning for all .nfo files..."
            ;;
        automated)
            echo "Scanning for library-style .nfo (movie.nfo, tvshow.nfo, season.nfo, album.nfo, artist.nfo, VIDEO_TS.nfo)..."
            ;;
        companion)
            echo "Scanning for companion .nfo (same stem as a video/audio file in the same folder)..."
            ;;
        *)
            echo "Error: unknown NFO mode."
            return
            ;;
    esac

    before="$(queued_operation_count)"

    while IFS= read -r path; do
        ((scanned+=1))
        if ((scanned % 500 == 0)); then
            echo "  Scanned $scanned .nfo path(s)..."
        fi

        base="${path##*/}"

        case "$mode" in
            all)
                queue_quarantine "$path"
                ;;
            automated)
                if is_automated_library_nfo "$base"; then
                    queue_quarantine "$path"
                fi
                ;;
            companion)
                if is_companion_nfo_for_media "$path"; then
                    queue_quarantine "$path"
                fi
                ;;
        esac
    done < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            -type f \
            \( -iname "*.nfo" -o -name ".nfo" \) \
            -print
    )

    report_queue_delta ".nfo file" "$before"
}

clean_nfo_menu() {
    local sub

    while true; do
        echo ""
        echo "======================================"
        echo "           CLEAN .NFO FILES"
        echo "======================================"
        echo ""
        echo "Moves selected .nfo files into:"
        echo "  $JUNK_DIR"
        echo ""
        echo "1. All .nfo files"
        echo "2. Library-style only (movie.nfo, tvshow.nfo, season.nfo, album.nfo, artist.nfo, VIDEO_TS.nfo)"
        echo "3. Companion only (same stem as video/audio in same folder)"
        echo "4. Back to main menu"
        echo ""

        read -rp "Choose option [1-4]: " sub

        case "$sub" in
            1)
                clear_queues
                build_nfo_queue all
                confirm_and_execute
                return
                ;;
            2)
                clear_queues
                build_nfo_queue automated
                confirm_and_execute
                return
                ;;
            3)
                clear_queues
                build_nfo_queue companion
                confirm_and_execute
                return
                ;;
            4)
                return
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
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
    local before
    local item
    local oldname
    local dir
    local newname
    local scanned=0
    local ancestor
    local abase
    local anew
    local aparent

    echo ""
    echo "Scanning for rename candidates..."

    before="$(queued_operation_count)"

    while IFS= read -r item; do
        ((scanned+=1))
        if ((scanned % 1000 == 0)); then
            echo "  Scanned $scanned rename candidate path(s)..."
        fi

        if ! is_rename_candidate_type "$item"; then
            continue
        fi

        oldname="${item##*/}"
        dir="${item%/*}"

        if has_tracker_noise "$oldname"; then
            newname="$(sanitize_name "$oldname")"

            if [[ -n "$newname" && "$oldname" != "$newname" ]]; then
                queue_rename "$item" "$dir/$newname"
            fi
        fi

        # Also clean spam release-folder names (e.g. www.UIndex.org - …) even when only the
        # child file name needed sanitization, or find order skipped the directory entry.
        ancestor="$dir"
        while [[ -n "$ancestor" && "$ancestor" != "$MEDIA_ROOT" ]]; do
            case "$ancestor" in
                "$MEDIA_ROOT"/*) ;;
                *) break ;;
            esac
            [[ -d "$ancestor" ]] || break

            abase="${ancestor##*/}"
            if has_tracker_noise "$abase"; then
                anew="$(sanitize_name "$abase")"
                if [[ -n "$anew" && "$abase" != "$anew" ]]; then
                    aparent="${ancestor%/*}"
                    queue_rename "$ancestor" "$aparent/$anew"
                fi
            fi
            ancestor="${ancestor%/*}"
        done
    done < <(
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            \( -type f -o -type d \) \
            ! -name "._*" \
            ! -iname "*.txt" \
            ! -iname "*.jpg" \
            ! -iname "*.jpeg" \
            ! -iname "*.png" \
            ! -iname "*.nfo" \
            -print
    )

    report_queue_delta "rename candidate" "$before"
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
        find "$MEDIA_ROOT" -maxdepth "$SCAN_MAX_DEPTH" \
            \( -path "$JUNK_DIR" -o -path "$TAGSTRIPPER_DIR" -o -path "$SCRIPT_DIR" \) -prune -o \
            \( -type d \( -name ".*" -o -iname "__MACOSX" -o -iname "@eaDir" -o -iname '$RECYCLE.BIN' -o -iname "System Volume Information" \) -prune \) -o \
            -mindepth 2 -type d \
            -print \
            | sort
    )
}

select_nested_movie_folders() {
    local -n _candidates="$1"
    local -n _destinations="$2"
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

    for i in "${!_candidates[@]}"; do
        printf '%3d. %s\n' "$((i + 1))" "${_candidates[$i]}"
        printf '     -> %s\n' "${_destinations[$i]}"
    done

    echo ""
    read -rp "Select folders to move up one branch (all/none/1,3,5-7): " selection

    selection="$(printf '%s\n' "$selection" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

    if [[ -z "$selection" || "$selection" == "none" || "$selection" == "n" ]]; then
        echo "No nested folders selected."
        return
    fi

    if [[ "$selection" == "all" || "$selection" == "a" ]]; then
        for i in "${!_candidates[@]}"; do
            selected[$i]=1
        done
    else
        IFS=',' read -ra tokens <<< "$selection"

        for token in "${tokens[@]}"; do
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                index=$((token - 1))

                if [[ "$index" -ge 0 && "$index" -lt "${#_candidates[@]}" ]]; then
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
                    if [[ "$index" -ge 0 && "$index" -lt "${#_candidates[@]}" ]]; then
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
        queue_rename "${_candidates[$i]}" "${_destinations[$i]}"
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
# MANAGE TRACKER TAGS
# ==============================

show_tracker_tags() {
    local i

    echo ""
    echo "Tracker/release tags:"
    echo "--------------------------------------"

    if [ ${#TRACKER_TAGS[@]} -eq 0 ]; then
        echo "  (none configured)"
        return
    fi

    for i in "${!TRACKER_TAGS[@]}"; do
        printf '%3d. %s\n' "$((i + 1))" "${TRACKER_TAGS[$i]}"
    done
}

tracker_tag_exists() {
    local needle="$1"
    local needle_key
    local tag
    local tag_key

    needle_key="$(printf '%s\n' "$needle" | tr '[:upper:]' '[:lower:]')"

    for tag in "${TRACKER_TAGS[@]}"; do
        tag_key="$(printf '%s\n' "$tag" | tr '[:upper:]' '[:lower:]')"
        [[ "$tag_key" == "$needle_key" ]] && return 0
    done

    return 1
}

add_tracker_tags() {
    local input
    local tag
    local added=0

    echo ""
    read -rp "Enter tag(s) to add, separated by spaces or commas: " input
    input="${input//,/ }"

    for tag in $input; do
        if ! valid_tracker_tag "$tag"; then
            echo "Skipping invalid tag: $tag"
            continue
        fi

        if tracker_tag_exists "$tag"; then
            echo "Already exists: $tag"
            continue
        fi

        TRACKER_TAGS+=("$tag")
        ((added+=1))
        echo "Added: $tag"
    done

    if [ "$added" -gt 0 ]; then
        save_tracker_tags
        load_tracker_tags
        echo "Saved $added new tag(s)."
    else
        echo "No tags added."
    fi
}

remove_tracker_tag() {
    local input
    local remove_index=-1
    local tag
    local tag_key
    local input_key
    local i
    local next_tags=()

    show_tracker_tags

    if [ ${#TRACKER_TAGS[@]} -eq 0 ]; then
        return
    fi

    echo ""
    read -rp "Enter tag name or number to remove: " input
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"

    if [[ -z "$input" ]]; then
        echo "No tag removed."
        return
    fi

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        remove_index=$((input - 1))
    else
        input_key="$(printf '%s\n' "$input" | tr '[:upper:]' '[:lower:]')"

        for i in "${!TRACKER_TAGS[@]}"; do
            tag_key="$(printf '%s\n' "${TRACKER_TAGS[$i]}" | tr '[:upper:]' '[:lower:]')"
            if [[ "$tag_key" == "$input_key" ]]; then
                remove_index="$i"
                break
            fi
        done
    fi

    if [[ "$remove_index" -lt 0 || "$remove_index" -ge "${#TRACKER_TAGS[@]}" ]]; then
        echo "Tag not found: $input"
        return
    fi

    tag="${TRACKER_TAGS[$remove_index]}"

    for i in "${!TRACKER_TAGS[@]}"; do
        [[ "$i" -eq "$remove_index" ]] && continue
        next_tags+=("${TRACKER_TAGS[$i]}")
    done

    TRACKER_TAGS=("${next_tags[@]}")
    save_tracker_tags
    load_tracker_tags

    echo "Removed: $tag"
}

manage_tracker_tags() {
    local choice

    while true; do
        echo ""
        echo "======================================"
        echo "      TRACKER/RELEASE TAG MANAGER"
        echo "======================================"
        echo ""
        echo "Tag file:"
        echo "  $TRACKER_TAG_FILE"
        echo ""
        echo "1. List tags"
        echo "2. Add tag(s)"
        echo "3. Remove tag"
        echo "4. Return to main menu"
        echo ""

        read -rp "Choose option [1-4]: " choice

        case "$choice" in
            1)
                show_tracker_tags
                ;;
            2)
                add_tracker_tags
                ;;
            3)
                remove_tracker_tag
                ;;
            4)
                return
                ;;
            *)
                echo "Invalid option."
                ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
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
    echo "1. Clean hidden files"
    echo "2. Clean sample videos"
    echo "3. Clean junk folders"
    echo "4. Clean junk files (does not touch .nfo — use item 5)"
    echo "5. Clean .nfo files..."
    echo "6. Rename files/folders"
    echo "7. Detect nested movie folders"
    echo "8. Full cleanup"
    echo "9. Manage tracker/release tags"
    echo "10. Exit"
    echo ""
}

load_junk_suffix_blacklist
load_tracker_tags

while true; do

    show_menu

    read -rp "Choose option [1-10]: " choice

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
            clean_nfo_menu
            ;;
        6)
            rename_items
            ;;
        7)
            detect_nested_movie_folders
            ;;
        8)
            full_cleanup
            ;;
        9)
            manage_tracker_tags
            ;;
        10)
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
