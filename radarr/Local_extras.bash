#!/usr/bin/env bash

# This is ran as a stand-alone untill I add it into the extended scripts logic
# Radarr > Settings > Connect > Add > Custom Script
# Enable: On Import, On Upgrade.
# Put the path and filename of the script, I just place this in extended for now
# Settings must be set in this file below
# ==================================================================
# Radarr Extras Importer (local files)
#
#  • Ignores samples
#  • Recursively scans source folder + subfolders
#  • Forgiving folder detection (keyword‑based)
#  • Detection can be strict or forgiving
#  • Dry‑run mode via DRY_RUN=true
# ==================================================================
# Manual mode example:
#
# radarr_moviefile_sourcefolder="/downloads/Movie.Extras" \
# radarr_moviefile_sourcepath="/downloads/Movie.Extras/dummy.mkv" \
# radarr_moviefile_path="/movies/Movie (2024)/DUMMY.mkv" \
# radarr_movie_path="/movies/Movie (2024)" \
# DRY_RUN=false \
# ./extras_script.sh
# ==================================================================
# v1.0.0

# ========================= USER SETTINGS ===========================

ENABLE_LOGGING=true
ENABLE_DEBUG=true
LOG_FILE="/config/logs/local_extras.txt"

DRY_RUN="${DRY_RUN:-false}"
INLINE_STRICT="${INLINE_STRICT:-false}"

RENAME_MODE="plex"
STORAGE_MODE="inline"
UNKNOWN_MODE="generous"

ENABLE_TRAILERS=true
ENABLE_BEHIND_SCENES=true
ENABLE_FEATURETTES=true
ENABLE_INTERVIEWS=true
ENABLE_DELETED=true
ENABLE_SCENES=true
ENABLE_SHORTS=true
ENABLE_OTHER=true

# Optional ignore list for folders that should never be treated as extras
IGNORE_FOLDERS=("subs" "subtitles" "bdmv" "certificate" "audio" "video_ts" "sample")


# ========================= INTERNAL DATA ===========================

VIDEO_EXTENSIONS="mkv mp4 mov avi m4v webm mpg mpeg ts m2ts flv f4v 3gp 3g2 wmv asf"

declare -A FOLDER_KEYWORDS=(
    ["trailer"]="trailer"
    ["behind"]="behind the scenes bts behind"
    ["featurette"]="featurette featurettes"
    ["interview"]="interview interviews"
    ["deleted"]="deleted delete"
    ["scene"]="scene scenes"
    ["short"]="short shorts"
    ["extra"]="extra extras bonus"
    ["other"]="other misc"
)

INLINE_SUFFIXES=(
    "-behindthescenes" "-deleted" "-featurette" "-interview"
    "-scene" "-trailer" "-other" "-short"
)

FOUND_ANY=false


# ========================= HELPER FUNCTIONS ========================

log() {
    local level="Standard"
    [[ "$ENABLE_DEBUG" == true ]] && level="Debug"
    [[ "$ENABLE_LOGGING" == true ]] && {
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $level - $1" | tee -a "$LOG_FILE"
    }
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_sample() { [[ "$(lower "$1")" == *sample* ]]; }

is_video() {
    local f=$(lower "$1")
    for ext in $VIDEO_EXTENSIONS; do
        [[ "$f" == *.$ext ]] && return 0
    done
    return 1
}

folder_is_ignored() {
    local name=$(lower "$1")
    for ig in "${IGNORE_FOLDERS[@]}"; do
        [[ "$name" == *"$ig"* ]] && return 0
    done
    return 1
}

get_suffix() {
    local type=$1 suffix=
    case "$RENAME_MODE" in
        plex)
            case "$type" in
                trailer)        suffix="-trailer" ;;
                behind)         suffix="-behindthescenes" ;;
                featurette)     suffix="-featurette" ;;
                interview)      suffix="-interview" ;;
                deleted)        suffix="-deleted" ;;
                scene)          suffix="-scene" ;;
                short)          suffix="-short" ;;
                extra|other)    suffix="-other" ;;
            esac
            ;;
        jellyfin|kodi) suffix="-$type" ;;
        none) suffix="" ;;
    esac
    printf '%s' "$suffix"
}

get_next_filename() {
    local dir=$1 base=$2 suffix=$3 ext=$4 count=1 candidate
    candidate="${base}${suffix}.${ext}"
    while [[ -e "$dir/$candidate" ]]; do
        ((count++))
        candidate="${base}${count}${suffix}.${ext}"
    done
    printf '%s' "$candidate"
}

safe_copy() {
    local src=$1 dest=$2
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN – Would copy: $src → $dest"
        return 0
    fi
    cp -f "$src" "$dest" || { log "ERROR – copy failed: $src"; exit 1; }
}

copy_item() {
    local src=$1 type=$2
    local filename ext base suffix new target_dir

    filename=$(basename "$src")
    ext="${filename##*.}"
    base="${filename%.*}"
    suffix=$(get_suffix "$type")

    target_dir="$TARGET_DIR"
    [[ "$STORAGE_MODE" == "folders" ]] && target_dir="${TARGET_DIR}/${type^}"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN – Would ensure directory exists: $target_dir"
    else
        mkdir -p "$target_dir" || { log "ERROR – cannot create $target_dir"; exit 1; }
    fi

    new=$(get_next_filename "$target_dir" "$base" "$suffix" "$ext")

    safe_copy "$src" "$target_dir/$new"
    log "Imported $type → $new"
    FOUND_ANY=true
}


# ========================= RADARR TEST MODE ========================

if [[ -z "${radarr_moviefile_sourcefolder:-}" ]] || [[ -z "${radarr_moviefile_path:-}" ]]; then
    log "Radarr test mode detected – script loaded successfully."
    exit 0
fi


# ========================= PATH SETUP ==============================

if [[ -n "${radarr_moviefile_sourcepath:-}" ]]; then
    SOURCE_DIR="$(dirname "$radarr_moviefile_sourcepath")"
else
    SOURCE_DIR="${radarr_moviefile_sourcefolder}"
    log "WARNING – radarr_moviefile_sourcepath missing, falling back to radarr_moviefile_sourcefolder."
fi

TARGET_DIR="${radarr_movie_path}"
MOVIE_FILE="${radarr_moviefile_path}"

log "Source folder : $SOURCE_DIR"
log "Target folder : $TARGET_DIR"
log "Movie file    : $MOVIE_FILE"
log "Dry‑run mode  : $DRY_RUN"


# ========================= RECURSIVE SCAN ==========================

mapfile -t ALL_VIDEOS < <(
    find "$SOURCE_DIR" -type f | while read -r f; do
        is_sample "$f" && continue
        is_video "$f" && echo "$f"
    done
)

if (( ${#ALL_VIDEOS[@]} == 0 )); then
    log "No video files found in source folder."
    exit 0
fi


# ========================= MOVIE DETECTION (STAT-BASED) ============

if (( ${#ALL_VIDEOS[@]} == 1 )); then
    log "Only one video file found in source folder — treating it as the movie and skipping."
    log "File: ${ALL_VIDEOS[0]}"
    exit 0
fi

largest_file=""
largest_size=0

for f in "${ALL_VIDEOS[@]}"; do
    size=$(stat -c%s "$f")
    if (( size > largest_size )); then
        largest_size=$size
        largest_file="$f"
    fi
done

MOVIE_FILE="$largest_file"
log "Largest file detected via stat(): $MOVIE_FILE ($largest_size bytes)"


# ========================= FOLDER EXTRA DETECTION ==================

detect_folder_type() {
    local name=$(lower "$1")
    for type in "${!FOLDER_KEYWORDS[@]}"; do
        for kw in ${FOLDER_KEYWORDS[$type]}; do
            [[ "$name" == *"$kw"* ]] && echo "$type" && return
        done
    done
    echo "other"
}

mapfile -t EXTRA_DIRS < <(
    find "$SOURCE_DIR" -type d | while read -r d; do
        [[ "$d" == "$SOURCE_DIR" ]] && continue
        folder_is_ignored "$(basename "$d")" && continue
        is_sample "$d" && continue
        echo "$d"
    done
)

for dir in "${EXTRA_DIRS[@]}"; do
    type=$(detect_folder_type "$(basename "$dir")")

    case "$type" in
        trailer)        $ENABLE_TRAILERS        || continue ;;
        behind)         $ENABLE_BEHIND_SCENES   || continue ;;
        featurette)     $ENABLE_FEATURETTES     || continue ;;
        interview)      $ENABLE_INTERVIEWS      || continue ;;
        deleted)        $ENABLE_DELETED         || continue ;;
        scene)          $ENABLE_SCENES          || continue ;;
        short)          $ENABLE_SHORTS          || continue ;;
        extra|other)    $ENABLE_OTHER           || continue ;;
    esac

    log "Processing folder: $dir (type: $type)"

    find "$dir" -maxdepth 1 -type f | while read -r f; do
        is_video "$f" || continue
        is_sample "$f" && continue
        [[ "$f" == "$MOVIE_FILE" ]] && continue
        copy_item "$f" "$type"
    done
done


# ========================= INLINE EXTRA DETECTION ==================

for file in "${ALL_VIDEOS[@]}"; do
    [[ "$file" == "$MOVIE_FILE" ]] && continue

    fname=$(lower "$(basename "$file")")
    type=""

    if [[ "$INLINE_STRICT" == true ]]; then
        for suffix in "${INLINE_SUFFIXES[@]}"; do
            if [[ "$fname" == *"$suffix."* ]]; then
                type="${suffix#-}"
                break
            fi
        done
    else
        for t in "${!FOLDER_KEYWORDS[@]}"; do
            for kw in ${FOLDER_KEYWORDS[$t]}; do
                [[ "$fname" == *"$kw"* ]] && type="$t"
            done
        done
    fi

    if [[ -n "$type" ]]; then
        copy_item "$file" "$type"
    else
        case "$UNKNOWN_MODE" in
            generous) copy_item "$file" "other" ;;
            strict)   log "Skipped unknown inline extra: $file" ;;
            skip)     log "Ignored unknown inline extra: $file" ;;
        esac
    fi
done


# ========================= FINAL STATUS ============================

if ! $FOUND_ANY; then
    log "Scan complete — no extras detected in source folder:"
    log "  $SOURCE_DIR"
    log "Movie folder:"
    log "  $TARGET_DIR"
else
    log "Extras processing completed successfully."
fi

log "SCRIPT FINISHED"
exit 0
