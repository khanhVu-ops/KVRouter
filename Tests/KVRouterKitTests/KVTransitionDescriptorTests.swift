import SwiftUI
import XCTest
@testable import KVRouterKit

@MainActor
final class KVTransitionDescriptorTests: XCTestCase {
    func testSlidePushUsesFullIncomingAndSubtleOutgoingOffsets() {
        let descriptor = KVNavigationTransition.slide().descriptor(
            operation: .push,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.relativeOffset,
            CGSize(width: 1, height: 0)
        )
        XCTAssertEqual(
            descriptor.outgoing.relativeOffset,
            CGSize(width: -0.05, height: 0)
        )
    }

    func testSlidePopSwapsPushEndpointRoles() {
        let descriptor = KVNavigationTransition.slide().descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.relativeOffset,
            CGSize(width: -0.05, height: 0)
        )
        XCTAssertEqual(
            descriptor.outgoing.relativeOffset,
            CGSize(width: 1, height: 0)
        )
    }

    func testMirroredCustomPopSwapsPushRoles() {
        let transition = KVNavigationTransition.custom(
            push: .init(
                incoming: .identity.relativeOffset(x: 1).opacity(0),
                outgoing: .identity.relativeOffset(x: -0.08).scale(0.97)
            ),
            pop: .mirrored,
            animation: .easeInOut(duration: 0.35)
        )
        let descriptor = transition.descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(descriptor.incoming.relativeOffset.width, -0.08)
        XCTAssertEqual(descriptor.outgoing.relativeOffset.width, 1)
        XCTAssertEqual(descriptor.outgoing.opacity, 0)
    }

    func testExplicitCustomPopIsPreserved() {
        let explicitPop = KVTransitionStage(
            incoming: .identity.scale(0.95),
            outgoing: .identity.relativeOffset(x: -1)
        )
        let transition = KVNavigationTransition.custom(
            push: .init(incoming: .identity.opacity(0)),
            pop: .custom(explicitPop),
            animation: .easeOut(duration: 0.3)
        )

        let descriptor = transition.descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 0.95, height: 0.95))
        XCTAssertEqual(descriptor.outgoing.relativeOffset.width, -1)
    }

    func testReduceMotionCompilesToFadeOnly() {
        let descriptor = KVNavigationTransition.flip3D().descriptor(
            operation: .push,
            reduceMotion: true
        )

        XCTAssertEqual(descriptor.incoming.opacity, 0)
        XCTAssertTrue(descriptor.incoming.transforms.isEmpty)
        XCTAssertTrue(descriptor.outgoing.isIdentity)
        XCTAssertEqual(descriptor.animation.duration, 0.18)
    }

    func testPolishedPresetsReduceToFadeOnly() {
        let transitions: [KVNavigationTransition] = [
            .sharedAxis(),
            .reveal(),
            .depth,
        ]

        for transition in transitions {
            let descriptor = transition.descriptor(
                operation: .push,
                reduceMotion: true
            )
            XCTAssertEqual(descriptor.incoming.opacity, 0)
            XCTAssertTrue(descriptor.incoming.transforms.isEmpty)
            XCTAssertNil(descriptor.incoming.revealOrigin)
            XCTAssertTrue(descriptor.outgoing.isIdentity)
        }
    }

    func testRevealUsesRadialIncomingAndRecessedOutgoingStates() {
        let descriptor = KVNavigationTransition.reveal(
            origin: .topTrailing
        ).descriptor(operation: .push, reduceMotion: false)

        XCTAssertEqual(descriptor.incoming.revealOrigin, .topTrailing)
        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 1.025, height: 1.025)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0.2, accuracy: 0.001)
        XCTAssertNil(descriptor.outgoing.revealOrigin)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 0.975, height: 0.975)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0.78, accuracy: 0.001)
    }

    func testRevealPopContractsOutgoingMaskToOrigin() {
        let descriptor = KVNavigationTransition.reveal(
            origin: .bottomLeading
        ).descriptor(operation: .pop, reduceMotion: false)

        XCTAssertNil(descriptor.incoming.revealOrigin)
        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 0.975, height: 0.975)
        )
        XCTAssertEqual(descriptor.outgoing.revealOrigin, .bottomLeading)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 1.025, height: 1.025)
        )
    }

    func testSharedAxisPushUsesCohesiveHorizontalFlow() {
        let descriptor = KVNavigationTransition.sharedAxis().descriptor(
            operation: .push,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.relativeOffset,
            CGSize(width: 0.14, height: 0)
        )
        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 0.985, height: 0.985)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.relativeOffset,
            CGSize(width: -0.07, height: 0)
        )
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 0.985, height: 0.985)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0.58, accuracy: 0.001)
    }

    func testSharedAxisVerticalUsesYAxisAndPopMirrorsEndpoints() {
        let descriptor = KVNavigationTransition.sharedAxis(axis: .vertical).descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.relativeOffset,
            CGSize(width: 0, height: -0.07)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0.58, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.relativeOffset,
            CGSize(width: 0, height: 0.14)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
    }

    func testDepthPushUsesForegroundToBackgroundDolly() {
        let descriptor = KVNavigationTransition.depth.descriptor(
            operation: .push,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 1.09, height: 1.09)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 0.90, height: 0.90)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0.42, accuracy: 0.001)
    }

    func testDepthPopMirrorsDollyEndpoints() {
        let descriptor = KVNavigationTransition.depth.descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 0.90, height: 0.90)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0.42, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 1.09, height: 1.09)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
    }

    func testScalePushCollapsesOutgoingAndRevealsIncoming() {
        let descriptor = KVNavigationTransition.scale.descriptor(
            operation: .push,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 0.94, height: 0.94)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 0.84, height: 0.84)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(descriptor.incomingDelayFactor, 0.08, accuracy: 0.001)
        XCTAssertEqual(descriptor.outgoingDelayFactor, 0, accuracy: 0.001)
    }

    func testScalePopMirrorsCollapseAndRevealEndpoints() {
        let descriptor = KVNavigationTransition.scale.descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(
            descriptor.incoming.scale,
            CGSize(width: 0.84, height: 0.84)
        )
        XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(
            descriptor.outgoing.scale,
            CGSize(width: 0.94, height: 0.94)
        )
        XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
        XCTAssertEqual(descriptor.incomingDelayFactor, 0.08, accuracy: 0.001)
    }

    func testScaleReduceMotionRemovesEndpointDelays() {
        let descriptor = KVNavigationTransition.scale.descriptor(
            operation: .push,
            reduceMotion: true
        )

        XCTAssertEqual(descriptor.incomingDelayFactor, 0, accuracy: 0.001)
        XCTAssertEqual(descriptor.outgoingDelayFactor, 0, accuracy: 0.001)
    }

    func testFlipPushUsesTwoMatching180DegreeFaces() {
        let descriptor = KVNavigationTransition.flip3D().descriptor(
            operation: .push,
            reduceMotion: false
        )

        XCTAssertEqual(descriptor.incoming.rotation3DDegrees, 180, accuracy: 0.001)
        XCTAssertEqual(descriptor.outgoing.rotation3DDegrees, -180, accuracy: 0.001)
        XCTAssertEqual(descriptor.incoming.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(descriptor.outgoing.opacity, 1, accuracy: 0.001)

        let size = CGSize(width: 390, height: 844)
        let incoming = descriptor.incoming.state.resolved(containerSize: size)
        let outgoing = descriptor.outgoing.state.resolved(containerSize: size)
        XCTAssertEqual(
            incoming.transform.m34,
            outgoing.transform.m34,
            accuracy: 0.000_001
        )
        XCTAssertNotEqual(incoming.transform.m34, 0)
    }

    func testFlipPopReversesTheCardFaces() {
        let descriptor = KVNavigationTransition.flip3D().descriptor(
            operation: .pop,
            reduceMotion: false
        )

        XCTAssertEqual(descriptor.incoming.rotation3DDegrees, -180, accuracy: 0.001)
        XCTAssertEqual(descriptor.outgoing.rotation3DDegrees, 180, accuracy: 0.001)
    }

    func testHorizontalFlipRotatesAroundXAxis() {
        let descriptor = KVNavigationTransition.flip3D(axis: .horizontal).descriptor(
            operation: .push,
            reduceMotion: false
        )
        let resolved = descriptor.incoming.state.resolved(
            containerSize: CGSize(width: 390, height: 844)
        )

        XCTAssertEqual(resolved.transform.m11, 1, accuracy: 0.001)
        XCTAssertEqual(resolved.transform.m22, -1, accuracy: 0.001)
    }
}
