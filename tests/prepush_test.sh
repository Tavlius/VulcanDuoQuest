#!/bin/sh
# Tests tests/init_repo.sh and the pre-push hook it installs, on a throwaway copy of
# this tree pushing to a throwaway bare repository:
#   - init_repo.sh sets the repository's own identity;
#   - a clean history pushes;
#   - a push is refused when the history holds an email address, or a commit by
#     another identity, even after the file was deleted again, or with the commit
#     hidden behind `git replace`, or pushed by id with no ref pointing to it.
set -e
cd "$(dirname "$0")/.."
src="$(pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "  ok: $1"; }
bad() { echo "FAIL pre-push test: $1"; fail=1; }

git init -q --bare "$tmp/remote.git"
mkdir "$tmp/w"
( cd "$src" && tar --exclude=./.git --exclude=./.release -cf - . ) | ( cd "$tmp/w" && tar -xf - )
cd "$tmp/w"
git init -q -b main
# A machine-wide identity that must not be used.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name "Machine Name"
git config --global user.email "machine""@example.invalid"
sh tests/init_repo.sh >/dev/null
[ "$(git config --local user.name)" = "Tavlius" ] && ok "local user.name set" || bad "local user.name not set"
[ "$(git config --local user.email)" = "337816587+Tavlius""@users.noreply.github.com" ] && ok "local user.email set" || bad "local user.email not set"
[ -x .git/hooks/pre-push ] && ok "hook installed" || bad "hook not installed"
git remote add origin "$tmp/remote.git"
git add -A
git commit -qm "Initial commit"
if git push -q origin main >/dev/null 2>&1; then ok "a clean history pushes"; else bad "a clean history was refused"; fi

echo "mail someone""@example.com" > leak.txt
git add leak.txt && git commit -qm "add" && git rm -q leak.txt && git commit -qm "remove"
if git push -q origin main >/dev/null 2>&1; then bad "an email in the history was pushed"; else ok "an email in the history is refused"; fi
git reset -q --hard HEAD~2

git -c user.name="Machine Name" -c user.email="machine""@example.invalid" commit -q --allow-empty -m "other identity"
if git push -q origin main >/dev/null 2>&1; then bad "another identity's commit was pushed"; else ok "another identity's commit is refused"; fi

# The same commit hidden behind `git replace` (git would show the guard the clean
# replacement, while the push sends the original).
clean=$(git commit-tree "HEAD^{tree}" -p HEAD~1 -m "clean")
git replace HEAD "$clean"
if git push -q origin main >/dev/null 2>&1; then bad "a commit hidden by git replace was pushed"; else ok "a commit hidden by git replace is refused"; fi
git replace -d HEAD >/dev/null
git reset -q --hard HEAD~1

# A leaking commit that no branch or tag points to any more, pushed by its id.
echo "mail someone""@example.com" > leak2.txt
git add leak2.txt && git commit -qm "leak" && orphan=$(git rev-parse HEAD) && git reset -q --hard HEAD~1
if git push -q origin "$orphan:refs/heads/side" >/dev/null 2>&1; then bad "a commit no ref points to was pushed by its id"; else ok "a commit no ref points to is refused when pushed by its id"; fi

[ "$fail" = 0 ] && echo "pre-push test: init_repo.sh and the hook work" || exit 1
