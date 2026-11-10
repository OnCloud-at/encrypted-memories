import DesignSystem
import MapKit
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// Content of the viewer's native inspector: all available file metadata for the current photo or video plus a
/// native map when GPS is present.
struct InfoPanelView: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    let item: PhotoItem
    let metadataLoadState: PhotoMetadataLoadState
    let placeName: String?
    let albumTitles: [String]
    let canLoadAlbumMemberships: Bool
    let isLoadingAlbumMemberships: Bool
    let albumMembershipsLoadFailed: Bool
    let onRetry: () -> Void

    private var metadata: PhotoMetadata? { metadataLoadState.metadata }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                captureSection
                locationSection
                fileSection
                if canLoadAlbumMemberships {
                    albumSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Sections

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.captureTime, format: ViewerInfoCaptureFormat.date)
                .font(.headline)
            Text(item.captureTime, format: ViewerInfoCaptureFormat.time)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let device = metadata.flatMap({ ViewerInfoFileFields(metadata: $0, fallbackDuration: nil).device }) {
                Label(device, systemImage: "camera")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var locationSection: some View {
        let location = ViewerInfoLocation(
            metadata: metadata, placeName: placeName, mapAndPlacesEnabled: mapAndPlacesEnabled)
        if let coordinates = location.coordinateText {
            VStack(alignment: .leading, spacing: 10) {
                if let placeName = location.placeName {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if location.showsMap, let metadata, let mapLabel = location.mapAccessibilityLabel {
                    mapSection(
                        metadata, title: location.markerTitle, accessibilityLabel: mapLabel,
                        identity: location.mapIdentity)
                }
                Text(coordinates)
                    .font(mapAndPlacesEnabled ? .subheadline : .body)
                    .monospacedDigit()
                    .foregroundStyle(mapAndPlacesEnabled ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func mapSection(
        _ m: PhotoMetadata, title: String, accessibilityLabel: String, identity: String?
    ) -> some View {
        let coord = CLLocationCoordinate2D(latitude: m.latitude!, longitude: m.longitude!)
        Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
        ) {
            Marker(title, coordinate: coord)
        }
        .id(identity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fileSection: some View {
        let fields = metadata.map { ViewerInfoFileFields(metadata: $0, fallbackDuration: item.durationSeconds) }
        return VStack(alignment: .leading, spacing: 10) {
            if let name = fields?.filename {
                row(L10n.string("infopanel.name"), name)
            }
            if let dimensions = fields?.dimensions {
                row(L10n.string("infopanel.dimensions"), dimensions)
            }
            if let size = fields?.fileSize {
                row(L10n.string("infopanel.size"), L10n.fileSize(size))
            }
            if let duration = fields?.duration {
                row(L10n.string("infopanel.duration"), duration)
            }
            if let type = ViewerInfoFileFields.mediaType(mimeType: metadata?.mimeType, fallback: item.mediaType) {
                row(L10n.string("infopanel.type"), type)
            }
            if metadataLoadState == .loading || metadataLoadState == .idle {
                ProgressSpinner(accessibilityLabel: L10n.string("infopanel.info"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            } else if metadataLoadState == .failed {
                ViewerInfoLoadFailedView(onRetry: onRetry)
            }
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("infopanel.albums"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if isLoadingAlbumMemberships {
                ProgressSpinner(accessibilityLabel: L10n.string("infopanel.albums"))
            } else if albumMembershipsLoadFailed {
                Label(L10n.string("infopanel.albums_load_failed"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if albumTitles.isEmpty {
                Text(L10n.string("infopanel.no_albums"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(albumTitles, id: \.self) { title in
                    Label(title, systemImage: "rectangle.stack")
                        .font(.subheadline)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}
