#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
	printf '%s\n' "Usage: Tests/run.sh [--list | suite ...]" \
		"With no arguments, runs every suite except MultiFace, which downloads test images."
}

case "${1:-}" in
	--help|-h) usage; exit 0 ;;
	--list)
		for script in "$ROOT"/*/run.sh; do
			name="${script%/run.sh}"
			printf '%s\n' "${name##*/}"
		done
		exit 0
		;;
esac

suites=()
if [ "$#" -eq 0 ]; then
	for script in "$ROOT"/*/run.sh; do
		name="${script%/run.sh}"
		name="${name##*/}"
		[ "$name" = MultiFace ] || suites+=("$name")
	done
else
	for name in "$@"; do
		case "$name" in
			''|*[!a-zA-Z0-9]*)
				echo "Unknown suite: $name. Run Tests/run.sh --list." >&2
				exit 2
				;;
		esac
		if [ ! -f "$ROOT/$name/run.sh" ]; then
			echo "Unknown suite: $name. Run Tests/run.sh --list." >&2
			exit 2
		fi
		suites+=("$name")
	done
fi

passed=0
failed=()
for name in "${suites[@]}"; do
	printf '\n%s\n' "== $name =="
	if bash "$ROOT/$name/run.sh"; then
		passed=$((passed + 1))
	else
		failed+=("$name")
	fi
done
printf '\n%s\n' "$passed/${#suites[@]} suites passed."
if [ "${#failed[@]}" -gt 0 ]; then
	printf 'Failed: %s\n' "${failed[@]}" >&2
	exit 1
fi
