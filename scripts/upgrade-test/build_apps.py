#!/usr/bin/env python3
"""Build optimized upgrade apps in separate source and SDK scratch directories."""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import quote

from journey import JourneyError

PAYLOAD = [
    'ProtonAuth/UpgradeTestSessionFile.swift', 'PhotosCore/UpgradeTestProbe.swift', 'ProtonDriveBackend/UpgradeTestBackend.swift',
    'PhotoLibraryBackupAdapter/UpgradeTestPhotoLibrary.swift', 'MLSearchAppleAdapter/UpgradeTestSmartSearch.swift',
]
FLAG = 'ENCRYPTED_MEMORIES_UPGRADE_TEST'


@dataclass(frozen=True)
class Build:
    app: Path
    source: Path | None
    metadata: dict | None = None
    commit: str | None = None


def clean_environment():
    environment = {key: value for key, value in os.environ.items()
                   if key in {'HOME', 'USER', 'PATH', 'DEVELOPER_DIR', 'TMPDIR', 'LANG', 'LC_ALL'}}
    # A stalled Git transfer must fail rather than hold the release or local build queue indefinitely.
    environment.update(GIT_HTTP_LOW_SPEED_LIMIT='1', GIT_HTTP_LOW_SPEED_TIME='120')
    return environment


def command(args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env or clean_environment(), check=True)


def output(args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env or clean_environment(), text=True).strip()


def release_metadata(repo, automation, tag):
    sha = output(['git', 'rev-parse', '--verify', '--end-of-options', tag + '^{commit}'], repo)
    if not tag.startswith('v'):
        tags = [value for value in output(['git', 'tag', '--points-at', sha], repo).splitlines() if value.startswith('v')]
        if len(tags) != 1:
            raise JourneyError('The candidate needs an explicit release tag; no unique tag matches its commit')
        tag = tags[0]
    environment = clean_environment()
    if os.environ.get('GH_TOKEN'):
        environment['GH_TOKEN'] = os.environ['GH_TOKEN']
    try:
        payload = json.loads(output(['gh', 'api', 'repos/{owner}/{repo}/releases/tags/' + quote(tag, safe='')],
                                    repo, env=environment))
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        raise JourneyError(f'{tag}: no readable published GitHub release for this tag') from error
    if not isinstance(payload, dict) or payload.get('tag_name') != tag:
        raise JourneyError(f'{tag}: the published GitHub release does not match this tag')
    if payload.get('draft') is not False or not payload.get('published_at'):
        raise JourneyError(f'{tag}: not a published GitHub release')
    result = subprocess.run(['ruby', str(automation / '.github/scripts/release_identity.rb'), sha],
                            input=json.dumps(payload), cwd=repo, env=clean_environment(),
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise JourneyError(f'{tag}: {result.stderr.strip()}')
    return json.loads(result.stdout)


def verify_bundle_metadata(app, platform, release, stage):
    path = app / ('Info.plist' if platform == 'iOS' else 'Contents/Info.plist')
    try:
        info = plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as error:
        raise JourneyError(f'{release["tag"]}: unreadable {stage} bundle metadata') from error
    expected = {'CFBundleShortVersionString': release['version'], 'CFBundleVersion': release['build_number']}
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != 'at.oncloud.encryptedmemories.upgrade-test':
        raise JourneyError(f'{release["tag"]}: {stage} bundle does not have the test identifier')
    for key, value in expected.items():
        if type(info.get(key)) is not str or info[key] != value:
            raise JourneyError(f'{release["tag"]}: {stage} {key} must equal {value!r}; got {info.get(key)!r}')
    return {key: info[key] for key in expected}


def harness_digest(automation):
    files = [automation / name for name in ['scripts/upgrade-test/build_apps.py',
             '.github/scripts/release_identity.rb', '.github/scripts/release_build_number.rb']]
    files += list((automation / 'scripts/upgrade-test/overlays').rglob('*'))
    files += [automation / 'Packages/EncryptedMemoriesKit/Sources' / name for name in PAYLOAD]
    digest = hashlib.sha256()
    for path in sorted(files):
        if path.is_file() and '__pycache__' not in path.parts:
            digest.update(str(path.relative_to(automation)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def _take_interpolation(text, paren_index):
    """Return `(expression, end_index)` for the interpolation whose opening parenthesis
    sits at `paren_index` (a '(' character). The expression can contain nested strings,
    raw strings, comments and balanced parentheses; string contents are not code and the
    caller drops them. `end_index` is None when the interpolation never closes: the
    caller reports the file as unscannable."""
    cursor = paren_index + 1
    depth = 1
    block_depth = 0
    length = len(text)
    while cursor < length:
        char = text[cursor]
        nxt = text[cursor + 1] if cursor + 1 < length else ''
        if block_depth:
            if char == '/' and nxt == '*':
                block_depth += 1
                cursor += 2
            elif char == '*' and nxt == '/':
                block_depth -= 1
                cursor += 2
            else:
                cursor += 1
            continue
        if char == '/' and nxt == '*':
            block_depth = 1
            cursor += 2
            continue
        if char == '/' and nxt == '/':
            cursor = text.find('\n', cursor)
            if cursor < 0:
                return '', None
            continue
        if char == '"':
            # A raw string opens with the hashes that immediately precede the quote.
            hashes = 0
            while cursor - 1 - hashes >= 0 and text[cursor - 1 - hashes] == '#':
                hashes += 1
            if hashes:
                inner = _take_raw_string(text, cursor, hashes)
                if inner is None:
                    return '', None
                cursor = inner
                continue
            if text.startswith('"""', cursor):
                cursor = _take_multiline_string(text, cursor)
                if cursor is None:
                    return '', None
                continue
            inner_end = _take_simple_string(text, cursor)
            if inner_end is None:
                return '', None
            cursor = inner_end
            continue
        if char == '(':
            depth += 1
            cursor += 1
            continue
        if char == ')':
            depth -= 1
            if depth == 0:
                return text[paren_index + 1:cursor], cursor + 1
            cursor += 1
            continue
        cursor += 1
    return '', None


def _take_simple_string(text, index):
    """Consume a double-quoted string starting at `index`; return the end index (past the
    closing quote) or None when unterminated."""
    cursor = index + 1
    length = len(text)
    while cursor < length and text[cursor] != '"':
        if text[cursor] == '\\' and cursor + 1 < length:
            cursor += 2
        else:
            cursor += 1
    if cursor >= length:
        return None
    return cursor + 1


def _take_multiline_string(text, index):
    """Consume a triple-quoted string starting at `index`; return the end index (past the
    closing triple quote) or None when unterminated. Backslash escapes are consumed, so
    a \\"" sequence does not close the string."""
    cursor = index + 3
    length = len(text)
    while cursor < length and not text.startswith('"""', cursor):
        if text[cursor] == '\\' and cursor + 1 < length:
            cursor += 2
        else:
            cursor += 1
    if cursor >= length:
        return None
    return cursor + 3


def _take_raw_string(text, quote_index, hashes, collect=None):
    """Consume a raw string whose opening delimiter sits at `quote_index` with `hashes`
    leading '#'; return the end index (past the closing hashes) or None when unterminated.
    One scanner serves the file top level, interpolations and multi-line strings: n hashes
    followed by one quote open a single-line string that closes on any quote followed by
    exactly the same hash count; a single-line raw string must not span a newline: the
    scan stops closed at a newline, because a Swift single-line raw literal cannot hold
    one, so unterminated or newline-spanning input fails the file closed. n hashes
    followed by three quotes open a multi-line string that closes on three quotes plus
    the same hash count at the start of a line after optional blanks. Inside a
    single-line string every quote not followed by the hash count is content, so
    #"a""# closes on the second quote. Backslash escapes do not apply; only backslash
    plus the same hash count plus '(' interpolates, reported to the optional `collect`
    callback (expression, close_index) which returns False when the expression is
    unscannable."""
    length = len(text)
    multiline = text.startswith('"""', quote_index)
    cursor = quote_index + (3 if multiline else 1)
    marker = '\\' + '#' * hashes + '('
    closer = '"""' + '#' * hashes
    while cursor < length:
        if text.startswith(marker, cursor):
            expression, close = _take_interpolation(text, cursor + 1 + hashes)
            if close is None:
                return None
            if collect is not None and not collect(expression, close):
                return None
            cursor = close
            continue
        if multiline:
            if text.startswith(closer, cursor):
                line_start = text.rfind('\n', 0, cursor) + 1
                if not text[line_start:cursor].strip():
                    return cursor + 3 + hashes
        elif text[cursor] == '\n':
            # A Swift single-line raw literal cannot hold a newline. Stop closed so an
            # unterminated or newline-spanning raw string fails the file closed instead
            # of hiding the names that follow.
            return None
        elif text[cursor] == '"':
            if text[cursor + 1:cursor + 1 + hashes] == '#' * hashes:
                return cursor + 1 + hashes
        cursor += 1
    return None


def unbuildable_names(source, tag, payload=PAYLOAD, git_repo=None):
    """Return the candidate test-entry names that this release's sources cannot provide.

    A source without its own test entry receives the candidate's five payload files. A
    name compiles only when the release defines it, another payload file declares it, or
    a framework supplies it. The hosted failures of run 45890080546 came from names
    added after v1.0.5 shipped.

    The scan is a heuristic: it sees capitalized root names, bare capitalized identifiers,
    and members reached through a capitalized name or a closing parenthesis
    (`Capitalized.member`, `).member`). It does not see implicit members, members of a
    lowercase receiver, or argument labels; a payload file can still fail to compile
    through those. The local rehearsal is the proof that a release builds, not this
    scan. Comments and string literals carry no compiler meaning; interpolated
    expressions inside strings are scanned (including strings nested inside an
    interpolation). Raw strings, multi-line strings, nested block comments and directive
    lines are handled. A file the lexer cannot tokenize (unterminated string,
    interpolation or block comment) is an error naming that file, never a silent pass.
    Call this after the overlay installed the payload files. `git_repo` is the git
    checkout whose history holds the tagged release; the extracted source has none.
    """
    framework_roots = {'FileManager', 'ProcessInfo', 'URLProtocol', 'URLSession', 'JSONSerialization',
                       'Task', 'Insecure', 'SHA1', 'SHA256', 'Data', 'Int', 'Int64', 'Double', 'Bool', 'URL'}
    framework_members = {'registerClass'}
    exemptions = {'self', 'init', 'some', 'utf8'}
    # Preprocessor conditions are not Swift names: drop whole directive lines before scanning.
    compile_conditions = {'ENCRYPTED_MEMORIES_UPGRADE_TEST'}

    def strip(text):
        """One left-to-right pass over the file; every state below either keeps code or
        drops non-code. Returns the scan text plus the interpolated expressions.

        States: code, line comment (ends at newline), block comment (nesting counted),
        string (double-quoted), multi-line string, raw string. One raw-string scanner
        (_take_raw_string) serves the file top level, interpolations and multi-line
        strings: n hashes plus one quote open a single-line raw string closed by any
        quote plus the same hash count, and n hashes plus three quotes open a raw
        multi-line string closed by three quotes plus the same hash count at the start
        of a line after optional blanks. Conditional-compilation directive lines
        (#if/#elseif/#else/#endif) are dropped only in code state, at the start of a
        line after optional blanks, so a directive-looking line inside a multi-line
        string stays string content; only the directive token and its condition are
        dropped, so a block or line comment opener that follows keeps its meaning.
        Backslash escapes are consumed inside strings, including multi-line strings; a
        \\"" inside a multi-line string does not close it. In a raw string with n
        delimiter hashes, only backslash plus n hashes plus '(' interpolates (SE-0200);
        a plain \\( is literal text. An interpolation holds balanced parentheses and can
        itself contain strings, raw strings, raw multi-line strings and comments; its
        collected expression is lexed again so nested string contents carry no names.
        Unterminated strings, interpolations and block comments are not
        Swift-compilable input; strip returns None so the caller reports that file as
        unscannable.

        Not covered: regex literals. An extended regex literal (#/…/# with matching hash
        counts) containing '//' opens a line comment in this scan, so names between the
        literal and the end of that line can hide; containing an unescaped '/*' opens a
        block comment that swallows names until a real '*/' (which may sit inside the
        literal's own content, making the net effect row-dependent). A regex literal
        containing a quote character reads as a string opening and can fail the file
        closed. An escaped slash before a slash (`\\//`) also reads as '//' and hides
        the names after it on that line. Content without '//' and '/*' does not hide
        the names after the literal, but the scan reads the content of a regex literal
        as code, so a capitalized word inside it is reported as a missing name: the
        file fails closed, never silently passes. These rows pin the documented
        behavior: a future regex-aware fix must flip the hiding rows deliberately. The
        heuristic name scan itself sees only capitalized names, bare capitalized
        identifiers, and `Capitalized.member` / `).member` forms (see
        unbuildable_names).
        """
        code = []
        interpolated = []
        index, length = 0, len(text)
        block_depth = 0
        at_line_start = True
        hash_run = 0  # Number of '#' before an opening quote of a raw string.

        def collect(expression, close):
            # Lex the interpolation expression again: its string contents are text and
            # its own interpolations stay in the scan. Returns False when the expression
            # is not scannable.
            inner, inner_interpolated = strip(expression)
            if inner is None:
                return False
            interpolated.append(inner)
            interpolated.extend(inner_interpolated)
            return True

        while index < length:
            char = text[index]
            nxt = text[index + 1] if index + 1 < length else ''
            if block_depth:
                if char == '/' and nxt == '*':
                    block_depth += 1
                    index += 2
                elif char == '*' and nxt == '/':
                    block_depth -= 1
                    index += 2
                else:
                    index += 1
                continue
            if char == '/' and nxt == '*':
                block_depth = 1
                index += 2
                continue
            if at_line_start:
                # A directive line starts with optional blanks, then #if/#elseif/#else/#endif.
                # The check runs only in code state: directive-looking lines inside
                # comments or strings keep their meaning. Only the directive token and its
                # condition are dropped; a block or line comment opener that follows on the
                # line keeps its meaning, so #if DEBUG /* opens a comment that spans lines.
                # The newline stays so line tracking holds.
                directive = re.match(r'[ \t]*#[ \t]*(?:if|elseif|else|endif)\b', text[index:])
                if directive:
                    line_end = text.find('\n', index)
                    if line_end < 0:
                        line_end = length
                    cursor = index + directive.end()
                    comment_start = None
                    while cursor < line_end:
                        if text[cursor] == '"':
                            cursor += 1
                            while cursor < line_end and text[cursor] != '"':
                                cursor += 2 if text[cursor] == '\\' else 1
                            cursor += 1
                            continue
                        if text.startswith('/*', cursor) or text.startswith('//', cursor):
                            comment_start = cursor
                            break
                        cursor += 1
                    index = line_end if comment_start is None else comment_start
                    continue
            if char == '/' and nxt == '/':
                index = text.find('\n', index)
                if index < 0:
                    break
                continue
            hash_run = hash_run + 1 if char == '#' else 0
            if hash_run and nxt == '"':
                # Raw string literal, single-line or multi-line: the single scanner
                # decides by the quote count after the hashes, so a plain \( marker is
                # literal text and only backslash plus the same hash count interpolates
                # (SE-0200).
                index = _take_raw_string(text, index + 1, hash_run, collect)
                if index is None:
                    return None, None
                code.append(' ')
                continue
            if char == '"':
                # Regular string or multi-line string; both consume escapes and collect
                # interpolations. A lone """ on one line is multi-line opening.
                if text.startswith('"""', index):
                    index += 3
                    while index < length and not text.startswith('"""', index):
                        if text.startswith('\\(', index):
                            expression, close = _take_interpolation(text, index + 1)
                            if close is None or not collect(expression, close):
                                return None, None
                            index = close
                        elif text[index] == '\\' and index + 1 < length:
                            index += 2
                        else:
                            index += 1
                    if index >= length:
                        return None, None
                    index += 3
                else:
                    index += 1
                    while index < length and text[index] != '"':
                        if text.startswith('\\(', index):
                            expression, close = _take_interpolation(text, index + 1)
                            if close is None or not collect(expression, close):
                                return None, None
                            index = close
                        elif text[index] == '\\' and index + 1 < length:
                            index += 2
                        else:
                            index += 1
                    if index >= length:
                        return None, None
                    index += 1
                code.append(' ')
                continue
            code.append(char)
            index += 1
            at_line_start = char == '\n'
        if block_depth:
            return None, None
        return ''.join(code), interpolated

    def grep(word):
        result = subprocess.run(['git', 'grep', '-qw', '-e', word, tag, '--',
                                 'Packages/EncryptedMemoriesKit/Sources'],
                                cwd=git_repo or source, capture_output=True)
        if result.returncode in (0, 1):
            return result.returncode == 0
        detail = result.stderr.decode('utf-8', 'replace').strip() or f'exit {result.returncode}'
        raise JourneyError(f'Cannot read the tagged sources of {tag} for the test-entry guard: {detail}. '
                           f'The git history that holds {tag} must be reachable from the automation checkout.')

    texts = {}
    declared = set()
    for relative in payload:
        path = source / 'Packages/EncryptedMemoriesKit/Sources' / relative
        if not path.is_file():
            continue
        stripped, interpolated = strip(path.read_text())
        if stripped is None:
            raise JourneyError(
                f'{tag}: {relative} is not valid Swift the test-entry guard can scan '
                '(an unterminated string, interpolation or block comment). '
                'Pin the file to the commit whose bytes it must keep.')
        code = stripped + ('' if not interpolated else '\n' + '\n'.join(interpolated))
        texts[relative] = code
        declared |= set(re.findall(r'\b(?:func|var|let|case|associatedtype|class|struct|enum|protocol|actor|typealias)\s+(\w+)', code))
    unknown = {}
    for relative, text in texts.items():
        roots = set(re.findall(r'\b([A-Z]\w*)\s*\.', text))
        # A bare capitalized name (constructor, cast, conformance, metatype) compiles only
        # when the release defines it too. The run 45890080546 failure class includes names
        # that never take a member.
        bare = set(re.findall(r'(?<![\w.])\b([A-Z]\w*)\b(?!\s*\.)', text))
        members = set(re.findall(r'(?:\b[A-Z]\w*|\))\s*\.\s*([a-z]\w*)', text))
        bad_roots = {root for root in roots if root not in framework_roots and root not in declared and not grep(root)}
        bad_bare = {word for word in bare if word not in framework_roots and word not in compile_conditions
                    and word not in declared and not grep(word)}
        bad_members = {member for member in members if member not in exemptions
                       and member not in framework_members and member not in declared and not grep(member)}
        bad = bad_roots | bad_bare | bad_members
        if bad:
            unknown[relative] = sorted(bad)
    return unknown


def source_tree(repo, sha, destination, working_copy=False):
    destination.mkdir(parents=True)
    archive = destination.parent / 'source.tar'
    command(['git', 'archive', '-o', str(archive), sha], cwd=repo)
    with tarfile.open(archive) as tree:
        tree.extractall(destination, filter='data')
    archive.unlink()
    if working_copy:
        # Rehearsal only. CI always extracts the exact release commit.
        patch = subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=repo)
        if patch:
            subprocess.run(['git', 'apply', '-'], input=patch, cwd=destination, check=True)
        for relative in output(['git', 'ls-files', '--others', '--exclude-standard'], repo).splitlines():
            source = repo / relative
            if source.is_file():
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)


def apply_overlay(source, automation, tag, sha):
    manifest = json.loads((automation / 'scripts/upgrade-test/overlays/versions.json').read_text())
    sentinel = source / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'
    # A release with its own test entry needs an overlay only when its tag has a reviewed one.
    has_test_entry = sentinel.exists()
    # A pinned test-entry file is used only for a release without its own entry, and only for a PAYLOAD path.
    pinned = automation / 'scripts/upgrade-test/overlays' / (tag + '.payload')
    pinned_files = sorted(str(path.relative_to(pinned)) for path in pinned.rglob('*') if path.is_file())
    if pinned_files and has_test_entry:
        raise JourneyError(f'{tag}: pinned test-entry files for a release that has its own test entry')
    if set(pinned_files) - set(PAYLOAD):
        raise JourneyError(f'{tag}: pinned file outside the test-entry payload: {sorted(set(pinned_files) - set(PAYLOAD))}')
    if has_test_entry and tag not in manifest:
        return
    if tag not in manifest or manifest[tag]['commit'] != sha:
        raise JourneyError(f'{tag}: no reviewed overlay for commit {sha}')
    patch = automation / 'scripts/upgrade-test/overlays' / (tag + '.patch')
    command(['git', 'apply', '--check', '--unidiff-zero', str(patch)], cwd=source)
    command(['git', 'apply', '--unidiff-zero', str(patch)], cwd=source)
    if has_test_entry:
        return
    # The release's own protocols decide what a test file may use. A pinned file replaces the candidate's
    # when the candidate's file needs a type that this release does not have (v1.0.5: UploadNetworkReservation).
    for relative in PAYLOAD:
        target = source / 'Packages/EncryptedMemoriesKit/Sources' / relative
        candidate = automation / 'Packages/EncryptedMemoriesKit/Sources' / relative
        shutil.copy2(pinned / relative if (pinned / relative).is_file() else candidate, target)
    unbuildable = unbuildable_names(source, tag, git_repo=automation)
    if unbuildable:
        listed = '; '.join(f'{relative}: {", ".join(names)}' for relative, names in sorted(unbuildable.items()))
        raise JourneyError(f'{tag}: candidate test files use names that this release does not provide. '
                           f'Pin the named files to the commit whose bytes they must keep: {listed}')


def test_project(source, automation, platform):
    project = source / 'project.yml'
    text = project.read_text()
    shipping_id = 'PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories\n'
    if text.count(shipping_id) != 2 or FLAG in text:
        raise JourneyError('The source must retain the ordinary archive configuration')
    text = text.replace(shipping_id, 'PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.upgrade-test\n')
    ui = source / 'UpgradeUITests'
    ui.mkdir()
    shutil.copytree(automation / 'scripts/upgrade-test/UITests', ui, dirs_exist_ok=True)
    target = f'''  UpgradeJourneyUITests:
    type: bundle.ui-testing
    platform: {platform}
    deploymentTarget: "26.0"
    sources:
      - UpgradeUITests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.upgrade-test.runner
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_IDENTITY: "-"

'''
    text = text.replace('schemes:\n', target + 'schemes:\n', 1)
    text += '''
  UpgradeJourney:
    build:
      targets:
        UpgradeJourneyUITests: [test]
    test:
      config: Release
      targets:
        - UpgradeJourneyUITests
'''
    project.write_text(text)
    for relative in ['App/Info.plist', 'iOSApp/Info.plist']:
        path = source / relative
        value = plistlib.loads(path.read_bytes())
        value['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True,
            'NSExceptionDomains': {'127.0.0.1': {'NSExceptionAllowsInsecureHTTPLoads': True}}}
        path.write_bytes(plistlib.dumps(value))


def build_app(repo, automation, tag, platform, root, historical=True, working_copy=False, metadata=None):
    sha = output(['git', 'rev-parse', tag + '^{commit}'], repo)
    metadata = metadata or release_metadata(repo, automation, tag)
    if metadata['commit'] != sha and not working_copy:
        raise JourneyError(f'{tag}: the source commit does not match published release {metadata["tag"]}')
    toolchain = output(['xcodebuild', '-version'])
    identity = hashlib.sha256((sha + toolchain + platform + output(['uname', '-m'])
                               + harness_digest(automation) + json.dumps(metadata, sort_keys=True)).encode()).hexdigest()
    if working_copy:
        app_paths = ['App', 'iOSApp', 'Shared', 'Packages', 'project.yml',
                     'scripts/update-proton-sdk.sh', 'scripts/build-paths.sh']
        digest = hashlib.sha256(subprocess.check_output(['git', 'diff', '--binary', 'HEAD', '--', *app_paths], cwd=repo))
        for relative in output(['git', 'ls-files', '--others', '--exclude-standard', '--', *app_paths], repo).splitlines():
            path = repo / relative
            if path.is_file():
                digest.update(relative.encode())
                digest.update(path.read_bytes())
        identity = hashlib.sha256((identity + digest.hexdigest()).encode()).hexdigest()
    product = root / 'products' / platform / identity
    if (product / 'complete.json').exists():
        cached = json.loads((product / 'complete.json').read_text())
        app = product / cached['app']
        if cached['identity'] != identity or cached.get('commit') != sha or cached.get('release') != metadata or not app.is_dir():
            raise JourneyError(f'{tag}: invalid historical app cache')
        verify_bundle_metadata(app, platform, metadata, 'cached')
        source = Path(cached['source']) if cached.get('source') else None
        if historical or (source and source.is_dir()):
            return Build(app, None if historical else source, metadata, sha)
    scratch = Path(tempfile.mkdtemp(prefix=f'{tag.replace("/", "_")}-{platform}-', dir=root / 'scratch'))
    source = scratch / 'source'
    source_tree(repo, sha, source, working_copy=working_copy)
    apply_overlay(source, automation, tag, sha)
    test_project(source, automation, platform)
    env = clean_environment()
    env.update(ENCRYPTED_MEMORIES_BUILD_ROOT=str(scratch / 'build'),
               DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
    # Each tag runs its own SDK restore script with its own default pin and scratch.
    command(['bash', 'scripts/update-proton-sdk.sh'], cwd=source, env=env)
    command(['xcodegen', 'generate'], cwd=source, env=env)
    command(['bash', '-c', 'source scripts/build-paths.sh; encryptedmemories_pin_generated_project_packages "$PWD"'], cwd=source, env=env)
    sdk = 'iphonesimulator' if platform == 'iOS' else 'macosx'
    scheme = 'EncryptedMemoriesMobile' if platform == 'iOS' else 'EncryptedMemories'
    destination = 'generic/platform=iOS Simulator' if platform == 'iOS' else 'platform=macOS'
    dd = scratch / 'build/DerivedData.noindex'
    command(['xcrun', 'xcodebuild', '-resolvePackageDependencies',
             '-project', 'EncryptedMemories.xcodeproj', '-scheme', scheme,
             '-clonedSourcePackagesDirPath', str(scratch / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(scratch / 'build/XcodePackageCache.noindex'),
             '-onlyUsePackageVersionsFromResolvedFile'], cwd=source, env=env)
    signing = ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-'] if platform == 'iOS' else ['CODE_SIGNING_ALLOWED=NO']
    command(['xcrun', 'xcodebuild', 'build', '-project', 'EncryptedMemories.xcodeproj',
             '-scheme', scheme, '-configuration', 'Release', '-sdk', sdk, '-destination', destination,
             '-derivedDataPath', str(dd), '-clonedSourcePackagesDirPath', str(scratch / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(scratch / 'build/XcodePackageCache.noindex'),
             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
             '-skipPackagePluginValidation', '-skipMacroValidation',
             *signing, 'MARKETING_VERSION=' + metadata['version'],
             'CURRENT_PROJECT_VERSION=' + metadata['build_number'],
             'SWIFT_ACTIVE_COMPILATION_CONDITIONS=' + FLAG,
             'SWIFT_OPTIMIZATION_LEVEL=-O', 'ARCHS=' + output(['uname', '-m']), 'ONLY_ACTIVE_ARCH=YES'], cwd=source, env=env)
    built = dd / 'Build/Products' / ('Release-iphonesimulator' if platform == 'iOS' else 'Release')
    apps = [path for path in built.glob('*.app') if 'Runner' not in path.name]
    if len(apps) != 1:
        raise JourneyError(f'{tag}: expected one built app, found {len(apps)}')
    verify_bundle_metadata(apps[0], platform, metadata, 'built')
    app = publish_product(apps[0], product, {'identity': identity, 'commit': sha, 'app': apps[0].name,
                                             'source': str(source) if not historical else None, 'release': metadata})
    if historical:
        # A historical journey needs only its published app. Its source, SDK and derived data take several GiB on
        # a hosted runner whose disk also holds every case's Simulator.
        shutil.rmtree(scratch)
        return Build(app, None, metadata, sha)
    return Build(app, source, metadata, sha)


def publish_product(built, product, record):
    """Only finished products enter the historical cache. Source, SDK and partial builds remain separate."""
    # A restored cache can already hold this product without its source, so the candidate is rebuilt. Copying over
    # it fails on the framework symlinks of a macOS bundle; replace the old copy, and mark it complete only after.
    product.mkdir(parents=True, exist_ok=True)
    (product / 'complete.json').unlink(missing_ok=True)
    app = product / built.name
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(built, app, symlinks=True)
    (product / 'complete.json').write_text(json.dumps(record) + '\n')
    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--automation', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--platform', choices=['iOS', 'macOS'], required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--working-copy', action='store_true')
    parser.add_argument('--release-tag', help='Published metadata for the candidate; required when its commit has no unique tag')
    args = parser.parse_args()
    (args.root / 'scratch').mkdir(parents=True, exist_ok=True)
    print(build_app(args.repo.resolve(), args.automation.resolve(), args.tag, args.platform,
                    args.root.resolve(), historical=not args.working_copy, working_copy=args.working_copy,
                    metadata=release_metadata(args.repo.resolve(), args.automation.resolve(), args.release_tag or args.tag)).app)
