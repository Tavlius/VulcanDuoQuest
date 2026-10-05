"""Personal-data guard. Fails if a protected name, an email address or a user's home
path appears in the project: in any file (text, binary or UTF-16, and file names), or
with --history anywhere in the repository's history (every file version ever committed,
file names, commit and tag messages, ref names, and the identities on commits and tags).

The protected names are stored only as SHA-256 hashes, so this file contains none of
them. The scanned text is lowercased and split into words of letters, and every 4 to
12-letter piece of every word is hashed, so a name is caught anywhere inside a longer
word too (a name plus "alt", or "Mr" plus a name).

    python3 tests/guard_personal.py            # the working tree (tracked and new files)
    python3 tests/guard_personal.py --history  # every commit, tag and ref in the repository
    python3 tests/guard_personal.py --history <commit>...  # also these commits (the pre-push
                                               # hook passes what's being pushed, which may be
                                               # a commit no ref points to)
"""
import hashlib
import os
import re
import subprocess
import sys

PROTECTED = {
    '4d30c878c44ec3d52deb0318ae71d9a9b7a91391a46a9d704697570af06426f0',
    '21bcc01cc313acb13d394abed3e3d3fec8112f330057361d35af902d44025c28',
    'e0fecb1c0170c7e1e01bb2754a050ee8d05aaed450093d8bcb6d2470d9d777d9',
    'bbd1b8fe94fcb9b57620efa89297c387f58807ad920dce40558403c9177b6a9a',
    'f108b610ae3b3018a710a0d49ce8edf4b8fb510096c90d50a07cacd1cf8f115d',
    'c04130c1b22d04c90973f337bba9e8fffdfbeb8893fb42f80c8fc9acd04e95bb',
    'd9cd8eab7b2ea26baa104325e4d37f430b7034490de50f9f5d46f52d2d523844',
    'df73d47a85d130334bbc5c7b5622c70c47991ef67f959962736c4c287e0d20f0',
    'd09202bbe00a2491f28b979b524b256b3ee6d296267206930ef23b14fca42f86',
    '6bf2fbe05884bde3dafc0238184221ac1497dca54ed511e1f4943dddcb8e2b89',
    '562a8c8cf283983c56aee27a4f58698e4e80c681622007871b547479d0612f54',
    '40d76283c7aec71e61d56e453b85e57b4b37fb710de7cddd20ced41b219462d1',
    'd23b28d1d3cf9d074a9389160bb2a921ba9c3da4b0590209c262907948a34733',
    'b0b0fd96501f28f8a723a7e0c9a0ddeccd2f146e1c9e724f2ef8b9f0ef63bda6',
    '98e9c99dfe3d922d1b88def7b2b2800d20bd4399286ccaab4977d9bf58eab1c2',
    '4b257d47bbc8f2bf762c7556be1e4920bd70edc44f7ab8c34951303dfa960f52',
    'a0ff241cdd9fc014140b094a6de7e1ac705de0dbdd8615f766fbafce3ba1cc8b',
}
MIN_LEN, MAX_LEN = 4, 12   # (the protected names' lengths fall inside this)
# The owner's one identity on commits and tags (in pieces, so this file has no email in it).
OWNER_EMAIL = '337816587+Tavlius' + '@' + 'users.noreply.github.com'
IDENTITY = 'Tavlius <%s>' % OWNER_EMAIL
# GitHub itself commits web merges and web edits.
GITHUB_COMMITTER = 'GitHub <noreply' + '@' + 'github.com>'
# Anyone else (a contributor) must use their own GitHub noreply address, in either
# form GitHub hands out: <id>+<login> (current) or <login> (older accounts).
NOREPLY = re.compile(r'(?:[0-9]+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com', re.I)
# The email addresses history text may contain (co-author and sign-off trailers): the
# owner's, Anthropic's co-author address, and contributors' GitHub noreply addresses.
HISTORY_EMAILS = {OWNER_EMAIL.lower(), 'noreply' + '@' + 'anthropic.com'}
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')
# A user's home folder: C:\Users\<name>, C:/Users/<name>, /c/Users/<name> (Git Bash),
# /mnt/c/Users/<name> (WSL), /Users/<name> (macOS), /home/<name> (Linux).
USER_PATH = re.compile(r'(?:[a-z]:[\\/]+|(?<![\w.~-])/(?:mnt/[a-z]/|[a-z]/)?)(?:users|home)[\\/]+[^\\/\s"\'<>]', re.I)
WORD = re.compile(r'[a-z]+')
_seen = {}
EXTRA = []   # commits to scan besides every ref (from the command line)
# Read the objects as they really are (and as a push sends them): `git replace` must not
# be able to show the guard a different commit.
os.environ['GIT_NO_REPLACE_OBJECTS'] = '1'


def protected_word(text):
    """The first word in text that holds a protected name, or None."""
    for m in WORD.finditer(text.lower()):
        w = m.group(0)
        if len(w) < MIN_LEN:
            continue
        hit = _seen.get(w)
        if hit is None:
            hit = any(hashlib.sha256(w[i:i + n].encode()).hexdigest() in PROTECTED
                      for n in range(MIN_LEN, min(MAX_LEN, len(w)) + 1) for i in range(len(w) - n + 1))
            _seen[w] = hit
        if hit:
            return w
    return None


def decodings(data):
    """Every reading of a file worth scanning: UTF-8, Latin-1, and UTF-16 if it has NUL bytes."""
    out = [data.decode('utf-8', 'ignore'), data.decode('latin-1')]
    if b'\x00' in data:
        out += [data.decode('utf-16-le', 'ignore'), data.decode('utf-16-be', 'ignore')]
    return out


def noreply_ok(email):
    m = NOREPLY.fullmatch(email)
    return bool(m) and not protected_word(m.group(1))


def problems_in(label, text, emails_ok=frozenset()):
    out = []
    w = protected_word(text)
    if w:
        out.append('%s: a protected name ("%s...")' % (label, w[:2]))
    for m in EMAIL.finditer(text):
        if not (m.group(0).lower() in emails_ok or (emails_ok and noreply_ok(m.group(0)))):
            out.append('%s: an email address' % label)
            break
    if USER_PATH.search(text):
        out.append('%s: a user folder path' % label)
    return out


def problems_in_bytes(label, data, emails_ok=frozenset()):
    for text in decodings(data):
        found = problems_in(label, text, emails_ok)
        if found:
            return found
    return []


def git(*args):
    return subprocess.run(['git'] + list(args), capture_output=True, text=True, errors='replace').stdout


def scan_tree():
    inside = subprocess.run(['git', 'rev-parse', '--git-dir'], capture_output=True).returncode == 0
    if inside:
        files = [f for f in git('ls-files', '-co', '--exclude-standard', '-z').split('\0') if f]
    else:
        files = []
        for dp, dn, fn in os.walk('.'):
            dn[:] = [d for d in dn if d not in ('.git', '.release')]
            files += [os.path.relpath(os.path.join(dp, f), '.').replace(os.sep, '/') for f in fn]
    if len(files) < 5:
        return ['found only %d files to scan' % len(files)]
    problems = []
    for f in files:
        problems += problems_in('file name ' + f, f)
        try:
            data = open(f, 'rb').read()
        except OSError:
            continue
        problems += problems_in_bytes(f, data)
    return problems


def identity_ok(ident, committer=False):
    if ident == IDENTITY or (committer and ident == GITHUB_COMMITTER):
        return True
    m = re.fullmatch(r'(.*) <([^<>]*)>', ident)
    return bool(m and noreply_ok(m.group(2)) and not protected_word(m.group(1)))


def tree_names(body):
    """The entry names in a raw git tree object ("<mode> <name>\\0<20-byte id>" each)."""
    names, i = [], 0
    while i < len(body):
        sp = body.index(b' ', i)
        nul = body.index(b'\0', sp)
        names.append(body[sp + 1:nul].decode('utf-8', 'replace'))
        i = nul + 21
    return names


def history_objects():
    """("blob", path, content) for every file version, and ("tree", folder, entry names)
    for every folder listing, reachable from any ref. The folder listings hold every
    name a file ever had (rev-list records a renamed file's content under one path)."""
    objs = [l.split(' ', 1) for l in git('rev-list', '--all', '--objects', *EXTRA).split('\n') if l.strip()]
    paths = {o[0]: (o[1] if len(o) > 1 else '') for o in objs}
    p = subprocess.run(['git', 'cat-file', '--batch'], input=('\n'.join(paths) + '\n').encode(), capture_output=True)
    data, i = p.stdout, 0
    while i < len(data):
        nl = data.index(b'\n', i)
        sha, kind, size = data[i:nl].decode().split(' ')
        size = int(size)
        body = data[nl + 1:nl + 1 + size]
        i = nl + 1 + size + 1
        if kind == 'blob':
            yield 'blob', paths.get(sha, sha), body
        elif kind == 'tree':
            yield 'tree', paths.get(sha, '') or '(root)', tree_names(body)
        elif kind == 'tag':   # (every tag object, also one reachable only through another tag)
            yield 'tag', sha, body.decode('utf-8', 'replace')


def scan_history():
    if subprocess.run(['git', 'rev-parse', '--git-dir'], capture_output=True).returncode != 0:
        return ['--history needs a git repository']
    if git('rev-parse', '--is-shallow-repository').strip() == 'true':
        return ['the repository is a shallow clone, so its history can\'t be checked (fetch it in full)']
    problems = []
    # Replacements and grafts make git show some commits differently from what a push
    # sends; neither belongs in these repositories.
    if git('for-each-ref', 'refs/replace').strip():
        problems.append('the repository has git replace refs (refs/replace/); remove them')
    if os.path.exists(git('rev-parse', '--git-path', 'info/grafts').strip() or '.git/info/grafts'):
        problems.append('the repository has a grafts file (info/grafts); remove it')
    authors = set(git('log', '--all', *EXTRA, '--format=%an <%ae>').split('\n'))
    authors |= set(git('for-each-ref', 'refs/tags', '--format=%(taggername) %(taggeremail)').split('\n'))
    committers = set(git('log', '--all', *EXTRA, '--format=%cn <%ce>').split('\n'))
    for ident in sorted(i.strip() for i in authors):
        if ident and not identity_ok(ident):   # (a lightweight tag has no tagger: an empty line)
            problems.append('identity not allowed: ' + ident)
    for ident in sorted(i.strip() for i in committers):
        if ident and not identity_ok(ident, committer=True):
            problems.append('committer not allowed: ' + ident)
    # The next commit's identity: this repository's own setting, never the machine's.
    # (Not on CI, which only reads the history.)
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        name, email = git('config', 'user.name').strip(), git('config', 'user.email').strip()
        if '%s <%s>' % (name, email) != IDENTITY:
            problems.append('git user.name/user.email for this repository must be ' + IDENTITY
                            + ' (set them with git config, without --global)')
    texts = {
        'commit messages': git('log', '--all', *EXTRA, '--format=%B'),
        'tags': git('for-each-ref', 'refs/tags', '--format=%(refname) %(contents)'),
        'ref names': git('for-each-ref', '--format=%(refname)'),
    }
    for label, text in texts.items():
        problems += problems_in('history (%s)' % label, text, HISTORY_EMAILS)
    # Every version of every file ever committed (binary and UTF-16 ones too), and every
    # name any file or folder ever had.
    n = 0
    for kind, path, body in history_objects():
        if kind == 'tag':
            head, _, message = body.partition('\n\n')
            m = re.search(r'^tagger (.*?) (\d+ [+-]\d{4})$', head, re.M)
            if m and not identity_ok(m.group(1).strip()):
                problems.append('identity not allowed: %s (tagger of tag object %s)' % (m.group(1).strip(), path[:10]))
            tagname = re.search(r'^tag (.*)$', head, re.M)
            problems += problems_in('history (tag object %s)' % path[:10], message + '\n' + (tagname.group(1) if tagname else ''), HISTORY_EMAILS)
            continue
        if kind == 'tree':
            for entry in body:
                problems += problems_in('history (a name in %s: %s)' % (path, entry), entry)
            continue
        n += 1
        problems += problems_in('history (file name %s)' % path, path)
        problems += problems_in_bytes('history (%s)' % path, body)
    if n == 0:
        problems.append('history: no committed files found to scan')
    return problems


def main():
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    history = '--history' in sys.argv
    for a in sys.argv[1:]:
        if a != '--history':
            if not re.fullmatch(r'[0-9a-f]{40}([0-9a-f]{24})?', a):
                print('FAIL personal-data guard: not a commit id: ' + a[:60])
                sys.exit(1)
            EXTRA.append(a)
    problems = scan_history() if history else scan_tree()
    if problems:
        for p in sorted(set(problems))[:40]:
            print('FAIL personal-data guard: ' + p)
        sys.exit(1)
    print('personal-data guard: clean' + (' (history)' if history else ''))


if __name__ == '__main__':
    main()
