#!/usr/bin/env bash
# Separate warm-up task from the chat screenshot, not part of archive tests.
set -euo pipefail
if (( $# != 2 )); then
    printf 'Usage: bash name_age.sh NAME AGE\n' >&2
    exit 2
fi
name=$1
age=$2
pattern="^[[:alpha:]][[:alpha:] '-]*$"
[[ $name =~ $pattern ]] || { printf 'ERROR: invalid name.\n' >&2; exit 1; }
[[ $age =~ ^[0-9]{1,3}$ ]] || { printf 'ERROR: age must be an integer.\n' >&2; exit 1; }
age=$((10#$age))
(( age <= 150 )) || { printf 'ERROR: age must be 0..150.\n' >&2; exit 1; }
printf 'Hello, %s! Age: %s\n' "$name" "$age"
