import Testing
import UIKit

@testable import EncryptedMemoriesMobile

/// What covers a place of the continued backup question, read from a real window (#1108).
@MainActor @Suite(.serialized) struct MobileContinuedBackupPromptProbeTests {
    private struct Place {
        let window: UIWindow
        let root: UIViewController
        let probe: MobileContinuedBackupPromptProbe
    }

    private func makePlace() throws -> Place {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "the test host has a scene")
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let probe = MobileContinuedBackupPromptProbe()
        root.view.addSubview(probe.anchorView())
        return Place(window: window, root: root, probe: probe)
    }

    private func present(_ controller: UIViewController, from presenter: UIViewController) async {
        await withCheckedContinuation { done in
            presenter.present(controller, animated: false) { done.resume() }
        }
    }

    private func dismiss(_ presenter: UIViewController) async {
        await withCheckedContinuation { done in
            presenter.dismiss(animated: false) { done.resume() }
        }
    }

    @Test func presentationsOverThePlaceCoverIt() async throws {
        let place = try makePlace()
        defer { place.window.isHidden = true }
        #expect(place.probe.presentationsOverPlace() == 0)
        #expect(!place.probe.coversPlace(ownQuestionShows: false))

        let sheet = UIViewController()
        await present(sheet, from: place.root)
        #expect(place.probe.presentationsOverPlace() == 1)
        #expect(place.probe.coversPlace(ownQuestionShows: false), "a sheet covers the place")
        #expect(!place.probe.coversPlace(ownQuestionShows: true), "the own question alone does not cover it")

        await present(UIViewController(), from: sheet)
        #expect(place.probe.presentationsOverPlace() == 2)
        #expect(place.probe.coversPlace(ownQuestionShows: true), "something over the own question covers it")

        await dismiss(place.root)
        #expect(place.probe.presentationsOverPlace() == 0)
        #expect(!place.probe.coversPlace(ownQuestionShows: false))
    }

    @Test func textInputInThePlacesSceneCoversIt() throws {
        let place = try makePlace()
        defer { place.window.isHidden = true }
        let field = UITextField()
        place.root.view.addSubview(field)

        #expect(field.becomeFirstResponder())
        #expect(place.probe.isEditingText)
        #expect(place.probe.coversPlace(ownQuestionShows: false))

        #expect(field.resignFirstResponder())
        #expect(!place.probe.isEditingText)
        #expect(!place.probe.coversPlace(ownQuestionShows: false))
    }

    @Test func aPlaceWithoutAViewControllerCountsAsCovered() {
        let probe = MobileContinuedBackupPromptProbe()
        #expect(probe.presentationsOverPlace() == nil)
        #expect(probe.coversPlace(ownQuestionShows: false), "it never asks blind")
        _ = probe.anchorView()
        #expect(probe.coversPlace(ownQuestionShows: false), "a view outside any window has no view controller")
    }
}
