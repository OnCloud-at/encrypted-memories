import DesignSystemCore
import Foundation
import MapKit
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// Native iOS metadata sheet for the full-screen viewer.
///
/// Metadata and album membership are supplied by the viewer so this view only owns presentation. The
/// shared `PhotoMetadataLoadState` remains the single source of truth for the metadata request lifecycle.
struct MobileViewerInfoSheet: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    let item: PhotoItem
    let metadataLoadState: PhotoMetadataLoadState
    let albumTitles: [String]
    let canLoadAlbumMemberships: Bool
    let isLoadingAlbumMemberships: Bool
    let albumMembershipsLoadFailed: Bool
    let placeName: String?
    let onRetry: () -> Void
    let onClose: () -> Void

    private var metadata: PhotoMetadata? {
        metadataLoadState.metadata
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    captureSection
                    fileSection
                    locationSection
                    albumsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mobileNavigationTitle(L10n.string("infopanel.info"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Label(L10n.string("infopanel.close"), systemImage: "xmark")
                    }
                    .accessibilityLabel(L10n.string("infopanel.close"))
                }
                .mobileVisibilityPriority(.high)
            }
            .presentationDragIndicator(.visible)
        }
    }

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
                    .accessibilityLabel(device)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let type = ViewerInfoFileFields.mediaType(mimeType: metadata?.mimeType, fallback: item.mediaType) {
                metadataRow(L10n.string("infopanel.type"), value: type)
            }

            metadataStateContent
        }
    }

    @ViewBuilder
    private var metadataStateContent: some View {
        switch metadataLoadState {
        case .idle:
            Label(L10n.string("infopanel.info"), systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("infopanel.info"))

        case .loading:
            ProgressSpinner(accessibilityLabel: L10n.string("infopanel.info"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

        case .loaded(let metadata):
            loadedMetadataSection(metadata)

        case .unavailable:
            EmptyView()

        case .failed:
            ViewerInfoLoadFailedView(onRetry: onRetry)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func loadedMetadataSection(_ metadata: PhotoMetadata) -> some View {
        let fields = ViewerInfoFileFields(metadata: metadata, fallbackDuration: item.durationSeconds)
        if let filename = fields.filename {
            metadataRow(L10n.string("infopanel.name"), value: filename)
        }
        if let dimensions = fields.dimensions {
            metadataRow(L10n.string("infopanel.dimensions"), value: dimensions)
        }
        if let size = fields.fileSize {
            metadataRow(L10n.string("infopanel.size"), value: L10n.fileSize(size))
        }
        if let duration = fields.duration {
            metadataRow(L10n.string("infopanel.duration"), value: duration)
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        let location = ViewerInfoLocation(
            metadata: metadata, placeName: placeName, mapAndPlacesEnabled: mapAndPlacesEnabled)
        if location.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                if let placeName = location.placeName {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let latitude = metadata?.latitude, let longitude = metadata?.longitude,
                    let coordinates = location.coordinateText
                {
                    if location.showsMap, let mapLabel = location.mapAccessibilityLabel {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        let mapTitle = location.markerTitle
                        Map(
                            initialPosition: .region(
                                MKCoordinateRegion(
                                    center: coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                                ))
                        ) {
                            Marker(mapTitle, coordinate: coordinate)
                        }
                        .id(location.mapIdentity)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.55, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(mapLabel))
                    }

                    Text(coordinates)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            Text(coordinates)
                        )
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        if canLoadAlbumMemberships {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("infopanel.albums"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if isLoadingAlbumMemberships {
                    ProgressSpinner(accessibilityLabel: L10n.string("infopanel.albums"))
                } else if albumMembershipsLoadFailed {
                    Label(
                        L10n.string("infopanel.albums_load_failed"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if albumTitles.isEmpty {
                    Text(L10n.string("infopanel.no_albums"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(albumTitles, id: \.self) { title in
                        Label(title, systemImage: "rectangle.stack")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The photo details in the lower part of the folded layout: the date and time as its title, the place, and the albums
/// as chips. No map, no file information and no buttons; the Info inspector keeps those. The title bar then shows only
/// the position, so each fact appears once.
struct MobileViewerDetailsSummary: View {
    let details: ViewerChromeLayoutProfile.Details
    let item: PhotoItem
    let placeName: String?
    let albumTitles: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: details.groupSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: details.titleSpacing) {
                    dateText
                    timeText
                }
                VStack(alignment: .leading, spacing: details.stackedTitleSpacing) {
                    dateText
                    timeText
                }
            }
            .accessibilityElement(children: .combine)
            if let placeName {
                Label(placeName, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !albumTitles.isEmpty {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: details.albumChipSpacing) { chips(singleLine: false) }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: details.albumChipSpacing) { chips(singleLine: true) }
                    }
                    .scrollClipDisabled()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var dateText: some View {
        Text(item.captureTime, format: ViewerInfoCaptureFormat.date)
            .font(.title3.weight(.semibold))
    }

    private var timeText: some View {
        Text(item.captureTime, format: ViewerInfoCaptureFormat.time)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func chips(singleLine: Bool) -> some View {
        ForEach(albumTitles, id: \.self) { title in
            Label(title, systemImage: "rectangle.stack")
                .font(.footnote.weight(.medium))
                .lineLimit(singleLine ? 1 : nil)
                .modifier(CappedWidth(maximum: singleLine ? details.albumChipMaxWidth : nil))
                .padding(.horizontal, details.albumChipHorizontalPadding)
                .padding(.vertical, details.albumChipVerticalPadding)
                .background(.fill.secondary, in: Capsule())
        }
    }
}

/// Keeps a chip's label at its own width up to `maximum`, so a long album title truncates instead of widening the chip.
/// A horizontal scroll view proposes no width, so a plain maximum-width frame alone cannot cap the label.
struct CappedWidth: ViewModifier {
    let maximum: CGFloat?

    func body(content: Content) -> some View {
        if let maximum {
            CappedWidthLayout(maximum: maximum) { content }
        } else {
            content
        }
    }
}

private struct CappedWidthLayout: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(subview.sizeThatFits(.unspecified).width, maximum, proposal.width ?? .infinity)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
