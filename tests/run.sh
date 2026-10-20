#!/usr/bin/env bash
# Runs the package's tests: the [Test] functions in tests/, with pepper test.
#
# Usage: tests/run.sh [path/to/pepper]   (default: pepper on PATH)
#
# Then it builds each program in tests/rejected/, which breaks a thread-safety
# rule, and checks that the compiler rejects it with the error its
# `# expect:` line names.
set -euxo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pepper="${1:-pepper}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# The package is the module `sqlite`: a folder of that name on the import path.
mkdir "$build/packages"
ln -s "$root" "$build/packages/sqlite"
"$pepper" test -I "$build/packages" "$root/tests"

for program in "$root"/tests/rejected/*.pep; do
    expected="$(sed -n 's/^# expect: //p' "$program")"
    if "$pepper" build -I "$build/packages" "$program" -o "$build/rejected" 2>"$build/errors"; then
        echo "error: $program built, but the compiler should reject it" >&2
        exit 1
    fi
    grep -F -- "$expected" "$build/errors" || {
        cat "$build/errors" >&2
        echo "error: $program failed without: $expected" >&2
        exit 1
    }
done
