import SwiftUI
import UIKit

/// Applies the native leading title style to iPhone and iPad routes.
///
/// SwiftUI does not expose `UINavigationItem.style`, so this bridge sets the public UIKit property
/// on the visible navigation item.
extension View {
    func mobileNavigationTitle(_ title: String, isVisible: Bool = true) -> some View {
        modifier(MobileNavigationTitleModifier(title: title, isVisible: isVisible))
    }
}

private struct MobileNavigationTitleModifier: ViewModifier {
    let title: String
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .navigationTitle(isVisible ? title : "")
            .toolbarTitleDisplayMode(.inline)
            .background {
                MobileNavigationItemStyleBridge(style: .browser)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

private struct MobileNavigationItemStyleBridge: UIViewControllerRepresentable {
    let style: UINavigationItem.ItemStyle

    func makeUIViewController(context: Context) -> Controller {
        Controller(style: style)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(style: style)
    }

    @MainActor
    final class Controller: UIViewController {
        private var style: UINavigationItem.ItemStyle

        init(style: UINavigationItem.ItemStyle) {
            self.style = style
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyWhenMounted()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyWhenMounted()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyStyleIfVisible()
        }

        func update(style: UINavigationItem.ItemStyle) {
            self.style = style
            applyWhenMounted()
        }

        private func applyWhenMounted() {
            applyStyleIfVisible()
            DispatchQueue.main.async { [weak self] in
                self?.applyStyleIfVisible()
            }
        }

        private func applyStyleIfVisible() {
            guard viewIfLoaded?.window != nil,
                let navigationController = enclosingNavigationController(),
                let visibleController = navigationController.topViewController,
                belongs(to: visibleController)
            else {
                return
            }
            guard visibleController.navigationItem.style != style else { return }
            visibleController.navigationItem.style = style
            navigationController.navigationBar.setNeedsLayout()
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                if let navigationController = current.navigationController {
                    return navigationController
                }
                candidate = current.parent
            }
            return nil
        }

        private func belongs(to visibleController: UIViewController) -> Bool {
            var candidate: UIViewController? = self
            while let current = candidate {
                if current === visibleController { return true }
                candidate = current.parent
            }
            return false
        }
    }
}
