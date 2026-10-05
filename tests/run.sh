#!/bin/sh
# Runs everything: syntax check, lint (addon + tests), the test suites, the
# personal-data guard and the package-shape test. Stops at the first failure.
set -e
cd "$(dirname "$0")"
# (the suites test the tree this script is in, wherever it is)
DQ_DIR="$(cd .. && pwd)/"
DQ_TESTS="$(pwd)/"
export DQ_DIR DQ_TESTS
echo "tools: $(lua5.1 -v 2>&1 | head -1); $(luacheck --version | head -1); $(python3 --version 2>&1); packager $(sha256sum /usr/local/bin/release.sh 2>/dev/null | cut -c1-12 || echo missing)"
for f in ../*.lua; do luac5.1 -p "$f"; done
luacheck --config .luacheckrc -q ../*.lua
luacheck -q --std lua51 --no-max-line-length --allow-defined-top --no-global --no-self harness.lua tests*.lua
for t in tests*.lua; do lua5.1 "$t"; done
python3 mutate.py --check  # (every mutation pattern still matches the code)
python3 guard_personal.py
# Every commit, tag and ref, once this is a git repository (CI always is).
if git rev-parse --git-dir >/dev/null 2>&1; then python3 guard_personal.py --history
elif [ "$GITHUB_ACTIONS" = true ]; then echo "FAIL personal-data guard: running on CI, but the checkout has no git history to check"; exit 1
else echo "personal-data guard: not a git repository yet, so there is no history to check"; fi
sh prepush_test.sh
sh package_test.sh
python3 release_check_test.py
echo "All DuoQuest tests passed."
