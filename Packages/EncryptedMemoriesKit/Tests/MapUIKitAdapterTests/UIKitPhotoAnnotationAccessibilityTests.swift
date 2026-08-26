#if canImport(UIKit)
    import MapCore
    import PhotosCore
    import Testing
    import UIKit
    @testable import MapUIKitAdapter

    @MainActor
    @Suite("UIKit map accessibility")
    struct UIKitPhotoAnnotationAccessibilityTests {
        private func annotation(memberCount: Int) -> PhotoMapAnnotation {
            let members = (0..<memberCount).map { index in
                PhotoUID(volumeID: "volume", nodeID: "map-\(index)")
            }
            let aggregated = AggregatedCoordinate(
                cellID: PhotoLocationCellID(
                    latitudeStepExponent: -2,
                    longitudeCellCountExponent: 10,
                    latitudeIndex: 10,
                    longitudeIndex: 20
                ),
                memberUIDs: members,
                latitude: 47,
                longitude: 13,
                uid: members[0]
            )
            return PhotoMapAnnotation(aggregated)
        }

        @Test func singleAndMultiPhotoPinsExposeNativeLabelsHintsAndTraits() {
            let view = UIKitPhotoAnnotationView(annotation: nil, reuseIdentifier: nil)

            view.configureAccessibility(annotation: annotation(memberCount: 1))
            #expect(view.isAccessibilityElement)
            #expect(view.accessibilityLabel == L10n.string("a11y.map.photo"))
            #expect(view.accessibilityHint == L10n.string("a11y.map.open_hint"))
            #expect(view.accessibilityTraits.contains(.image))
            #expect(view.accessibilityTraits.contains(.button))

            view.configureAccessibility(annotation: annotation(memberCount: 3))
            #expect(view.accessibilityLabel == L10n.string("a11y.map.photos_count 3"))
            #expect(view.accessibilityHint == L10n.string("a11y.map.open_cluster_hint"))
            #expect(view.accessibilityTraits.contains(.image))
            #expect(view.accessibilityTraits.contains(.button))
        }

        @Test func countBadgeUsesDynamicTypeAndResizes() {
            let view = UIKitPhotoAnnotationView(annotation: nil, reuseIdentifier: nil)
            view.setCount(3)

            let label = view.subviews.compactMap { $0 as? UILabel }.first
            #expect(label?.adjustsFontForContentSizeCategory == true)
            #expect(label?.font.pointSize ?? 0 > 0)
            #expect(label?.isHidden == false)
        }
    }
#endif
