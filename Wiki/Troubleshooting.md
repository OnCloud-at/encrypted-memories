# Troubleshooting

## The app says the device is unsupported

Confirm the device runs OS 26.0 or later and supports Metal 3. The App Store cannot filter Metal 3 exactly, so installation alone is not proof of support. See [[Device and Feature Support|Device-and-Feature-Support]].

## Sign-in does not return to the app

- Finish the Proton browser flow in the same user session.
- Allow the browser to open Encrypted Memories when prompted.
- Reopen the app and retry once.
- Confirm the network is available.

## The library is still preparing

Large libraries can show usable media before all thumbnails, map locations, and search indexes finish. Keep the app in the foreground for the first load. Do not clear caches while a first load or backup pass is active unless you intend to rebuild them.

## Photos are missing from backup

- Check Photos permission.
- With limited access, review **Manage Selection**.
- Resume a paused backup.
- Open the failed-items view and retry recoverable items.
- On iPhone and iPad, remember that the operating system schedules background work.

## A search scope is missing

Smart Search exposes only scopes that Apple Vision reports as supported and that have an available index. Check indexing status in Settings. A Neural Engine is not a general requirement.

## Cached media is unavailable offline

Only media already present in the configured encrypted cache can open offline. Reconnect and open or cache the media before the next offline period.

If a problem is reproducible after these checks, use [[Support and Feedback|Support-and-Feedback]].
