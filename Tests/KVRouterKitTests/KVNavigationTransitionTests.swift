import SwiftUI
import XCTest
@testable import KVRouterKit

@MainActor
final class KVNavigationTransitionTests: XCTestCase {
    func testBuiltInFactoriesKeepTheirKinds() {
        XCTAssertEqual(KVNavigationTransition.system.debugKind, .system)
        XCTAssertEqual(KVNavigationTransition.slide().debugKind, .slide)
        XCTAssertEqual(KVNavigationTransition.fade.debugKind, .fade)
        XCTAssertEqual(KVNavigationTransition.scale.debugKind, .scale)
        XCTAssertEqual(KVNavigationTransition.scaleAndFade.debugKind, .scaleAndFade)
        XCTAssertEqual(KVNavigationTransition.sharedAxis().debugKind, .sharedAxis)
        XCTAssertEqual(KVNavigationTransition.depth.debugKind, .depth)
        XCTAssertEqual(KVNavigationTransition.reveal().debugKind, .reveal)
        XCTAssertEqual(KVNavigationTransition.flip3D().debugKind, .flip3D)
        XCTAssertEqual(KVNavigationTransition.zoom(sourceID: "card").debugKind, .zoom)
    }

    func testTimingCurveStoresDurationAndControlPoints() {
        let animation = KVTransitionAnimation.timingCurve(
            0.22,
            1,
            0.36,
            1,
            duration: 0.38
        )

        XCTAssertEqual(animation.duration, 0.38)
        XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
    }

    func testSpringStoresResponseAndDamping() {
        let animation = KVTransitionAnimation.spring(
            response: 0.4,
            dampingFraction: 0.9
        )

        XCTAssertEqual(animation.duration, 0.4)
        XCTAssertEqual(
            animation.debugTiming,
            .spring(dampingRatio: 0.9, initialVelocity: 0)
        )
    }

    func testAnimationOverridePreservesKind() {
        let transition = KVNavigationTransition.depth
            .animation(.easeInOut(duration: 0.9))

        XCTAssertEqual(transition.debugKind, .depth)
        XCTAssertEqual(transition.resolvedAnimation.duration, 0.9)
    }

    func testScaleUsesCollapseAndRevealTiming() {
        let animation = KVNavigationTransition.scale.resolvedAnimation

        XCTAssertEqual(animation.duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
    }

    func testSharedAxisUsesFlowTiming() {
        let animation = KVNavigationTransition.sharedAxis().resolvedAnimation

        XCTAssertEqual(animation.duration, 0.36, accuracy: 0.001)
        XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
    }

    func testRevealUsesRadialTiming() {
        let animation = KVNavigationTransition.reveal().resolvedAnimation

        XCTAssertEqual(animation.duration, 0.42, accuracy: 0.001)
        XCTAssertEqual(animation.debugTiming, .cubic(0.16, 1, 0.30, 1))
    }

    func testDepthUsesDollyTiming() {
        let animation = KVNavigationTransition.depth.resolvedAnimation

        XCTAssertEqual(animation.duration, 0.40, accuracy: 0.001)
        XCTAssertEqual(animation.debugTiming, .cubic(0.20, 0.80, 0.20, 1))
    }

    func testFlipUsesSymmetricCardTurnTiming() {
        let animation = KVNavigationTransition.flip3D().resolvedAnimation

        XCTAssertEqual(animation.duration, 0.50, accuracy: 0.001)
        XCTAssertEqual(animation.debugTiming, .cubic(0.65, 0, 0.35, 1))
    }

    func testCustomTransitionStoresPushAndMirroredPop() {
        let transition = KVNavigationTransition.custom(
            push: .init(
                incoming: .identity
                    .relativeOffset(x: 1)
                    .opacity(0),
                outgoing: .identity
                    .relativeOffset(x: -0.08)
                    .scale(0.97)
            ),
            pop: .mirrored,
            animation: .easeInOut(duration: 0.35)
        )

        XCTAssertEqual(transition.debugKind, .custom)
        XCTAssertTrue(transition.supportsInteractiveBack)
    }

    func testCustomTransitionCanDisableInteractiveBack() {
        let transition = KVNavigationTransition.custom(
            push: .init(incoming: .identity.opacity(0)),
            animation: .easeOut(duration: 0.2),
            interactiveBack: false
        )

        XCTAssertFalse(transition.supportsInteractiveBack)
    }

    func testViewStateCompositionKeepsPrimitiveOrder() {
        let state = KVTransitionViewState.identity
            .relativeOffset(x: 1)
            .scale(0.9)
            .rotation(.degrees(12))
            .opacity(0.5)

        XCTAssertEqual(state.primitives.count, 4)
    }
}
