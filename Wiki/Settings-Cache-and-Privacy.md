# Settings, Cache, and Privacy

## iPhone and iPad

Open the **Photos** tab and select the account button. The Settings screen contains account and storage information, backup, album sync, cache controls, Smart Search, optional tips, support-report export, build information, and sign out.

## Mac

Open **Encrypted Memories → Settings…**. Native tabs separate Account, Support, Library, Smart Search, Backup, and Cache diagnostics.

## Cache controls

Encrypted Memories keeps encrypted thumbnails, previews, originals, metadata, and derived indexes in account-scoped local storage. Clearing a cache removes local copies; it does not delete remote Proton Drive photos.

The app can rebuild derived thumbnails and search indexes from the remote library. This can temporarily increase network and background activity.

## Privacy boundaries

- Proton authentication happens through the browser flow.
- Credentials use the platform Keychain with device-only accessibility.
- Local photo and search data is encrypted at rest.
- Search queries are not sent to a separate search service.
- Release builds do not write file debug logs. Runtime-gated unified logging is disabled unless explicitly enabled for a local investigation.
- Support reports must be reviewed before sharing. Never attach passwords, API keys, private links, or photo content to GitHub.

Signing out removes account-scoped local state after active work has stopped. Remote Proton Drive content remains unchanged.
