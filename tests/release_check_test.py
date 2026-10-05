"""Runs the release job's "Check release prerequisites" script (taken from
.github/workflows/release.yml as it is) against good and bad setups, since GitHub is
the only other place it ever runs. Each bad setup must fail; the good one must pass.
Then checks the packaging step itself (the tested packager, its secrets, no skip
options, its log checked) and tests/check_upload_log.py on packager-shaped logs.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
NAME = [f[:-4] for f in os.listdir(ROOT) if f.endswith('.toc')][0]


def check_script():
    wf = open(os.path.join(ROOT, '.github', 'workflows', 'release.yml'), encoding='utf-8').read().split('\n')
    i = next(k for k, l in enumerate(wf) if 'name: Check release prerequisites' in l)
    j = next(k for k in range(i, len(wf)) if wf[k].strip() == 'run: |')
    indent = len(wf[j + 1]) - len(wf[j + 1].lstrip())
    body = []
    for line in wf[j + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:])
    return '\n'.join(body)


SCRIPT = check_script()
passed = failed = 0


def run(label, expect_ok, tag='v1.2.0', cf='key', wago='token', curse_id='123456', wago_id='he54k6bL',
        changelog=True, on_main=True):
    global passed, failed
    d = tempfile.mkdtemp()
    try:
        git = lambda *a: subprocess.run(['git', '-C', d] + list(a), capture_output=True, text=True, check=True)
        git('init', '-q', '-b', 'main')
        toc = '## Interface: 16001\n## Title: x\n'
        if curse_id is not None:
            toc += '## X-Curse-Project-ID: %s\n' % curse_id
        if wago_id is not None:
            toc += '## X-Wago-ID: %s\n' % wago_id
        open(os.path.join(d, NAME + '.toc'), 'w').write(toc)
        open(os.path.join(d, 'CHANGELOG.md'), 'w').write('# Changelog\n\n' + ('## %s - notes\n' % tag if changelog else ''))
        git('add', '-A')
        git('-c', 'user.name=t', '-c', 'user.email=t@invalid', 'commit', '-qm', 'one')
        if not on_main:
            git('checkout', '-qb', 'side')
            open(os.path.join(d, 'x'), 'w').write('x')
            git('add', '-A')
            git('-c', 'user.name=t', '-c', 'user.email=t@invalid', 'commit', '-qm', 'two')
        sha = git('rev-parse', 'HEAD').stdout.strip()
        git('update-ref', 'refs/remotes/origin/main', 'main')   # (what actions/checkout leaves for the default branch)
        env = dict(os.environ, CF_API_KEY=cf, WAGO_API_TOKEN=wago, DEFAULT_BRANCH='main',
                   GITHUB_REF_NAME=tag, GITHUB_SHA=sha)
        r = subprocess.run(['bash', '-c', SCRIPT], cwd=d, env=env, capture_output=True, text=True)
        ok = r.returncode == 0
        if ok == expect_ok:
            passed += 1
        else:
            failed += 1
            print('FAIL release check: %s: expected %s, got exit %d %s' % (label, 'pass' if expect_ok else 'fail',
                                                                         r.returncode, (r.stdout + r.stderr).strip()[:200]))
    finally:
        shutil.rmtree(d, ignore_errors=True)


run('a correct release', True)
run('an alpha tag', True, tag='v1.2.0-alpha.1')
run('a beta tag', True, tag='v1.2.0-beta.2')
run('missing CF_API_KEY', False, cf='')
run('missing WAGO_API_TOKEN', False, wago='')
run('no CurseForge project ID', False, curse_id=None)
run('CurseForge project ID 0', False, curse_id='0')
run('no Wago ID', False, wago_id=None)
run('Wago ID 0', False, wago_id='0')
run('tag without the v', False, tag='1.2.0')
run('tag v1.2', False, tag='v1.2')
run('a release-candidate tag', False, tag='v1.2.0-rc1')
run('tagged commit not on the default branch', False, on_main=False)
run('no changelog section for the tag', False, changelog=False)
# --- The packaging step: the packager that ships is the tested one, it gets its
# secrets, it isn't told to skip anything, and its log is checked. ---
WF = open(os.path.join(ROOT, '.github', 'workflows', 'release.yml'), encoding='utf-8').read()
DOCKERFILE = open(os.path.join(ROOT, 'ci', 'Dockerfile'), encoding='utf-8').read()


def static(label, ok):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print('FAIL release check: workflow: ' + label)


def step(name):
    """The text of the step named `name` (up to the next step or job)."""
    m = re.search(r'\n      - name: ' + re.escape(name) + r'\n(.*?)(?=\n      - |\n  [a-z]|\Z)', WF, re.S)
    return m.group(1) if m else ''


uses = re.findall(r'uses:\s*(\S+)', WF)
static('every action is actions/checkout pinned to a full commit SHA (no packager action)',
       uses and all(re.fullmatch(r'actions/checkout@[0-9a-f]{40}', u) for u in uses))
static('no step or job may fail quietly (no continue-on-error)', 'continue-on-error' not in WF)
static('the release job needs the test job', re.search(r'\n  release:\n    needs: test\n', WF) is not None)
static('the release job runs only for pushed v-tags',
       "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')" in WF)
static('the test job passes GITHUB_ACTIONS and runs tests/run.sh',
       re.search(r'docker run --rm (--shm-size=1g )?-e GITHUB_ACTIONS -v "\$PWD:/src:ro" vulcan-test .*sh tests/run.sh', WF) is not None)
pkg = step('Package and upload to CurseForge, Wago and GitHub')
static('the packaging step exists', bool(pkg))
static('the prerequisites are checked before packaging',
       0 <= WF.find('- name: Check release prerequisites') < WF.find('- name: Package and upload'))
static('the release job builds the test container (the pinned packager)',
       WF.count('run: docker build -t vulcan-test ci') == 2)
static('the packaging step runs in bash (so a failing packager fails the pipe)', 'shell: bash' in pkg)
for k, v in (('CF_API_KEY', 'secrets.CF_API_KEY'), ('WAGO_API_TOKEN', 'secrets.WAGO_API_TOKEN'), ('GITHUB_OAUTH', 'secrets.GITHUB_TOKEN')):
    static('the packaging step gets %s from %s' % (k, v), ('%s: ${{ %s }}' % (k, v)) in pkg)
    static('the container gets %s' % k, ('-e %s ' % k) in pkg)
static("release.sh runs with no arguments (nothing like -d or -L that skips uploads)", re.search(r"&& release\.sh'", pkg) is not None)
static('the log is kept', '2>&1 | tee "$RUNNER_TEMP/packager.log"' in pkg)
static('the log is checked', 'python3 tests/check_upload_log.py "$RUNNER_TEMP/packager.log"' in pkg)
static('ci/Dockerfile pins the packager by commit and checksum',
       re.search(r'ARG PACKAGER_COMMIT=[0-9a-f]{40}\n', DOCKERFILE) and re.search(r'ARG PACKAGER_SHA256=[0-9a-f]{64}\n', DOCKERFILE)
       and 'sha256sum -c' in DOCKERFILE)

# --- The upload-log check, on logs shaped like the pinned packager's output. ---
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_upload_log  # noqa: E402

CF = 'Uploading %s-v1.2.0-forever.zip (11604 release) to https://wow.curseforge.com/projects/123456' % NAME
WAGO = 'Uploading %s-v1.2.0-forever.zip (1.60.1 release) to https://addons.wago.io/addons/he54k6bL' % NAME
GH = 'Uploading %s-v1.2.0-forever.zip... Success!' % NAME
GOOD = '\n'.join(['Packaging %s' % NAME, CF, 'Success!', '', WAGO, 'Success!', '', 'Creating GitHub release', GH, 'Uploading release.json... Success!'])


def log_case(label, log, expect_ok):
    global passed, failed
    ok = not check_upload_log.problems(log)
    if ok == expect_ok:
        passed += 1
    else:
        failed += 1
        print('FAIL release check: upload log: %s: expected %s, got %s' % (label, 'pass' if expect_ok else 'fail', check_upload_log.problems(log)))


log_case('every upload succeeded', GOOD, True)
log_case('CRLF line ends', GOOD.replace('\n', '\r\n'), True)
log_case('CurseForge succeeded on a retry', GOOD.replace(CF + '\nSuccess!', CF + '\nError! (500)\n\n' + CF + '\nSuccess!'), True)
log_case('CurseForge skipped', GOOD.replace(CF + '\nSuccess!', 'Skipping upload to CurseForge.'), False)
log_case('CurseForge failed', GOOD.replace(CF + '\nSuccess!', CF + '\nError! (403)'), False)
log_case('CurseForge failed on the last retry', GOOD.replace(CF + '\nSuccess!', CF + '\nSuccess!\n' + CF + '\nError! (500)'), False)
log_case('Wago skipped', GOOD.replace(WAGO + '\nSuccess!', 'Skipping upload to Wago.'), False)
log_case('Wago failed', GOOD.replace(WAGO + '\nSuccess!', WAGO + '\nError! (403)'), False)
log_case("Wago's success belongs to the next upload", GOOD.replace(WAGO + '\nSuccess!', WAGO + '\n' + GH), False)
log_case("CurseForge printed nothing; the next line is Wago's upload and its success",
         GOOD.replace(CF + '\nSuccess!\n', CF + '\n'), False)
log_case('CurseForge fell back to another game version',
         GOOD.replace(CF, 'WARNING: No CurseForge game version match for "1.60.1", using "1.15.7"\n' + CF), False)
log_case('Wago fell back to another game version',
         GOOD.replace(WAGO, 'WARNING: No Wago game version match for "1.60.1", ignoring\n' + WAGO), False)
log_case('no GitHub release asset', GOOD.replace(GH, 'Uploading %s-v1.2.0-forever.zip... Error (422)' % NAME), False)
log_case('an empty log', '', False)

print('release check: %d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
