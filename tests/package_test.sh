#!/bin/sh
# Package-shape test: builds the release zip the way the GitHub release job does
# (the BigWigs packager, with uploads switched off by -d) and checks what players get.
set -e
cd "$(dirname "$0")/.."
NAME=VulcanDuoQuest
TAG=v9.9.9-test
fail() { echo "FAIL package test: $*"; exit 1; }
command -v release.sh >/dev/null 2>&1 || fail "the BigWigs packager isn't installed (run tests/docker.sh)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The packager reads the version from git, so it runs on a throwaway repository
# holding a copy of this tree (the real checkout is never touched).
mkdir "$tmp/src"
tar --exclude=./.git --exclude=./.release -cf - . | tar -xf - -C "$tmp/src"
(
  cd "$tmp/src"
  git init -q
  git add -A
  git -c user.name=pkgtest -c user.email=pkgtest@invalid commit -qm "package test"
  git tag "$TAG"
)
release.sh -d -t "$tmp/src" -r "$tmp/out" >"$tmp/log" 2>&1 || { tail -20 "$tmp/log"; fail "the packager failed"; }
set -- "$tmp"/out/*.zip
[ "$#" = 1 ] && [ -f "$1" ] || fail "expected exactly one zip, got: $*"
zip="$1"
list=$(unzip -Z1 "$zip")
echo "$list" | grep -qv "^$NAME/" && fail "files outside the $NAME/ folder: $(echo "$list" | grep -v "^$NAME/" | head -3)"
echo "$list" | grep -qx "$NAME/$NAME.toc" || fail "no $NAME/$NAME.toc in the zip"
dev=$(echo "$list" | grep -E "^$NAME/(tests|ci|\.github|media-src|dev)/|/AUDIT_(LOG|REPORT)\.md$|/\.pkgmeta$|/\.luacheckrc$|/\.git(ignore|attributes)?$|/\.release/" || true)
[ -z "$dev" ] || fail "dev-only files in the zip: $(echo "$dev" | head -5)"
mkdir "$tmp/unz" && unzip -q "$zip" -d "$tmp/unz"
# (The packager writes CRLF line endings into the zip unless run with -u; WoW reads either.)
toc="$tmp/toc.txt"
tr -d '\r' < "$tmp/unz/$NAME/$NAME.toc" > "$toc"
grep -qx "## Version: $TAG" "$toc" || fail "TOC version not replaced by the tag: $(grep '^## Version' "$toc")"
grep -qx "## Interface: 16001" "$toc" || fail "TOC interface changed: $(grep '^## Interface' "$toc")"
grep -rl "@project-version@" "$tmp/unz" >/dev/null 2>&1 && fail "an unreplaced @project-version@ is left in the zip"
missing=$(sed -n 's/\r$//; /^[^#].*\.\(lua\|xml\)$/p' "$toc" | while read -r f; do [ -f "$tmp/unz/$NAME/$f" ] || echo "$f"; done)
[ -z "$missing" ] || fail "files the TOC loads are missing: $missing"
for f in LICENSE README.md CHANGELOG.md Bindings.xml; do
  [ -f "$tmp/unz/$NAME/$f" ] || fail "$f missing from the zip"
done
# The packager replaces its keywords in every text file, so check the docs come through unchanged.
for f in README.md CHANGELOG.md LICENSE; do
  tr -d '\r' < "$tmp/unz/$NAME/$f" | cmp -s - "$f" || fail "$f in the zip differs from the source (the packager rewrote something in it)"
done
# The icon the TOC names (Interface\AddOns\<name>\...) must be in the zip.
icon=$(sed -n 's/\r$//; s/^## IconTexture: Interface\\AddOns\\'"$NAME"'\\//p' "$toc" | tr '\\' '/')
[ -n "$icon" ] && [ -f "$tmp/unz/$NAME/$icon.tga" ] || fail "the icon the TOC names isn't in the zip: $icon"
echo "package test: $(basename "$zip"), $(echo "$list" | grep -vc '/$') files, one $NAME/ folder, version $TAG"
