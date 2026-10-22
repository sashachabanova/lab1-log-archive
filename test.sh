#!/usr/bin/env bash
set -euo pipefail

# Запуск: bash test.sh (рядом должен лежать lab.sh).
script="$(cd -- "$(dirname -- "$0")" && pwd)/lab.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
passed=0
failed=0

result() {
    if "$@"; then
        echo "ОК"
        passed=$((passed + 1))
    else
        echo "ОШИБКА"
        failed=$((failed + 1))
    fi
}

# Каждый тест получает минимум 512 МиБ настоящих данных.
prepare() {
    case_dir="$temp_dir/$1"
    mkdir -p "$case_dir/log"
    for ((i = 1; i <= $2; i++)); do
        dd if=/dev/zero of="$case_dir/log/$i.log" bs=1M count=256 status=none
        touch -t "202001010${i}00" "$case_dir/log/$i.log"
    done
}

check_archive() {
    local archive
    local restored="$case_dir/restored"
    archive=$(find "$case_dir/backup" -name '*.tar.gz' -type f)
    [[ -f "$archive" ]] || return 1
    gzip -t "$archive" || return 1
    mkdir -p "$restored"
    tar -xzf "$archive" -C "$restored" || return 1
    # В архиве должны быть ровно два старейших файла без потери данных.
    [[ $(find "$restored" -type f | wc -l) -eq 2 ]] || return 1
    cmp "$restored/1.log" "$case_dir/expected.log" || return 1
    cmp "$restored/2.log" "$case_dir/expected.log" || return 1
    [[ ! -e "$case_dir/log/1.log" && ! -e "$case_dir/log/2.log" ]] || return 1
    [[ -f "$case_dir/log/3.log" && -f "$case_dir/log/4.log" ]]
}

echo "Тест 1: 512 МиБ, порог 70%, архив не нужен"
prepare below 2
if bash "$script" "$case_dir/log"; then
    result test ! -d "$case_dir/backup"
else
    result false
fi
rm -rf -- "$case_dir"

echo "Тест 2: 1 ГиБ, архивируются два старейших файла"
prepare archive 4
cp "$case_dir/log/1.log" "$case_dir/expected.log"
if bash "$script" "$case_dir/log"; then
    result check_archive
else
    result false
fi
rm -rf -- "$case_dir"

echo "Тест 3: 512 МиБ, порог 50%, ровно на границе"
prepare boundary 2
if bash "$script" "$case_dir/log" 50; then
    result test ! -d "$case_dir/backup"
else
    result false
fi
rm -rf -- "$case_dir"

echo "Тест 4: неверный порог, код возврата 1"
prepare invalid 2
status=0
bash "$script" "$case_dir/log" abc || status=$?
result test "$status" -eq 1
rm -rf -- "$case_dir"

echo "Тест 5: LAB1_MAX_COMPRESSION=1, проверяем gzip -9"
prepare maximum 4
cp "$case_dir/log/1.log" "$case_dir/expected.log"
# Обёртка записывает параметры gzip и запускает настоящий gzip.
export REAL_GZIP="$(command -v gzip)"
export GZIP_LOG="$case_dir/gzip.log"
mkdir "$case_dir/bin"
cat > "$case_dir/bin/gzip" <<'WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GZIP_LOG"
exec "$REAL_GZIP" "$@"
WRAPPER
chmod +x "$case_dir/bin/gzip"
check_maximum() {
    grep -qx -- '-9' "$GZIP_LOG" || return 1
    check_archive
}
if PATH="$case_dir/bin:$PATH" LAB1_MAX_COMPRESSION=1 bash "$script" "$case_dir/log"; then
    result check_maximum
else
    result false
fi
rm -rf -- "$case_dir"

echo "Пройдено: $passed; ошибок: $failed"
if (( failed > 0 )); then
    exit 1
fi
