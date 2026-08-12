import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
final class KVTransitionAnimatorTests: XCTestCase {
    func testRelativeOffsetResolvesAgainstContainerSize() {
        let resolved = KVTransitionViewState.identity
            .relativeOffset(x: 0.5, y: -0.25)
            .resolved(containerSize: CGSize(width: 320, height: 640))

        XCTAssertEqual(resolved.translation.width, 160, accuracy: 0.001)
        XCTAssertEqual(resolved.translation.height, -160, accuracy: 0.001)
    }

    func testThreeDimensionalStateAddsPerspective() {
        let resolved = KVTransitionViewState.identity
            .rotation3D(
                .degrees(70),
                axis: (x: 0, y: 1, z: 0),
                perspective: 1
            )
            .resolved(containerSize: CGSize(width: 320, height: 640))

        XCTAssertNotEqual(resolved.transform.m34, 0)
        XCTAssertFalse(CATransform3DIsIdentity(resolved.transform))
    }

    func testOrderedTransformsProduceOneResolvedTransform() {
        let resolved = KVTransitionViewState.identity
            .relativeOffset(x: 0.5)
            .scale(0.8)
            .rotation(.degrees(10))
            .resolved(containerSize: CGSize(width: 300, height: 600))

        XCTAssertFalse(CATransform3DIsIdentity(resolved.transform))
        XCTAssertEqual(resolved.translation.width, 150, accuracy: 0.001)
    }

    func testManagedViewRestoresEveryMutatedProperty() {
        let view = UIView(frame: CGRect(x: 10, y: 20, width: 200, height: 300))
        view.alpha = 0.8
        view.layer.cornerRadius = 7
        view.layer.zPosition = 3
        view.isUserInteractionEnabled = true
        let originalTransform = CATransform3DMakeScale(0.99, 0.99, 1)
        view.layer.transform = originalTransform
        let managed = KVManagedTransitionView(view)

        managed.apply(
            KVTransitionViewState.identity
                .opacity(0.2)
                .relativeOffset(x: 0.5)
                .scale(0.7)
                .cornerRadius(24)
                .zPosition(10)
                .reveal(from: .topLeading),
            containerSize: CGSize(width: 320, height: 640)
        )

        XCTAssertEqual(view.alpha, 0.2, accuracy: 0.001)
        XCTAssertEqual(view.layer.cornerRadius, 24, accuracy: 0.001)
        XCTAssertEqual(view.layer.zPosition, 10, accuracy: 0.001)
        XCTAssertNotNil(view.mask)
        XCTAssertFalse(view.isUserInteractionEnabled)

        managed.restore()

        XCTAssertEqual(view.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(view.layer.cornerRadius, 7, accuracy: 0.001)
        XCTAssertEqual(view.layer.zPosition, 3, accuracy: 0.001)
        XCTAssertTrue(CATransform3DEqualToTransform(view.layer.transform, originalTransform))
        XCTAssertNil(view.mask)
        XCTAssertTrue(view.isUserInteractionEnabled)
    }

    func testManagedViewRestoresDoubleSidedAfterFlipState() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.layer.isDoubleSided = true
        let managed = KVManagedTransitionView(view)

        managed.apply(
            .identity.rotation3D(
                .degrees(180),
                axis: (x: 0, y: 1, z: 0),
                perspective: 1
            ),
            containerSize: view.bounds.size
        )

        XCTAssertFalse(view.layer.isDoubleSided)
        managed.restore()
        XCTAssertTrue(view.layer.isDoubleSided)
    }

    func testRevealMaskIsCircleCenteredAtOriginAndCoversFarthestCorner() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let managed = KVManagedTransitionView(view)

        managed.prepareReveal(
            for: .identity.reveal(from: .topTrailing),
            containerSize: view.bounds.size
        )

        // A UIView, not a CALayer: UIViewPropertyAnimator animates view
        // properties, so a layer mask would snap instead of wiping.
        let mask = try XCTUnwrap(view.mask)
        let radius = hypot(view.bounds.width, view.bounds.height)
        XCTAssertEqual(mask.center.x, view.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(mask.center.y, view.bounds.minY, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.width, radius * 2, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.height, radius * 2, accuracy: 0.001)
        XCTAssertEqual(mask.layer.cornerRadius, radius, accuracy: 0.001)
        XCTAssertTrue(mask.layer.masksToBounds)
    }

    func testPushHierarchyPlacesDestinationAboveSource() {
        let container = UIView()
        let fromView = UIView()
        let toView = UIView()
        container.addSubview(fromView)

        KVTransitionHierarchy.install(
            operation: .push,
            container: container,
            fromView: fromView,
            toView: toView
        )

        XCTAssertEqual(container.subviews, [fromView, toView])
    }

    func testPopHierarchyPlacesDestinationBelowSource() {
        let container = UIView()
        let fromView = UIView()
        let toView = UIView()
        container.addSubview(fromView)

        KVTransitionHierarchy.install(
            operation: .pop,
            container: container,
            fromView: fromView,
            toView: toView
        )

        XCTAssertEqual(container.subviews, [toView, fromView])
    }
}
