# Smart Search

Smart Search builds an encrypted, on-device index for private discovery across the photo library.

## Current search scopes

- **All:** Combines available search sources.
- **Text:** Searches recognized text from images and documents.

The app shows **Text** only when its local Apple Vision index is available. Initial indexing can take time and can pause when foreground library work has priority.

Visual Search is a separate optional model feature for descriptive queries. Its availability depends on a compatible signed model in the current model catalog. Document, barcode, and similar-image pipelines are not separate user-selectable scopes in the current app.

## Search suggestions

When the search field is empty, Search suggests entries from your own library:

- Places and places in a season, for example a city in summer.
- Trips, seasons, and photos from this day in earlier years.
- Favorites from a year.
- Media types, for example Videos or Live Photos.
- Photo content, for example beaches or dogs. This requires Visual Search and a finished index.

Select a suggestion to show exactly the photos that belong to it. The app builds suggestions on the device while it is idle. It pauses this work during an active search, video playback, exports that you start, Low Power Mode, and high device temperature. The first build can take several minutes for a large library. After a restart, the app shows the saved suggestions at once if the library did not change.

Suggestion previews never show photos that the sensitive-content check did not confirm.

- **iPhone and iPad:** The Search tab shows **For You** rows with previews and your **Recent** searches.
- **Mac:** Suggestions appear in the menu of the search field.

## Privacy

- Photos and search queries are not sent to a separate search service.
- Place suggestions get their names from Apple MapKit. For this, the app sends only the rounded center of a group of photos, precise to about 1 km. See [[Settings, Cache, and Privacy|Settings-Cache-and-Privacy]].
- Model artifacts and encrypted indexes remain on the device.
- Signing out removes account-scoped local search data.

## Hardware

Smart Search does not require a Neural Engine. Apple Vision exposes supported compute devices for each request, and Core ML can use CPU, GPU, or Neural Engine. A specific scope can be unavailable when its Apple Vision request is unsupported even though the rest of the app remains available.

## Platform presentation

- **iPhone and iPad:** Use the native **Search** tab and choose an available scope below the query field.
- **Mac:** Use the search controls in the library and configure indexing in the Smart Search Settings tab.
