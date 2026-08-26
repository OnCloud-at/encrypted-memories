# Smart Search

Smart Search builds an encrypted, on-device index for private discovery across the photo library.

## Current search scopes

- **All:** Combines available search sources.
- **Text:** Searches recognized text from images and documents.

The app shows **Text** only when its local Apple Vision index is available. Initial indexing can take time and can pause when foreground library work has priority.

Visual Search is a separate optional model feature for descriptive queries. Its availability depends on a compatible signed model in the current model catalog. Document, barcode, and similar-image pipelines are not separate user-selectable scopes in the current app.

## Privacy

- Photos and search queries are not sent to a separate search service.
- Model artifacts and encrypted indexes remain on the device.
- Signing out removes account-scoped local search data.

## Hardware

Smart Search does not require a Neural Engine. Apple Vision exposes supported compute devices for each request, and Core ML can use CPU, GPU, or Neural Engine. A specific scope can be unavailable when its Apple Vision request is unsupported even though the rest of the app remains available.

## Platform presentation

- **iPhone and iPad:** Use the native **Search** tab and choose an available scope below the query field.
- **Mac:** Use the search controls in the library and configure indexing in the Smart Search Settings tab.
