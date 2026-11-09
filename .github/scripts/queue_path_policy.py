#!/usr/bin/env python3
"""Choose macOS jobs for a merge group, using the complete base-to-head diff.

Only non-Swift files under Wiki/ or site/, Markdown under docs/, and root
Markdown files other than AGENTS.md, CONTRIBUTING.md, CLAUDE.md and
PROJECT-TRAPS.md are eligible to skip. Protected build paths and Swift files
always run the jobs. Empty, unreadable, or unknown changes run the jobs.
Renames count both the old and new paths.
"""

import os
import subprocess
import sys

PROTECTED = ('.github/', 'scripts/', 'BuildSupport/', 'VendorPatches/')
GOVERNANCE = {'AGENTS.md', 'CONTRIBUTING.md', 'CLAUDE.md', 'PROJECT-TRAPS.md'}


def can_skip(paths):
    if not paths:
        return False
    for path in paths:
        if (path.startswith(PROTECTED) or path == 'project.yml'
                or path.lower().endswith('.swift')):
            return False
        if path.startswith(('Wiki/', 'site/')):
            continue
        if path.lower().endswith('.md') and (path.startswith('docs/') or '/' not in path and path not in GOVERNANCE):
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
