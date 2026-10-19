#!/usr/bin/env bash
# GNU/Linux, Bash 4+. Run with bash log_archive.sh --help.
set -euo pipefail
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash log_archive.sh LOG_DIR [THRESHOLD_PERCENT] [BACKUP_DIR] [CAPACITY_MIB]
Defaults: threshold=70; backup=LOG_DIR/../backup; capacity=filesystem total.
Usage is the sum of regular file lengths / capacity * 100 (recursive).
Oldest files by mtime are archived until usage <= threshold.
Set LAB1_MAX_COMPRESSION=1 for tar.lzma instead of tar.gz.
The log directory must be quiescent while this script runs.
HELP
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
(( $# >= 1 && $# <= 4 )) || { usage >&2; exit 2; }
for cmd in find sort df awk realpath mktemp tar; do
    command -v "$cmd" >/dev/null || die "Required command: $cmd"
done
threshold=${2:-70}
[[ $threshold =~ ^(0|[1-9][0-9]?)$|^100$ ]] || die 'Threshold must be an integer from 0 to 100.'
[[ -d $1 && ! -L $1 ]] || die 'LOG_DIR must be an existing non-symlink directory.'
log=$(realpath -e -- "$1")
[[ $log != / ]] || die 'The filesystem root cannot be used as LOG_DIR.'
backup_arg=${3:-"$log/../backup"}
backup=$(realpath -m -- "$backup_arg")
[[ $backup != "$log" && $backup != "$log/"* ]] || die 'BACKUP_DIR must be outside LOG_DIR.'
compression=${LAB1_MAX_COMPRESSION:-0}
[[ $compression == 0 || $compression == 1 ]] || die 'LAB1_MAX_COMPRESSION must be 0 or 1.'
if (( $# == 4 )); then
    [[ $4 =~ ^[1-9][0-9]{0,8}$ ]] || die 'CAPACITY_MIB must be a positive integer (up to 999999999).'
    capacity=$(( $4 * 1024 * 1024 ))
else
    capacity=$(df -Pk -- "$log" | awk 'END {printf "%.0f", $2 * 1024}')
fi
[[ $capacity =~ ^[1-9][0-9]*$ && ${#capacity} -le 15 ]] || die 'Unsupported filesystem capacity.'
if [[ $compression == 1 ]]; then
    command -v xz >/dev/null || die 'xz (xz-utils) is required for LZMA.'
    suffix=tar.lzma; codec='--use-compress-program=xz --format=lzma'
else
    command -v gzip >/dev/null || die 'gzip is required.'
    suffix=tar.gz; codec=-z
fi
mkdir -p -- "$backup"
backup=$(realpath -e -- "$backup")
[[ $backup != "$log" && $backup != "$log/"* ]] || die 'BACKUP_DIR resolves inside LOG_DIR.'
# The lock is bound to the source, so different backup paths cannot bypass it.
lock="$log/.lab1.lock"
mkdir -- "$lock" 2>/dev/null || die 'Directory is locked (.lab1.lock); check another run.'
work=''
cleanup() {
    [[ -z $work ]] || rm -rf -- "$work"
    rmdir -- "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$backup/.lab1-work.XXXXXXXX")
# NUL records preserve spaces, tabs, newlines and leading dashes in names.
find -P "$log" -path "$lock" -prune -o -type f -printf '%T@ %s %P\0' > "$work/raw"
sort -z -n -- "$work/raw" > "$work/sorted"
declare -a names=() sizes=()
total=0
while IFS= read -r -d '' record; do
    rest=${record#* }; size=${rest%% *}; name=${rest#* }
    [[ ${#size} -le 15 ]] || die 'A file is too large.'
    total=$(( total + size ))
    (( total <= 999999999999999 )) || die 'Total file length is too large.'
    names+=("$name"); sizes+=("$size")
done < "$work/sorted"
percent() { awk -v n="$1" -v d="$capacity" 'BEGIN {printf "%.2f", 100*n/d}'; }
printf 'BEFORE bytes=%s capacity=%s usage=%s%% threshold=%s%%\n' "$total" "$capacity" "$(percent "$total")" "$threshold"
if (( total * 100 <= capacity * threshold )); then
    printf 'OK: threshold is not exceeded; no archive needed.\n'
    exit 0
fi
remaining=$total
declare -a selected=()
: > "$work/list"
for i in "${!names[@]}"; do
    (( remaining * 100 > capacity * threshold )) || break
    selected+=("${names[i]}")
    printf '%s\0' "${names[i]}" >> "$work/list"
    remaining=$(( remaining - sizes[i] ))
done
printf 'SELECTED files=%s bytes=%s\n' "${#selected[@]}" "$((total - remaining))"
# GNU tar: NUL list, literal names, no directory traversal, independent hardlinks.
tar --create "$codec" --format=pax --hard-dereference --file="$work/archive.$suffix" \
    --directory="$log" --null --verbatim-files-from --no-recursion --files-from="$work/list"
# Compare archive contents to the still-existing source BEFORE deleting anything.
[[ $compression != 1 ]] || xz --format=lzma --test -- "$work/archive.$suffix"
tar --compare "$codec" --file="$work/archive.$suffix" --directory="$log"
archive="$backup/archive-$(date -u +%Y%m%dT%H%M%SZ)-${work##*.}.$suffix"
mv -- "$work/archive.$suffix" "$archive"
printf 'ARCHIVE %s\n' "$archive"
for name in "${selected[@]}"; do
    rm -- "$log/$name" || die "Removal failed; archive preserved at $archive"
done
printf 'AFTER bytes=%s usage=%s%%\n' "$remaining" "$(percent "$remaining")"
printf 'OK: archive verified; archived originals removed.\n'
