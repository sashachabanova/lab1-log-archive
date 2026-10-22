#!/usr/bin/env bash
set -euo pipefail

# Запуск: bash lab.sh /путь/к/log [порог в процентах]
if (( $# < 1 || $# > 2 )); then
    echo "Использование: bash lab.sh ПАПКА [ПОРОГ]" >&2
    exit 1
fi

if [[ ! -d "$1" ]]; then
    echo "Ошибка: папка не существует" >&2
    exit 1
fi

threshold=${2:-70}
if [[ ! "$threshold" =~ ^[0-9]{1,3}$ ]]; then
    echo "Ошибка: порог должен быть целым числом от 1 до 100" >&2
    exit 1
fi
threshold=$((10#$threshold))
if (( threshold < 1 || threshold > 100 )); then
    echo "Ошибка: порог должен быть от 1 до 100" >&2
    exit 1
fi

folder=$(cd -- "$1" && pwd)
backup="$(dirname -- "$folder")/backup"
cd -- "$folder"

# Условная вместимость — 1 ГиБ. Считаем суммарный размер файлов.
capacity=$((1024 * 1024 * 1024))
limit=$((capacity * threshold / 100))
size=$(find . -type f -printf '%s\n' | awk '{sum += $1} END {printf "%.0f", sum}')
echo "Заполненность: $((size * 100 / capacity))% (порог: $threshold%)"

if (( size <= limit )); then
    echo "Архивация не нужна"
    exit 0
fi

# Сортируем по дате изменения: сначала самые старые файлы.
files=()
while IFS= read -r -d '' file; do
    files+=("$file")
    size=$((size - $(stat -c %s -- "$file")))
    if (( size <= limit )); then
        break
    fi
done < <(find . -type f -printf '%T@ %p\0' | sort -zn | cut -z -d ' ' -f 2-)

echo "Будут заархивированы ${#files[@]} файлов:"
printf '%s\n' "${files[@]}"
mkdir -p -- "$backup"
archive=$(mktemp "$backup/archive-XXXXXX.tar.gz")

# Для 9 баллов: gzip -9 включает максимальное сжатие.
compression='gzip'
if [[ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]]; then
    compression='gzip -9'
fi
if ! tar -I "$compression" -cf "$archive" -- "${files[@]}"; then
    rm -f -- "$archive"
    echo "Ошибка архивации; исходные файлы сохранены" >&2
    exit 1
fi

# Удаляем оригиналы только после успешной архивации.
rm -- "${files[@]}"
echo "Архив создан: $archive"
echo "Заполненность после архивации: $((size * 100 / capacity))%"
