#if canImport(UIKit)
    import MapKit
    import MapCore
    import PhotosCore
    import UIKit

    private enum UIKitMapBadgeStyle {
        static let size: CGFloat = 54
        static let corner: CGFloat = 12
        static let border: CGFloat = 3
    }

    private final class UIKitMapObserverToken: @unchecked Sendable {
        let token: NSObjectProtocol

        init(_ token: NSObjectProtocol) {
            self.token = token
        }

        func remove() {
            NotificationCenter.default.removeObserver(token)
        }
    }

    final class UIKitPhotoAnnotationView: MKAnnotationView {
        static let reuseID = "UIKitPhotoAnnotation"

        private let imageLayer = CALayer()
        private let countLabel = UILabel()
        private let countBackground = CALayer()
        private var displayedCount = 1
        private var contentSizeCategoryObserver: UIKitMapObserverToken?

        override var annotation: MKAnnotation? {
            didSet {
                guard let photo = annotation as? PhotoMapAnnotation else {
                    isAccessibilityElement = false
                    accessibilityLabel = nil
                    accessibilityHint = nil
                    accessibilityTraits = []
                    return
                }
                configureAccessibility(annotation: photo)
            }
        }

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            // Core has already produced the final, point-budgeted display partition. Required priority is
            // intentional: MapKit must not silently hide a cell containing thousands of represented photos.
            clusteringIdentifier = nil
            displayPriority = .required
            collisionMode = .circle
            frame = CGRect(x: 0, y: 0, width: UIKitMapBadgeStyle.size, height: UIKitMapBadgeStyle.size)
            centerOffset = CGPoint(x: 0, y: -UIKitMapBadgeStyle.size / 2)
            configureContainer(layer)
            imageLayer.frame = layer.bounds.insetBy(dx: UIKitMapBadgeStyle.border, dy: UIKitMapBadgeStyle.border)
            imageLayer.cornerRadius = UIKitMapBadgeStyle.corner - UIKitMapBadgeStyle.border
            imageLayer.masksToBounds = true
            imageLayer.contentsGravity = .resizeAspectFill
            layer.addSublayer(imageLayer)

            // A final cell can stand for many photos, so its badge always carries the complete member count.
            // Hidden for a cell of exactly one photo.
            countBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            countBackground.cornerRadius = 8
            countBackground.isHidden = true
            layer.addSublayer(countBackground)

            countLabel.font = UIFontMetrics(forTextStyle: .caption1)
                .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
            countLabel.adjustsFontForContentSizeCategory = true
            countLabel.textColor = .white
            countLabel.backgroundColor = .clear
            countLabel.isHidden = true
            addSubview(countLabel)
            let observer = NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.layoutCountBadge() }
            }
            contentSizeCategoryObserver = UIKitMapObserverToken(observer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        deinit {
            contentSizeCategoryObserver?.remove()
        }

        func setThumbnail(_ image: UIImage?) {
            imageLayer.contentsScale = image?.scale ?? currentDisplayScale
            imageLayer.contents = image?.cgImage
            imageLayer.backgroundColor = image == nil ? UIColor.secondaryLabel.cgColor : nil
        }

        /// Show a "N" pill when the cell aggregates more than one photo; hide it for a single photo so a
        /// lone pin still reads as one picture.
        func setCount(_ count: Int) {
            if let photo = annotation as? PhotoMapAnnotation {
                configureAccessibility(annotation: photo)
            }
            displayedCount = max(1, count)
            layoutCountBadge()
        }

        private func layoutCountBadge() {
            guard displayedCount > 1 else {
                countLabel.isHidden = true
                countBackground.isHidden = true
                return
            }
            countLabel.isHidden = false
            countBackground.isHidden = false
            countLabel.text = "\(displayedCount)"
            countLabel.sizeToFit()

            let pad: CGFloat = 6
            let width = countLabel.frame.width + pad * 2
            let height = countLabel.frame.height + 2
            let y = bounds.height - UIKitMapBadgeStyle.border - height - 1
            countLabel.frame = CGRect(
                x: UIKitMapBadgeStyle.border + pad + 1,
                y: y + 1,
                width: countLabel.frame.width,
                height: countLabel.frame.height
            )
            countBackground.frame = CGRect(
                x: UIKitMapBadgeStyle.border + 1,
                y: y,
                width: width,
                height: height
            )
        }

        /// Configure the native VoiceOver node for the final Core-owned map cell.
        /// MapKit may recycle this view, so every annotation assignment refreshes the full semantic state.
        func configureAccessibility(annotation: PhotoMapAnnotation) {
            isAccessibilityElement = true
            accessibilityLabel =
                annotation.memberCount > 1
                ? L10n.string("a11y.map.photos_count \(annotation.memberCount)")
                : L10n.string("a11y.map.photo")
            accessibilityHint =
                annotation.memberCount > 1
                ? L10n.string("a11y.map.open_cluster_hint")
                : L10n.string("a11y.map.open_hint")
            accessibilityTraits = [.image, .button]
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityHint = nil
            accessibilityTraits = []
            displayedCount = 1
            layoutCountBadge()
        }

        private func configureContainer(_ layer: CALayer) {
            layer.contentsScale = currentDisplayScale
            layer.cornerRadius = UIKitMapBadgeStyle.corner
            layer.backgroundColor = UIColor.white.cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.25
            layer.shadowRadius = 4
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }

        private var currentDisplayScale: CGFloat {
            let scale = window?.screen.scale ?? traitCollection.displayScale
            guard scale.isFinite, scale > 0 else { return 1 }
            return scale
        }
    }
#endif
