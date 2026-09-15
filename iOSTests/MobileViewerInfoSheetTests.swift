import PhotoViewerCore
import PhotosCore
import SwiftUI
import UIKit
import XCTest

@testable import EncryptedMemoriesMobile

final class MobileViewerInfoSheetTests: XCTestCase {
    @MainActor func testAbsentMetadataIsQuietAndRequestFailureRemainsRetryable() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let item = PhotoItem(
            uid: PhotoUID(volumeID: "shared", nodeID: "photo"),
            captureTime: Date(timeIntervalSince1970: 1_374_306_540), mediaType: "")
        let states: [(String, PhotoMetadataLoadState)] = [
            ("missing", .unavailable), ("empty", .loaded(PhotoMetadata())),
            ("partial", .loaded(PhotoMetadata(filename: "Shared photo.jpg", mimeType: "image/jpeg"))),
            ("failed", .failed),
        ]
        for (name, state) in states {
            window.rootViewController = UIHostingController(
                rootView: MobileViewerInfoSheet(
                    item: item, metadataLoadState: state, albumTitles: ["Shared family"],
                    canLoadAlbumMemberships: true, isLoadingAlbumMemberships: false,
                    albumMembershipsLoadFailed: false, placeName: nil, onRetry: {}, onClose: {}))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let labels = accessibilityLabels(in: window)
            XCTAssertTrue(labels.contains { $0.contains("Shared family") }, "the info sheet must actually render")
            XCTAssertEqual(
                labels.contains { $0.contains(L10n.string("infopanel.load_failed_title")) }, state == .failed)
            XCTAssertEqual(labels.contains { $0 == L10n.string("action.retry") }, state == .failed)
            if name == "partial" {
                XCTAssertTrue(labels.contains { $0.contains("Shared photo.jpg") })
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "photo-info-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["ENCRYPTED_MEMORIES_UI_SNAPSHOT_DIR"],
                let data = image.pngData()
            {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent("photo-info-\(name).png"))
            }
        }
    }

    @MainActor private func accessibilityLabels(in root: NSObject) -> [String] {
        if let view = root as? UIView, view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden {
            return []
        }
        var labels = root.accessibilityLabel.map { [$0] } ?? []
        if let view = root as? UIView {
            for element in view.accessibilityElements ?? [] {
                if let object = element as? NSObject { labels += accessibilityLabels(in: object) }
            }
            for subview in view.subviews { labels += accessibilityLabels(in: subview) }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let object = root.accessibilityElement(at: index) as? NSObject {
                        labels += accessibilityLabels(in: object)
                    }
                }
            }
        }
        return labels
    }
}
