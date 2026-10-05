"""Checks the packager's log after a release. The packager reports a skipped upload, a
failed one, or a game-version fallback only as a line of output and still exits 0, so
the release job runs this on its log and fails unless every upload really happened.

    python3 tests/check_upload_log.py packager.log
"""
import re
import sys

UPLOADS = {
    'CurseForge': re.compile(r'^Uploading \S+\.zip \(.+\) to https://wow\.curseforge\.com/projects/\S+$'),
    'Wago': re.compile(r'^Uploading \S+\.zip \(.+\) to https://addons\.wago\.io/addons/\S+$'),
}
GITHUB = re.compile(r'^Uploading \S+\.zip\.\.\. Success!$')
BAD = [
    (re.compile(r'WARNING: No (CurseForge|Wago) game version match'), 'the site has no matching game version, so the packager picked another one'),
    (re.compile(r'^Skipping upload'), 'an upload was skipped'),
]


def problems(log):
    lines = [l.rstrip('\r') for l in log.split('\n')]
    out = []
    for site, pat in UPLOADS.items():
        idx = [i for i, l in enumerate(lines) if pat.match(l)]
        if not idx:
            out.append('%s: no upload in the log' % site)
            continue
        # The last attempt (the packager retries CurseForge) must be followed by "Success!"
        # within the next few lines, before any other upload starts.
        after = []
        for l in lines[idx[-1] + 1:idx[-1] + 4]:
            if l.startswith('Uploading '):
                break
            after.append(l)
        if 'Success!' not in after:
            out.append('%s: the upload didn\'t report success' % site)
    if not any(GITHUB.match(l) for l in lines):
        out.append('GitHub: the zip wasn\'t attached to the release')
    for pat, why in BAD:
        for l in lines:
            if pat.search(l):
                out.append('%s: %s' % (why, l.strip()[:160]))
                break
    return out


def main():
    found = problems(open(sys.argv[1], encoding='utf-8', errors='replace').read())
    for p in found:
        print('::error::Release check: ' + p)
    if found:
        sys.exit(1)
    print('Release check: every upload succeeded (CurseForge, Wago, GitHub).')


if __name__ == '__main__':
    main()
