#!/bin/sh
# Runs the full test suite in the pinned container (ci/Dockerfile), the same way the
# GitHub Actions test job does. Needs Docker. Works from Git Bash on Windows too.
set -e
cd "$(dirname "$0")/.."
image=vulcan-duoquest-test
docker build -q -t "$image" ci >/dev/null
src="$(pwd)"
if command -v cygpath >/dev/null 2>&1; then src="$(cygpath -w "$src")"; fi
# The tree is mounted read-only and copied, so a test run never writes into your checkout.
MSYS_NO_PATHCONV=1 docker run --rm -v "$src:/src:ro" "$image" sh -c 'cp -r /src /w && cd /w && sh tests/run.sh'
