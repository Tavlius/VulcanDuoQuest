#!/bin/sh
# Run once in a fresh clone (or right after `git init`), before the first commit:
#
#     sh tests/init_repo.sh
#
# It sets this repository's commit identity (never the machine-wide one) and installs
# a pre-push hook that runs the personal-data guard over the working tree and the whole
# history, so nothing leaves this computer until the guard passes.
set -e
cd "$(dirname "$0")/.."
git rev-parse --git-dir >/dev/null
git config user.name "Tavlius"
git config user.email "337816587+Tavlius""@users.noreply.github.com"
# The repository's own hooks folder. (Not `--git-path hooks`: that follows a
# core.hooksPath set elsewhere, and would overwrite a shared hooks folder.)
hooks="$(git rev-parse --git-common-dir)/hooks"
mkdir -p "$hooks"
cp tests/pre-push "$hooks/pre-push"
chmod +x "$hooks/pre-push"
echo "This repository now commits as $(git config user.name) <$(git config user.email)>,"
echo "and every push runs the personal-data guard first."
