#!/bin/bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
SCRIPTS_ROOT="$TESTS_ROOT/Scripts"

usage() {
	cat <<'EOF'
Usage: Tests/run.sh [--unit | --all | --list | target ...]
  (no args)   Run `swift test`, `Tests/Scripts/Release/run.sh`, and `Tests/Scripts/AppIntegration/ProductBoundary/run.sh`.
  --unit      Run `swift test` only (CI/headless-safe).
  --all       Run `swift test`, `Tests/Scripts/Release/run.sh`, and all desktop `Tests/Scripts/AppIntegration/*/run.sh` suites (excluding network `MultiFace`).
  --list      List available targets and scripts.
  target ...  Run specific targets/scripts (e.g. `unit`, `GazeCoreTests`, `Release`, `ProductBoundary`, `Notch`, `MultiFace`).
EOF
}

list_targets() {
	printf '%s\n' "unit"
	for dir in "$TESTS_ROOT"/Gaze*Tests; do
		[ -d "$dir" ] || continue
		printf '%s\n' "${dir##*/}"
	done
	printf '%s\n' "Release" "MultiFace"
	for script in "$SCRIPTS_ROOT"/AppIntegration/*/run.sh; do
		[ -f "$script" ] || continue
		name="${script%/run.sh}"
		printf '%s\n' "${name##*/}"
	done
}

run_item() {
	local target="$1"
	case "$target" in
		unit)
			swift test --package-path "$REPO_ROOT"
			;;
		Gaze*Tests)
			swift test --package-path "$REPO_ROOT" --filter "$target"
			;;
		Release)
			bash "$SCRIPTS_ROOT/Release/run.sh"
			;;
		MultiFace)
			bash "$SCRIPTS_ROOT/MultiFace/run.sh"
			;;
		*)
			bash "$SCRIPTS_ROOT/AppIntegration/$target/run.sh"
			;;
	esac
}

validate_target() {
	local name="$1"
	case "$name" in
		''|*[!a-zA-Z0-9]*)
			echo "Unknown target: $name. Run Tests/run.sh --list." >&2
			exit 2
			;;
	esac
	case "$name" in
		unit|Release|MultiFace) return 0 ;;
		Gaze*Tests)
			[ -d "$TESTS_ROOT/$name" ] && return 0
			;;
		*)
			[ -f "$SCRIPTS_ROOT/AppIntegration/$name/run.sh" ] && return 0
			;;
	esac
	echo "Unknown target: $name. Run Tests/run.sh --list." >&2
	exit 2
}

targets=()
case "${1:-}" in
	--help|-h)
		usage
		exit 0
		;;
	--list)
		[ "$#" -eq 1 ] || { echo "Unexpected arguments with --list." >&2; exit 2; }
		list_targets
		exit 0
		;;
	--unit)
		[ "$#" -eq 1 ] || { echo "Unexpected arguments with --unit." >&2; exit 2; }
		targets=("unit")
		;;
	--all)
		[ "$#" -eq 1 ] || { echo "Unexpected arguments with --all." >&2; exit 2; }
		targets=("unit" "Release")
		for script in "$SCRIPTS_ROOT"/AppIntegration/*/run.sh; do
			[ -f "$script" ] || continue
			name="${script%/run.sh}"
			targets+=("${name##*/}")
		done
		;;
	"")
		targets=("unit" "Release" "ProductBoundary")
		;;
	--*)
		echo "Unknown option: $1. Run Tests/run.sh --help." >&2
		exit 2
		;;
	*)
		for name in "$@"; do
			validate_target "$name"
			targets+=("$name")
		done
		;;
esac

passed=0
failed=()
for name in "${targets[@]}"; do
	printf '\n%s\n' "== $name =="
	if run_item "$name"; then
		passed=$((passed + 1))
	else
		failed+=("$name")
	fi
done

printf '\n%s\n' "$passed/${#targets[@]} targets passed."
if [ "${#failed[@]}" -gt 0 ]; then
	printf 'Failed: %s\n' "${failed[@]}" >&2
	exit 1
fi
