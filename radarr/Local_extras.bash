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
# ./extras_script.bash
# ==================================================================
# v1.0.2

# ========================= USER SETTINGS ===========================

ENABLE_LOGGING=true
ENABLE_DEBUG=true
LOG_FILE="/config/logs/local_extras.txt"

DRY_RUN="${DRY_RUN:-false}"
INLINE_STRICT="${INLINE_STRICT:-false}"

RENAME_MODE="plex"      # plex | jellyfin | kodi | none
STORAGE_MODE="inline"   # inline | folders
UNKNOWN_MODE="generous" # generous | strict | skip

ENABLE_TRAILERS=true
ENABLE_BEHIND_SCENES=true
ENABLE_FEATURETTES=true
ENABLE_INTERVIEWS=true
ENABLE_DELETED=true
ENABLE_SCENES=true
ENABLE_SHORTS=true
ENABLE_OTHER=true

# Optional ignore list for folders that should never be treated as extras
IGNORE_FOLDERS=("subs" "subtitles" "bdmv" "certificate" "audio" "video_ts" "sample" ".stfolder")


# ========================= INTERNAL DATA ===========================

VIDEO_EXTENSIONS="mkv mp4 mov avi m4v webm mpg mpeg ts m2ts flv f4v 3gp 3g2 wmv asf"

declare -A FOLDER_KEYWORDS=(
    ["trailer"]="trailer trailers"
    ["behind"]="behind the scenes bts behind"
    ["featurette"]="featurette featurettes"
    ["interview"]="interview interviews"
    ["deleted"]="deleted delete"
    ["scene"]="scene scenes"
    ["short"]="short shorts"
    ["extra"]="extra extras bonus"
    ["other"]="other misc"
)

declare -A TYPE_PRIORITY=(
    [deleted]=100
    [trailer]=90
    [behind]=80
    [featurette]=70
    [interview]=60
    [scene]=50
    [short]=40
    [extra]=10
    [other]=10
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
    local f
    f=$(lower "$1")
    for ext in $VIDEO_EXTENSIONS; do
        [[ "$f" == *.$ext ]] && return 0
    done
    return 1
}

folder_is_ignored() {
    local name
    name=$(lower "$1")
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

# ------------ Normalization / identity helpers ------------

normalize_title_simple() {
    local s
    s=$(lower "$1")

    # remove extension
    s="${s%.*}"

    # replace separators with spaces
    s="${s//./ }"
    s="${s//_/ }"
    s="${s//-/ }"
    s="${s//\(/ }"
    s="${s//\)/ }"
    s="${s//

\[/ }"
    s="${s//\]

/ }"

    # remove year-like numbers (roughly)
    s="${s//19[0-9][0-9]/ }"
    s="${s//20[0-9][0-9]/ }"

    # collapse multiple spaces
    s=$(echo "$s" | tr -s ' ')

    printf '%s' "$s"
}

title_tokens() {
    local s
    s=$(normalize_title_simple "$1")
    for tok in $s; do
        # ignore very short tokens to reduce noise
        [[ ${#tok} -ge 3 ]] && printf '%s ' "$tok"
    done
}

extract_year_from_title() {
    local t
    t="$1"
    if [[ "$t" =~ ([12][0-9]{3}) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Check if given filename resembles the movie file name
resembles_movie_title() {
    local fname_base="$1"
    local movie_path="$2"

    local movie_name movie_base normalized_movie normalized_file

    movie_name=$(basename "$movie_path")
    movie_base="${movie_name%.*}"

    normalized_movie=$(normalize_title_simple "$movie_base")
    normalized_file=$(normalize_title_simple "$fname_base")

    local probe_len=12
    local movie_probe=${normalized_movie:0:$probe_len}

    [[ -n "$movie_probe" && "$normalized_file" == *"$movie_probe"* ]]
}

# ------------ Keyword detection (whole-word, weighted) ------------

detect_type_from_string() {
    local text
    text=$(lower "$1")

    # Normalize separators to spaces
    text="${text//./ }"
    text="${text//_/ }"
    text="${text//-/ }"
    text="${text//\(/ }"
    text="${text//\)/ }"
    text="${text//

\[/ }"
    text="${text//\]

/ }"

    # Add surrounding spaces for whole-word matching
    text=" $text "

    local best_type=""
    local best_score=0

    for t in "${!FOLDER_KEYWORDS[@]}"; do
        for kw in ${FOLDER_KEYWORDS[$t]}; do
            if [[ "$text" == *" $kw "* ]]; then
                local score=${TYPE_PRIORITY[$t]:-0}
                if (( score > best_score )); then
                    best_score=$score
                    best_type=$t
                fi
            fi
        done
    done

    [[ -n "$best_type" ]] && printf '%s\n' "$best_type" || return 1
}

detect_folder_type() {
    detect_type_from_string "$1" || printf '%s\n' "other"
}

# INLINE detection with support for strict suffix mode and weighted keywords
detect_inline_type() {
    local filename="$1"
    local fname_lower
    fname_lower=$(lower "$filename")

    if [[ "$INLINE_STRICT" == true ]]; then
        for suffix in "${INLINE_SUFFIXES[@]}"; do
            if [[ "$fname_lower" == *"$suffix."* ]]; then
                printf '%s\n' "${suffix#-}"
                return 0
            fi
        done
        return 1
    else
        detect_type_from_string "$fname_lower" || return 1
    fi
}


# ========================= RADARR TEST MODE ========================

if [[ -z "${radarr_moviefile_sourcefolder:-}" ]] || [[ -z "${radarr_moviefile_path:-}" ]]; then
    log "Radarr test mode detected – script loaded successfully."
    exit 0
fi


# ========================= PATH / MOVIE IDENTITY ===================

if [[ -n "${radarr_moviefile_sourcepath:-}" ]]; then
    SOURCE_DIR="$(dirname "$radarr_moviefile_sourcepath")"
else
    SOURCE_DIR="${radarr_moviefile_sourcefolder}"
    log "WARNING – radarr_moviefile_sourcepath missing, falling back to radarr_moviefile_sourcefolder."
fi

TARGET_DIR="${radarr_movie_path}"
MOVIE_FILE="${radarr_moviefile_path}"

MOVIE_DIR_BASENAME="$(basename "$radarr_movie_path")"
MOVIE_TITLE_TOKENS="$(title_tokens "$MOVIE_DIR_BASENAME")"
MOVIE_YEAR="$(extract_year_from_title "$MOVIE_DIR_BASENAME")"

log "Source folder : $SOURCE_DIR"
log "Target folder : $TARGET_DIR"
log "Movie file    : $MOVIE_FILE"
log "Dry‑run mode  : $DRY_RUN"
log "Movie identity: title tokens=[$MOVIE_TITLE_TOKENS] year=[$MOVIE_YEAR]"


# ========================= RECURSIVE SCAN ==========================

mapfile -t ALL_VIDEOS < <(
    find "$SOURCE_DIR" -maxdepth 2 -type f | while read -r f; do
        is_sample "$f" && continue
        is_video "$f" && echo "$f"
    done
)

if (( ${#ALL_VIDEOS[@]} == 0 )); then
    log "No video files found in source folder."
    exit 0
fi

ROOT_VIDEOS=()
SUB_VIDEOS=()

for f in "${ALL_VIDEOS[@]}"; do
    if [[ "$(dirname "$f")" == "$SOURCE_DIR" ]]; then
        ROOT_VIDEOS+=("$f")
    else
        SUB_VIDEOS+=("$f")
    fi
done

ROOT_COUNT=${#ROOT_VIDEOS[@]}
SUB_COUNT=${#SUB_VIDEOS[@]}
TOTAL_COUNT=${#ALL_VIDEOS[@]}

log "Video counts – total: $TOTAL_COUNT, root: $ROOT_COUNT, subfolders: $SUB_COUNT"


# ========================= SOURCE FOLDER CLASSIFICATION ============

is_release_like_folder() {
    local folder_base
    folder_base=$(basename "$1")
    local folder_tokens
    folder_tokens=$(title_tokens "$folder_base")

    local match_count=0
    for mt in $MOVIE_TITLE_TOKENS; do
        [[ -z "$mt" ]] && continue
        if [[ " $folder_tokens " == *" $mt "* ]]; then
            ((match_count++))
        fi
    done

    # Criteria: at least 1 significant token matches OR year matches
    if (( match_count >= 1 )); then
        return 0
    fi

    if [[ -n "$MOVIE_YEAR" && "$folder_base" == *"$MOVIE_YEAR"* ]]; then
        return 0
    fi

    return 1
}

# Check if SOURCE_DIR looks like the actual release folder
if is_release_like_folder "$SOURCE_DIR"; then
    log "Source folder appears to be a release folder for this movie."
else
    # SOURCE_DIR does NOT look like a release folder (likely generic downloads)
    # For safety, do NOT scan all movies. Only act if there's obviously a single related file.
    log "Source folder does NOT resemble this movie – treating as generic/shared downloads."
    # In generic/shared folders, we bail out to avoid importing unrelated movies as extras.
    log "Safety bailout: skipping extras scan to avoid mis-importing other movies."
    exit 0
fi


# ========================= SINGLE-FILE LOGIC =======================

handle_single_file() {
    local single="$1"
    local fname_base
    fname_base=$(basename "$single")
    local fname_lower
    fname_lower=$(lower "$fname_base")
    local parent_lower
    parent_lower=$(lower "$(basename "$SOURCE_DIR")")

    local filename_type parent_type
    filename_type=$(detect_type_from_string "$fname_lower" || true)
    parent_type=$(detect_type_from_string "$parent_lower" || true)

    local resembles=false
    if resembles_movie_title "$fname_base" "$MOVIE_FILE"; then
        resembles=true
    fi

    # 1) Filename clearly indicates extra and does NOT resemble movie → extra
    if [[ -n "$filename_type" && "$resembles" == false ]]; then
        log "Single file detected — filename indicates extra ($filename_type)."
        copy_item "$single" "$filename_type"
        exit 0
    fi

    # 2) Parent indicates extras and filename not clearly movie → extra
    if [[ -n "$parent_type" && "$resembles" == false ]]; then
        log "Single file detected — parent folder indicates extra ($parent_type)."
        copy_item "$single" "$parent_type"
        exit 0
    fi

    # 3) Resembles movie title and no extra keywords → movie
    if [[ "$resembles" == true && -z "$filename_type" ]]; then
        log "Single file detected — resembles movie title and no extra keywords; treating as movie."
        exit 0
    fi

    # 4) Resembles movie title but has extra keyword → extra
    if [[ "$resembles" == true && -n "$filename_type" ]]; then
        log "Single file detected — resembles movie title but filename indicates extra ($filename_type); treating as extra."
        copy_item "$single" "$filename_type"
        exit 0
    fi

    # 5) No strong signals → assume movie
    log "Single file detected — no strong extra signals; treating as movie."
    exit 0
}

if (( TOTAL_COUNT == 1 )); then
    handle_single_file "${ALL_VIDEOS[0]}"
fi


# ========================= MOVIE DETECTION (STRUCTURE + STAT) ======

if (( ROOT_COUNT == 1 && SUB_COUNT >= 1 )); then
    MOVIE_FILE="${ROOT_VIDEOS[0]}"
    log "Directory structure suggests root file as movie: $MOVIE_FILE"
else
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
fi


# ========================= RELATED FOLDERS ONLY ====================

# Build list of candidate extra folders: only subfolders within this release-like SOURCE_DIR
mapfile -t EXTRA_DIRS < <(
    find "$SOURCE_DIR" -mindepth 1 -maxdepth 2 -type d | while read -r d; do
        [[ "$d" == "$SOURCE_DIR" ]] && continue
        local base
        base=$(basename "$d")
        folder_is_ignored "$base" && continue
        is_sample "$d" && continue

        # Folder must either:
        #  - Contain at least one movie title token, or
        #  - Contain the movie year, or
        #  - Be a generic extras-type folder (detected by keywords)
        local base_lower
        base_lower=$(lower "$base")
        local token_match=false
        for mt in $MOVIE_TITLE_TOKENS; do
            [[ -z "$mt" ]] && continue
            if [[ " $base_lower " == *" $mt "* ]]; then
                token_match=true
                break
            fi
        done

        local year_match=false
        if [[ -n "$MOVIE_YEAR" && "$base_lower" == *"$MOVIE_YEAR"* ]]; then
            year_match=true
        fi

        local extras_like=false
        if detect_type_from_string "$base_lower" >/dev/null 2>&1; then
            extras_like=true
        fi

        if $token_match || $year_match || $extras_like; then
            echo "$d"
        fi
    done
)

log "Candidate extras folders detected: ${#EXTRA_DIRS[@]}"


# ========================= FOLDER EXTRA DETECTION ==================

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

    fname_base=$(basename "$file")
    type=""

    if type=$(detect_inline_type "$fname_base" 2>/dev/null); then
        :
    else
        type=""
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
