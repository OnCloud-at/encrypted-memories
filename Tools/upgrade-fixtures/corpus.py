#!/usr/bin/env python3
"""Pack unchanged historical snapshots. Read SQLite only in disposable copies."""
import argparse
import base64
import gzip
import hashlib
import io
import json
import re
import shutil
import sqlite3
import tarfile
import tempfile
from pathlib import Path

BUDGET = 15_000_000
SCENARIOS = ('backup', 'model', 'index', 'cache', 'location')
PRIVATE = re.compile(rb'/Users/|/home/[a-z]|/Volumes/|/private/|/var/folders/|file://|[.]ts[.]net|[.]lan\b|[A-Za-z0-9_-]+\.local\b|(?:192\.168|10\.\d+|172\.(?:1[6-9]|2\d|3[01])|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d+\.\d+')

def check_bytes(data, label, strict_issues=False):
    if PRIVATE.search(data):
        raise ValueError('Private path or hostname in ' + label)
    for encoded in re.findall(rb'encryptedmemories-backup-issue-v1:([A-Za-z0-9+/]+={0,2})', data):
        if not strict_issues:
            # A raw SQLite page can end inside a value. Decode every complete prefix.
            encoded = encoded.rstrip(b'=')
            if len(encoded) % 4 == 1:
                encoded = encoded[:-1]
            encoded += b'=' * (-len(encoded) % 4)
        check_bytes(base64.b64decode(encoded, validate=True), label + ' decoded backup issue')

def network_retry(value):
    prefix = 'encryptedmemories-backup-issue-v1:'
    if not value.startswith(prefix):
        return False
    record = json.loads(base64.b64decode(value[len(prefix):], validate=True))
    return record.get('kind') == 'network' and record.get('automaticRetryAttempt', 0) > 0

def rows(directory, name, sql=None):
    source = directory / name
    if not source.exists() or source.stat().st_size == 0:
        return []
    with tempfile.TemporaryDirectory(prefix='upgrade-oracle-') as temporary:
        copy = Path(temporary) / name
        copy.parent.mkdir(parents=True, exist_ok=True)
        for suffix in ('', '-wal', '-shm'):
            sidecar = Path(str(source) + suffix)
            if sidecar.exists():
                shutil.copyfile(sidecar, Path(str(copy) + suffix))
        with sqlite3.connect(copy) as db:
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
            if not tables:
                return []
            # Scan every recovered table value, not only printable strings in the file container.
            for table in tables:
                quoted = '"' + table.replace('"', '""') + '"'
                for row in db.execute('SELECT * FROM ' + quoted):
                    for value in row:
                        if isinstance(value, str):
                            check_bytes(value.encode(), name + ' SQLite text', strict_issues=True)
                        elif isinstance(value, bytes):
                            check_bytes(value, name + ' SQLite blob')
            if sql is None:
                return []
            table = re.search(r'FROM ([a-z_]+)', sql).group(1)
            return list(db.execute(sql)) if table in tables else []

def safe_rows(tree, name, unreadable, sql):
    return [] if name in unreadable else rows(tree, name, sql)

def pack(recorded, destination):
    blobs = {}
    manifest = dict(format=1, **json.loads((recorded.parent / 'recording.json').read_text()), scenarios={})
    for scenario in SCENARIOS:
        folder = recorded / scenario
        events = [json.loads(line) for line in (folder / 'events.jsonl').read_text().splitlines()]
        atomic_targets = {}
        atomic_helpers = {}
        for event in events:
            source = event.get('source')
            target = event['path'].lstrip('/')
            completed = folder / f"{event['id']:06d}" / target
            if source and completed.is_file():
                digest = hashlib.sha256(completed.read_bytes()).hexdigest()
                atomic_targets.setdefault(target, set()).add(digest)
                atomic_helpers[source.lstrip('/')] = target
        atomic_targets = {target: sorted(digests) for target, digests in atomic_targets.items()}
        # A journal can be atomically created and then intentionally appended in place.
        mutable_after = {}
        for event in events:
            target = event['path'].lstrip('/')
            if target in atomic_targets and event['kind'] in ('write', 'write-nocancel', 'pwrite', 'pwrite-nocancel', 'writev', 'truncate', 'create-or-truncate'):
                mutable_after.setdefault(target, event['id'])
        snapshots = []
        for event in events:
            tree = folder / f"{event['id']:06d}"
            files = {}
            directories = []
            metadata = {}
            for path in sorted(tree.rglob('*')):
                relative = path.relative_to(tree).as_posix()
                if path.is_dir():
                    directories.append(relative)
                    continue
                if not path.is_file() or path.is_symlink():
                    raise ValueError('Snapshot must contain regular files only')
                data = path.read_bytes()
                check_bytes(data, scenario + '/' + relative)
                digest = hashlib.sha256(data).hexdigest()
                blobs[digest] = data
                files[relative] = digest
                metadata[relative] = dict(mtimeNanoseconds=path.stat().st_mtime_ns, mode=path.stat().st_mode & 0o777, byteCount=len(data))
            # These copies may precede a valid SQLite header or the transaction's final WAL frame.
            # Keep those states; the checker must still open them. Record unreadable oracle stores explicitly.
            unreadable = []
            for database in tree.rglob('*.sqlite'):
                try:
                    rows(tree, database.relative_to(tree).as_posix())
                except sqlite3.DatabaseError:
                    unreadable.append(database.relative_to(tree).as_posix())
            oracle = json.loads((folder / f"{event['id']:06d}.oracle.json").read_text())
            oracle['unreadableStores'] = unreadable
            oracle['complete'] = [dict(zip(('identifier', 'resource', 'revision', 'resourceCount'), row)) for row in safe_rows(tree, 'Account/upload-backup-state-v1.sqlite', unreadable, 'SELECT source_id,resource,revision_us,resource_count FROM backup_asset_state WHERE pending_resources=0')]
            oracle['queueKeys'] = ['|'.join(map(str, row)) for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT source_id,resource,revision_us FROM backup_sync_queue')]
            oracle['queueStates'] = sorted({row[0] for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT state FROM backup_sync_queue')})
            retry = any(network_retry(row[0]) for row in safe_rows(tree, 'Account/upload-backup-sync-queue-v1.sqlite', unreadable, 'SELECT last_error FROM backup_sync_queue WHERE last_error IS NOT NULL'))
            snapshots.append({'atomicTargets': {path: hashes for path, hashes in atomic_targets.items() if event['id'] < mutable_after.get(path, float('inf'))}, 'atomicHelpers': {path: target for path, target in atomic_helpers.items() if path in files}, 'retryIssueObserved': retry, 'event': event, 'files': files, 'directories': directories, 'metadata': metadata, 'oracle': oracle})
        if not snapshots:
            raise ValueError('No write boundaries for ' + scenario)
        manifest['scenarios'][scenario] = snapshots
    destination.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
    check_bytes(encoded, 'manifest')
    archive = destination / 'corpus.tar.gz'
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed, tarfile.open(fileobj=compressed, mode='w') as tar:
        for digest, data in sorted(blobs.items()):
            info = tarfile.TarInfo('blobs/' + digest)
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    (destination / 'manifest.json').write_bytes(encoded)
    size = sum(path.stat().st_size for path in destination.rglob('*') if path.is_file())
    if size > BUDGET:
        raise ValueError(f'Corpus exceeds hard 15 MB budget: {size}')
    print(json.dumps({'snapshots': {key: len(value) for key, value in manifest['scenarios'].items()}, 'blobs': len(blobs), 'archiveBytes': archive.stat().st_size, 'manifestBytes': len(encoded), 'totalBytes': size}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recorded', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    pack(args.recorded, args.destination)
