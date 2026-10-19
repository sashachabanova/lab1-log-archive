#!/usr/bin/env bash
# Self-contained integration tests: 512 MiB of real data per scenario.
set -euo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/log_archive.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/lab1-tests.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Hash stdin, not a filename-bearing checksum record. Names containing newlines
# must never be serialized and parsed by sha256sum --check.
file_hash() {
    local digest
    digest=$(sha256sum < "$1") || return
    digest=${digest%% *}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}
# Small regression preflight, separate from the 12 full-size lab scenarios.
mkdir "$root/hash-regression"
for unusual in 'space name.log' '-leading-dash.log' $'line\nbreak.log'; do
    probe="$root/hash-regression/$unusual"
    printf abc > "$probe"
    [[ $(file_hash "$probe") == ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] || fail 'Filename hash regression'
    printf abd > "$probe"
    [[ $(file_hash "$probe") != ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] || fail 'Changed content was not detected'
done
printf 'CHECK: filename hashing and content-change detection passed.\n'
passed=0
run_case() {
    local label=$1 threshold=$2 expected=$3 mode=${4:-0}
    local base="$root/$label" logs backup i archive actual run_path=$PATH
    logs="$base/log space"; backup="$base/backup space"
    mkdir -p -- "$logs/sub dir" "$backup" "$base/extracted"
    mkdir -p "$base/outside"
    printf 'outside sentinel\n' > "$base/outside/do-not-touch"
    MSYS=winsymlinks:sys ln -s "$base/outside" "$logs/external-link"
    local -a files=('old file.log' 'sub dir/second.log' '-third.log' $'fourth\nline.log')
    for i in 0 1 2 3; do
        dd if=/dev/zero of="$logs/${files[i]}" bs=1048576 count=128 status=none
        printf 'unique-content-%s\n' "$i" | dd of="$logs/${files[i]}" conv=notrunc status=none
        touch -t "2020010$((i+1))0000.00" -- "$logs/${files[i]}"
        file_hash "$logs/${files[i]}" > "$base/hash$i"
    done
    actual=$(find "$logs" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s}')
    [[ $actual == 536870912 ]] || fail "$label: fixture must contain 512 MiB"
    if [[ $mode == 1 ]]; then
        # Reproduce a lzma command that writes XZ instead of legacy LZMA.
        mkdir "$base/codec-bin"
        printf '#!/usr/bin/env bash\nexec xz "$@"\n' > "$base/codec-bin/lzma"
        chmod +x "$base/codec-bin/lzma"
        run_path="$base/codec-bin:$PATH"
        printf probe > "$base/probe"
        PATH=$run_path tar --use-compress-program=lzma -cf "$base/wrong-format.tar.lzma" -C "$base" probe
        xz --format=xz --test -- "$base/wrong-format.tar.lzma"
        if xz --format=lzma --test -- "$base/wrong-format.tar.lzma" 2>/dev/null; then
            fail 'Regression setup did not reproduce the wrong-format archive'
        fi
        printf 'CHECK: reproduced XZ output from implicit lzma; testing explicit LZMA.\n'
    fi
    printf '\nTEST %s (512 MiB)\n' "$label"
    PATH=$run_path LAB1_MAX_COMPRESSION=$mode bash "$script" "$logs" "$threshold" "$backup" 640
    local -a archives=()
    mapfile -d '' archives < <(find "$backup" -maxdepth 1 -type f -name 'archive-*' -print0)
    if (( expected == 0 )); then
        (( ${#archives[@]} == 0 )) || fail "$label: unexpected archive"
    else
        (( ${#archives[@]} == 1 )) || fail "$label: expected one archive"
        archive=${archives[0]}
        if [[ $mode == 1 ]]; then
            [[ $archive == *.tar.lzma ]] || fail 'Wrong LZMA extension'
            xz --format=lzma --test -- "$archive"
        else
            [[ $archive == *.tar.gz ]] || fail 'Wrong gzip extension'
            gzip -t -- "$archive"
        fi
        tar -xf "$archive" -C "$base/extracted"
        actual=$(find "$base/extracted" -type f -printf '1\n' | wc -l)
        (( actual == expected )) || fail "$label: wrong archive member count"
    fi
    for i in 0 1 2 3; do
        if (( i < expected )); then
            [[ ! -e $logs/${files[i]} ]] || fail "$label: archived source remains"
            [[ $(file_hash "$base/extracted/${files[i]}") == $(cat "$base/hash$i") ]] || fail 'Archived bytes differ'
        else
            [[ ! -e $base/extracted/${files[i]} ]] || fail 'New file archived unexpectedly'
            [[ $(file_hash "$logs/${files[i]}") == $(cat "$base/hash$i") ]] || fail 'Remaining bytes differ'
        fi
    done
    actual=$(find "$logs" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s+0}')
    [[ $actual == $(( (4-expected)*134217728 )) ]] || fail 'Wrong final size'
    [[ ! -e $logs/.lab1.lock ]] || fail 'Lock not removed'
    [[ $(cat "$base/outside/do-not-touch") == 'outside sentinel' ]] || fail 'Symlink target changed'
    passed=$((passed+1))
    printf 'PASS %s\n' "$label"
    rm -rf -- "$base"
}
run_case below_threshold 90 0
run_case exact_threshold 80 0
run_case one_oldest 70 1
run_case two_oldest 50 2
run_case lzma 70 1 1
run_case zero_threshold 0 4
# Failure cases use a fresh full-size fixture as required by the task.
base="$root/invalid"; mkdir -p "$base/log" "$base/backup"
dd if=/dev/zero of="$base/log/keep.log" bs=1048576 count=512 status=none
before=$(file_hash "$base/log/keep.log")
mkdir "$base/fake-bin"
printf '#!/usr/bin/env bash\nexit 42\n' > "$base/fake-bin/tar"
chmod +x "$base/fake-bin/tar"
for kind in bad_threshold bad_capacity nested_backup invalid_compression locked archive_failure; do
    args=("$base/log" 70 "$base/backup" 640); mode=0
    run_path=$PATH
    case $kind in
        bad_threshold) args[1]=abc ;;
        bad_capacity) args[3]=0 ;;
        nested_backup) args[2]="$base/log/backup" ;;
        invalid_compression) mode=bad ;;
        locked) mkdir "$base/log/.lab1.lock" ;;
        archive_failure) run_path="$base/fake-bin:$PATH" ;;
    esac
    if PATH=$run_path LAB1_MAX_COMPRESSION=$mode bash "$script" "${args[@]}" > "$base/output" 2>&1; then
        fail "$kind: invalid request unexpectedly succeeded"
    fi
    [[ $(file_hash "$base/log/keep.log") == "$before" ]] || fail "$kind: source changed"
    [[ -z $(find "$base/backup" -type f -print -quit) ]] || fail "$kind: unexpected archive"
    [[ $kind != locked ]] || rmdir "$base/log/.lab1.lock"
    [[ ! -e $base/log/.lab1.lock ]] || fail "$kind: lock not cleaned up"
    passed=$((passed+1)); printf 'PASS %s (512 MiB preserved)\n' "$kind"
done
printf '\nRESULT: %s tests passed.\n' "$passed"
