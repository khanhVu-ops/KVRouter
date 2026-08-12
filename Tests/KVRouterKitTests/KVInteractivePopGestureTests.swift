import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
final class KVInteractivePopGestureTests: XCTestCase {
    func testProgressClampsAndNormalizesLayoutDirection() {
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: 160,
                width: 320,
                isRightToLeft: false
            ),
            0.5
        )
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: -160,
                width: 320,
                isRightToLeft: true
            ),
            0.5
        )
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: -10,
                width: 320,
                isRightToLeft: false
            ),
            0
        )
    }

    func testInteractiveFinishUpdatesUIKitAndCommitsRouterOnce() async {
        let fixture = makeFixture()

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.update(
            translation: 160,
            width: 320,
            isRightToLeft: false
        )
        fixture.controller.end(
            translation: 160,
            velocity: 100,
            width: 320,
            isRightToLeft: false
        )
        await waitUntil { fixture.percentDriven.finishCount == 1 }

        XCTAssertEqual(fixture.percentDriven.updates.last, 0.5)
        XCTAssertEqual(fixture.percentDriven.finishCount, 1)
        XCTAssertEqual(fixture.percentDriven.cancelCount, 0)

        fixture.coordinator.completePendingTransition(cancelled: false)
        fixture.coordinator.completePendingTransition(cancelled: false)

        XCTAssertEqual(fixture.router.path, [.screen("a")])
    }

    func testMiddlewareDenialCancelsInteractivePop() async {
        let fixture = makeFixture(middlewares: [DenyPopMiddleware()])

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.update(
            translation: 280,
            width: 320,
            isRightToLeft: false
        )
        fixture.controller.end(
            translation: 280,
            velocity: 1_000,
            width: 320,
            isRightToLeft: false
        )
        await waitUntil { fixture.percentDriven.cancelCount == 1 }
        fixture.coordinator.completePendingTransition(cancelled: true)

        XCTAssertEqual(fixture.percentDriven.finishCount, 0)
        XCTAssertEqual(fixture.router.path.count, 2)
    }

    func testCancellationOnlyCancelsOnce() {
        let fixture = makeFixture()

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.cancel()
        fixture.controller.cancel()

        XCTAssertEqual(fixture.percentDriven.cancelCount, 1)
    }

    private func makeFixture(
        middlewares: [KVRouteMiddleware] = []
    ) -> (
        router: KVAppRouter,
        coordinator: KVTransitionCoordinator,
        controller: KVInteractiveTransitionController,
        percentDriven: RecordingPercentDrivenTransition
    ) {
        let router = KVAppRouter(middlewares: middlewares)
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = [UIViewController(), UIViewController()]
        let percentDriven = RecordingPercentDrivenTransition()
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            percentDrivenFactory: { percentDriven }
        )
        controller.attach(to: navigationController)
        return (router, coordinator, controller, percentDriven)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}

private struct DenyPopMiddleware: KVRouteMiddleware {
    func willNavigate(
        from: (any KVRoute)?,
        to: any KVRoute
    ) async -> (any KVRoute)? {
        to
    }

    func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool {
        false
    }
}

@MainActor
private final class RecordingNavigationController: UINavigationController {
    private(set) var popCount = 0

    override func popViewController(animated: Bool) -> UIViewController? {
        popCount += 1
        return viewControllers.last
    }
}

@MainActor
private final class RecordingPercentDrivenTransition:
    UIPercentDrivenInteractiveTransition {
    private(set) var updates: [CGFloat] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    override func update(_ percentComplete: CGFloat) {
        updates.append(percentComplete)
    }

    override func finish() {
        finishCount += 1
    }

    override func cancel() {
        cancelCount += 1
    }
}
