import PhotosCore
import SwiftUI

public struct OfflineContentUnavailableView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label(L10n.string("offline.content_title"), systemImage: "bolt.slash")
        } description: {
            Text(L10n.string("offline.content_message"))
        }
    }
}
