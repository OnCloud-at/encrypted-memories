# Duplicates

Duplicates finds identical copies of a photo or video in your library and merges them. Identical means the same bytes, including location, date, and all other details.

## Open Duplicates

- **iPhone and iPad:** Open **Collections**, then **Duplicates** in the **Utilities** section.
- **Mac:** Select **Duplicates** in the sidebar, above **Recently Deleted**.

The badge shows how many duplicate copies the app found.

The first check of a large library takes some time. While it runs, the screen shows **Checking Your Library**. If no duplicates were found yet, they appear when the check is done. If the check is still running, the screen says **Still checking your library. More duplicates can appear.**

## Read a group

Each group shows the identical copies of one photo. The group header shows the capture date. Each copy shows its file size. Below the group, the app shows the space that the group frees once Recently Deleted is emptied, for example **Merge frees 2.1 MB**.

One copy of each group stays. The group tells you which one and why, for example **Stays: favorite** or **Stays: in one of your albums**. The copy that stays keeps its favorites and albums.

Select **Merge** in the group header to merge one group. Each copy also has a menu with **Keep This Copy**; on iPhone and iPad, press and hold the copy.

Tap or click a copy to open it in the viewer. The viewer shows the other copies of the group in a filmstrip. Use **Keep This Copy** to choose the copy that stays, and **Merge** to merge the group.

## Merge All

**Merge All** merges every group. Confirm it in the dialog.

Merge All can show two phases:

1. **Checking albums and favorites**, for the groups that the app did not check yet: the app reads their albums, favorites, and sharing state, so that it keeps the correct copy.
2. **Merging Duplicates**: the app merges the groups in batches.

Both phases show their progress, for example **320 of 1,404 groups**. Select **Stop** to stop after the batch that runs. The app then shows **Merging stopped. X of Y groups were merged.** The groups that were not merged stay in the list. Start Merge All again to merge them.

On iPhone and iPad, Merge All pauses when the app goes to the background and continues when you return to the app. It does not continue after the app is quit.

## What happens to the merged copies

Merging moves the other copies of each group to [[Recently Deleted|Recently-Deleted]]. You can restore them from there.

Merging alone does not free storage in Proton Drive. Storage is freed only when Recently Deleted is emptied. The screen shows this, for example **Merging all frees 3.4 GB once Recently Deleted is emptied.**

## Copies that stay

Some copies stay in the library after a merge. The app then tells you how many duplicates it kept, and why, for example:

- It is shared with others.
- The backup of this device still needs it.
- An edit is still being backed up.
- A file such as a Live Photo video exists only with the duplicate.
- Its date, place, or other details differ.
- It could not be read. Try again later.

If the copy that you chose to keep cannot be read, the group is not merged. The app shows **Not Merged**: **The photo to keep could not be read. Choose another one or try again later.**

## If a merge fails

If some groups do not merge, the app shows **Merge Failed** and asks you to check your connection and try again.

If no group of a batch can be merged, for example without a connection, Merge All stops and shows **Merging stopped. X of Y groups were merged.**
