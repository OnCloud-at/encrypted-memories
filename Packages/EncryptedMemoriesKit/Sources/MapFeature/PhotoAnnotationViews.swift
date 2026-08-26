import AppKit
import MapKit

/// Shared rounded-photo badge styling (Apple-Photos look): a thumbnail in a white-bordered rounded square
/// with a soft shadow. The cluster variant adds a count pill.
private enum BadgeStyle {
    static let size: CGFloat = 54
    static let corner: CGFloat = 12
    static let border: CGFloat = 3
}

/// Decorative badge text must never become the click target instead of its MapKit annotation view.
private final class NonHitTestingTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One final Core display cell on the map - a rounded hero thumbnail with its complete member count.
final class PhotoAnnotationView: MKAnnotationView {
    static let reuseID = "PhotoAnnotation"

    private let imageLayer = CALayer()
    private let countLabel = NonHitTestingTextField(labelWithString: "")
    private let countBackground = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // The shared Core has already enforced the view's pin spacing and count budget. Requiring these
        // annotations prevents MapKit collision decluttering from dropping represented photos.
        clusteringIdentifier = nil
        displayPriority = .required
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: BadgeStyle.size, height: BadgeStyle.size)
        centerOffset = CGPoint(x: 0, y: -BadgeStyle.size / 2)
        wantsLayer = true
        configureContainer(layer!)
        imageLayer.frame = layer!.bounds.insetBy(dx: BadgeStyle.border, dy: BadgeStyle.border)
        imageLayer.cornerRadius = BadgeStyle.corner - BadgeStyle.border
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer!.addSublayer(imageLayer)

        // A final cell can stand for many photos, so its badge carries the complete member count.
        // Hidden for a cell of exactly one photo.
        countBackground.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        countBackground.cornerRadius = 8
        countBackground.isHidden = true
        layer!.addSublayer(countBackground)

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = .white
        countLabel.backgroundColor = .clear
        countLabel.isBezeled = false
        countLabel.isEditable = false
        countLabel.isHidden = true
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setThumbnail(_ image: NSImage?) {
        imageLayer.contents = image
        imageLayer.backgroundColor = image == nil ? NSColor.secondaryLabelColor.cgColor : nil
    }

    /// Show a "N" pill when the cell aggregates more than one photo; hide it for a single photo.
    func setCount(_ count: Int) {
        guard count > 1 else {
            countLabel.isHidden = true
            countBackground.isHidden = true
            return
        }
        countLabel.isHidden = false
        countBackground.isHidden = false
        countLabel.stringValue = "\(count)"
        countLabel.sizeToFit()
        let pad: CGFloat = 6
        let w = countLabel.frame.width + pad * 2
        let h = countLabel.frame.height + 2
        countLabel.frame = CGRect(
            x: BadgeStyle.border + pad + 1, y: BadgeStyle.border + 2, width: countLabel.frame.width,
            height: countLabel.frame.height)
        countBackground.frame = CGRect(x: BadgeStyle.border + 1, y: BadgeStyle.border + 1, width: w, height: h)
    }

    fileprivate func configureContainer(_ l: CALayer) {
        l.cornerRadius = BadgeStyle.corner
        l.backgroundColor = NSColor.white.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.25
        l.shadowRadius = 4
        l.shadowOffset = CGSize(width: 0, height: -1)
    }
}
