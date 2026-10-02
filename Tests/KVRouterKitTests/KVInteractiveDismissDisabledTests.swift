import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

/// `interactiveDismissDisabled()`: a screen that only closes from code.
@MainActor
final class KVInteractiveDismissDisabledTests: XCTestCase {
    private var retained: [AnyObject] = []

    func testTheModifierTurnsOffInteractiveBack() {
        XCTAssertTrue(KVNavigationTransition.zoom(sourceID: "a", destinationID: "b").supportsInteractiveBack)
        XCTAssertFalse(
            KVNavigationTransition.zoom(sourceID: "a", destinationID: "b")
                .interactiveDismissDisabled()
                .supportsInteractiveBack
        )
        XCTAssertTrue(
            KVNavigationTransition.depth
                .interactiveDismissDisabled()
                .interactiveDismissDisabled(false)
                .supportsInteractiveBack
        )
    }

    func testAnAnimationOverrideKeepsTheOptOut() {
        let transition = KVNavigationTransition.zoom(sourceID: "a")
            .interactiveDismissDisabled()
            .animation(.easeOut(duration: 0.2))
        XCTAssertFalse(transition.allowsInteractiveDismiss)
        XCTAssertEqual(transition.debugKind, .zoom)
    }

    /// Neither engine may pop it: the custom pan refuses, and UIKit's edge pan — which would
    /// otherwise read "not custom" as its turn — is switched off too.
    func testAnOptedOutTopScreenSilencesBothEngines() {
        let fixture = makeFixture(top: .depth.interactiveDismissDisabled())

        fixture.controller.refreshAvailability()

        XCTAssertTrue(fixture.coordinator.topScreenBlocksInteractiveDismiss())
        XCTAssertFalse(fixture.coordinator.canBeginInteractivePop())
        XCTAssertFalse(fixture.systemGesture.isEnabled)
    }

    /// The opt-out belongs to that screen: a plain `.system` push keeps its back swipe.
    func testASystemPushKeepsItsBackSwipe() {
        let fixture = makeFixture(top: .system)

        fixture.controller.refreshAvailability()

        XCTAssertFalse(fixture.coordinator.topScreenBlocksInteractiveDismiss())
        XCTAssertTrue(fixture.systemGesture.isEnabled)
    }

    private func makeFixture(top: KVNavigationTransition) -> (
        controller: KVInteractiveTransitionController,
        coordinator: KVTransitionCoordinator,
        systemGesture: StubDismissGestureRecognizer
    ) {
        let registry = KVRouteRegistry()
        registry.registerTransition(TestRoute.self) { _ in top }
        let router = KVAppRouter()
        router.routeRegistry = registry
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        let navigationController = UINavigationController()
        navigationController.viewControllers = [UIViewController(), UIViewController()]
        let systemGesture = StubDismissGestureRecognizer()
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            systemGestureResolver: { _ in systemGesture }
        )
        controller.attach(to: navigationController)
        retained.append(contentsOf: [registry, router, coordinator, navigationController] as [AnyObject])
        return (controller, coordinator, systemGesture)
    }
}

/// A recognizer that is never mid-recognition, so availability flips apply at once.
private final class StubDismissGestureRecognizer: UIGestureRecognizer {
    override var state: UIGestureRecognizer.State {
        get { .possible }
        set {}
    }
}
