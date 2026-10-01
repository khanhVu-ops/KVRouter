import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

/// `zoom(sourceID:destinationID:)`: the incoming screen clipped to one of its own views, laid
/// over the source.
@MainActor
final class KVAnchoredZoomTests: XCTestCase {

    // MARK: - Resolution

    func testAnchoredZoomNeverTakesTheNativeBackend() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { $0 == AnyHashable("prompt") }
        let resolved = coordinator.resolve(
            override: .zoom(sourceID: "prompt", destinationID: "composer"),
            supportsNativeZoom: true
        )

        XCTAssertEqual(resolved.backend, .custom)
        XCTAssertEqual(resolved.transition.debugKind, .anchoredZoom)
    }

    func testPushWithoutSourceFallsBackToScaleAndFade() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { _ in false }
        let resolved = coordinator.resolve(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: KVNavigationEntry(route: TestRoute.screen("chat")),
                transitionOverride: .zoom(sourceID: "prompt", destinationID: "composer")
            ),
            supportsNativeZoom: true
        )

        XCTAssertEqual(resolved.transition.debugKind, .scaleAndFade)
    }

    /// The screen holding the source is covered until the pop starts, and a covered source has
    /// left the registry — resolving it then would turn every pop into a fade.
    func testPopDefersMissingSourceToTheAnimator() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { _ in false }
        let resolved = coordinator.resolve(
            KVTransitionRequest(
                operation: .pop,
                from: KVNavigationEntry(route: TestRoute.screen("chat")),
                to: nil,
                transitionOverride: .zoom(sourceID: "prompt", destinationID: "composer")
            ),
            supportsNativeZoom: true
        )

        XCTAssertEqual(resolved.backend, .custom)
        XCTAssertEqual(resolved.transition.debugKind, .anchoredZoom)
        XCTAssertTrue(resolved.transition.supportsInteractiveBack)
    }

    // MARK: - Geometry

    /// Clip = destination's width, source's height (scaled back), hung from the destination's
    /// top; the transform lands that clip exactly on the source.
    func testGeometryLandsTheDestinationClipOnTheSource() {
        let viewFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let geometry = KVAnchoredHeroGeometry(
            source: KVHeroTransitionGeometry(frame: CGRect(x: 16, y: 500, width: 368, height: 120), cornerRadius: 24),
            destination: KVHeroTransitionGeometry(frame: CGRect(x: 0, y: 650, width: 400, height: 150), cornerRadius: 24)
        )

        let resolved = geometry.resolved(viewFrame: viewFrame)
        let scale: CGFloat = 368.0 / 400.0

        XCTAssertEqual(resolved.maskFrame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(resolved.maskFrame.minY, 650, accuracy: 0.001)
        XCTAssertEqual(resolved.maskFrame.width, 400, accuracy: 0.001)
        XCTAssertEqual(resolved.maskFrame.height, 120 / scale, accuracy: 0.001)
        XCTAssertEqual(resolved.maskCornerRadius, 24 / scale, accuracy: 0.001)

        let topLeft = project(CGPoint(x: resolved.maskFrame.minX, y: resolved.maskFrame.minY), resolved.transform, viewFrame)
        let bottomRight = project(CGPoint(x: resolved.maskFrame.maxX, y: resolved.maskFrame.maxY), resolved.transform, viewFrame)
        XCTAssertEqual(topLeft.x, 16, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 500, accuracy: 0.001)
        XCTAssertEqual(bottomRight.x, 384, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 620, accuracy: 0.001)
    }

    func testGeometryOfAnOffsetScreenWorksInItsOwnCoordinates() {
        let viewFrame = CGRect(x: 0, y: 20, width: 400, height: 780)
        let geometry = KVAnchoredHeroGeometry(
            source: KVHeroTransitionGeometry(frame: CGRect(x: 16, y: 500, width: 368, height: 120), cornerRadius: 24),
            destination: KVHeroTransitionGeometry(frame: CGRect(x: 0, y: 650, width: 400, height: 150), cornerRadius: 24)
        )

        let resolved = geometry.resolved(viewFrame: viewFrame)
        XCTAssertEqual(resolved.maskFrame.minY, 630, accuracy: 0.001)
        let topLeft = project(CGPoint(x: resolved.maskFrame.minX, y: resolved.maskFrame.minY), resolved.transform, viewFrame)
        XCTAssertEqual(topLeft.x, 16, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 500, accuracy: 0.001)
    }

    func testDegenerateDestinationLeavesTheScreenUntouched() {
        let viewFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let geometry = KVAnchoredHeroGeometry(
            source: KVHeroTransitionGeometry(frame: CGRect(x: 16, y: 500, width: 368, height: 120), cornerRadius: 24),
            destination: KVHeroTransitionGeometry(frame: CGRect(x: 0, y: 650, width: 0, height: 150), cornerRadius: 24)
        )

        let resolved = geometry.resolved(viewFrame: viewFrame)
        XCTAssertTrue(CATransform3DIsIdentity(resolved.transform))
        XCTAssertEqual(resolved.maskFrame, CGRect(origin: .zero, size: viewFrame.size))
    }

    // MARK: - Registry

    func testDestinationsDoNotShareTheSourceIDSpace() {
        let registry = KVTransitionSourceRegistry()
        registry.update(id: "prompt", frame: CGRect(x: 0, y: 0, width: 10, height: 10), view: nil)

        XCTAssertNotNil(registry.source(for: "prompt"))
        XCTAssertNil(registry.destination(for: "prompt"))

        registry.update(
            id: AnyHashable(KVTransitionDestinationKey(id: "prompt")),
            frame: CGRect(x: 0, y: 0, width: 20, height: 20),
            view: nil
        )
        XCTAssertEqual(registry.destination(for: "prompt")?.frame.width, 20)
        XCTAssertEqual(registry.source(for: "prompt")?.frame.width, 10)
    }

    func testSourceHiddenToggles() {
        let registry = KVTransitionSourceRegistry()
        XCTAssertFalse(registry.isSourceHidden("prompt"))
        registry.setSourceHidden(true, id: "prompt")
        XCTAssertTrue(registry.isSourceHidden("prompt"))
        registry.setSourceHidden(false, id: "prompt")
        XCTAssertFalse(registry.isSourceHidden("prompt"))
    }

    /// Where `point` (the view's own coordinates) lands in the container: the layer scales and
    /// translates about its centre.
    private func project(_ point: CGPoint, _ transform: CATransform3D, _ viewFrame: CGRect) -> CGPoint {
        let center = CGPoint(x: viewFrame.midX, y: viewFrame.midY)
        let p = CGPoint(x: viewFrame.minX + point.x - center.x, y: viewFrame.minY + point.y - center.y)
        let affine = CATransform3DGetAffineTransform(transform)
        let mapped = p.applying(affine)
        return CGPoint(x: mapped.x + center.x, y: mapped.y + center.y)
    }
}
