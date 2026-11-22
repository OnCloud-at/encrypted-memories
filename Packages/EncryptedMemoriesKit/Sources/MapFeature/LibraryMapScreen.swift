import AppKit
import SwiftUI

/// SwiftUI wrapper around the map view. Its body reads the revision of the location index, so a new revision
/// re-renders the wrapper and the map view inside it. The read is pinned by `testScreenBodyObservesIndexRevision`.
public struct LibraryMapScreen: View {
    private let map: LibraryMapView

    public init(_ map: LibraryMapView) {
        self.map = map
    }

    public var body: some View {
        let _ = map.index.revision
        map
    }
}
