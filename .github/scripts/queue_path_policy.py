"""Choose macOS jobs for a merge group, using the complete base-to-head diff.

Only non-Swift files under Wiki/ or site/ and exactly README.md or
SECURITY.md are eligible to skip. Every other path runs all macOS jobs.
Empty or unreadable diffs run all macOS jobs.
Renames count both the old and new paths.
"""

import os
import subprocess

def can_skip(paths):
    if not paths:
        return False
    for path in paths:
        if path.lower().endswith('.swift'):
            return False
        if path.startswith(('Wiki/', 'site/')) or path in {'README.md', 'SECURITY.md'}:
            continue
        return False
    return True


def main():
    try:
        diff = subprocess.run(
            ['git', 'diff', '--no-renames', '--name-only', '-z', os.environ['BASE_SHA'], os.environ['HEAD_SHA'], '--'],
            check=True, stdout=subprocess.PIPE,
        ).stdout
        paths = [os.fsdecode(path) for path in diff.split(b'\0') if path]
        skip = can_skip(paths)
    except (KeyError, OSError, subprocess.CalledProcessError):
        skip = False
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(f'run_macos={str(not skip).lower()}\n')
    print('skipped by policy' if skip else 'macOS jobs required')


if __name__ == '__main__':
    main()
