# Backup and Photo Library Sync

Encrypted Memories uses one shared backup engine across Mac, iPhone, and iPad. The platform shells own only permissions, background execution, and native controls.

## Apple Photos library backup

1. Open Settings, then **Backup**. On a Mac, open the Backup tab.
2. Enable Photos backup.
3. Grant full or limited Photos access.
4. Keep the app open for the first large pass when practical.
5. Review progress and any items that need attention.

The queue is durable. It includes streamed hashing, duplicate detection, retry state, crash recovery, and remote reconciliation.

A photo that exists only in iCloud ("Optimize Storage") downloads once for its backup. A new photo that the
camera still processes waits, without repeated checks, until Apple Photos reports the finished photo. If that
report does not come, one check ten minutes after the shot backs up the version that exists. **Back Up Now**
checks a waiting photo again at once.

On iPhone and iPad, background processing is scheduled with the operating system. iOS decides when background work runs, so backup is not guaranteed to be continuous after the app closes.

## Excluded from Backup

Deleting a photo in the app before it was backed up takes it out of the backup for good on this device.
Later backup passes never offer it again, and Apple Photos keeps it. The Backup settings list these photos
under **Excluded from Backup**; choose **Back Up Again** to put one back into the backup. Exclusions are
stored per device.

## Limited Photos access

When iOS or iPadOS grants limited access, only selected library items can be backed up. Use **Manage Selection** on the Backup page to change the allowed set.

## Mac folder backup

The Mac app can also watch user-selected folders. The first **Add Folder** click opens Full Disk
Access settings. Grant access, return to Encrypted Memories, and click **Add Folder** again to
choose the folder. The app stores a security-scoped bookmark for that selection. Renew access when
macOS requests it. An unreadable folder or subtree stops the pass and appears as an error instead of
being treated as empty.

Manual Mac photo or folder uploads are separate from continuous backup, but they use the same upload queue and duplicate protections.

Continue with [[Album Sync|Album-Sync]] or [[Uploads and Upload Queue|Uploads-and-Queue]].
