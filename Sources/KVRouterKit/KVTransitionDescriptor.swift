import SwiftUI

struct KVTransitionDescriptor {
    let incoming: KVTransitionEndpoint
    let outgoing: KVTransitionEndpoint
    let animation: KVTransitionAnimation
    let supportsInteractiveBack: Bool
    let incomingDelayFactor: CGFloat
    let outgoingDelayFactor: CGFloat

    init(
        incoming: KVTransitionEndpoint,
        outgoing: KVTransitionEndpoint,
        animation: KVTransitionAnimation,
        supportsInteractiveBack: Bool,
        incomingDelayFactor: CGFloat = 0,
        outgoingDelayFactor: CGFloat = 0
    ) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.animation = animation
        self.supportsInteractiveBack = supportsInteractiveBack
        self.incomingDelayFactor = incomingDelayFactor
        self.outgoingDelayFactor = outgoingDelayFactor
    }
}

struct KVTransitionEndpoint {
    let state: KVTransitionViewState
}

@MainActor
extension KVNavigationTransition {
    func descriptor(
        operation: KVTransitionOperation,
        reduceMotion: Bool
    ) -> KVTransitionDescriptor {
        if reduceMotion {
            return KVTransitionDescriptor(
                incoming: KVTransitionEndpoint(state: .identity.opacity(0)),
                outgoing: KVTransitionEndpoint(state: .identity),
                animation: .easeInOut(duration: 0.18),
                supportsInteractiveBack: supportsInteractiveBack
            )
        }

        let push = pushStage
        let stage: KVTransitionStage

        switch operation {
        case .push:
            stage = push
        case .pop:
            if case .custom(let custom) = kind,
               case .custom(let explicitPop) = custom.pop {
                stage = explicitPop
            } else {
                stage = KVTransitionStage(
                    incoming: push.outgoing,
                    outgoing: push.incoming
                )
            }
        }

        let incomingDelayFactor: CGFloat
        if case .scale = kind {
            incomingDelayFactor = 0.08
        } else {
            incomingDelayFactor = 0
        }

        return KVTransitionDescriptor(
            incoming: KVTransitionEndpoint(state: stage.incoming),
            outgoing: KVTransitionEndpoint(state: stage.outgoing),
            animation: resolvedAnimation,
            supportsInteractiveBack: supportsInteractiveBack,
            incomingDelayFactor: incomingDelayFactor
        )
    }

    private var pushStage: KVTransitionStage {
        switch kind {
        case .system:
            return KVTransitionStage(incoming: .identity)
        case .fade:
            return KVTransitionStage(incoming: .identity.opacity(0))
        case .scale:
            return KVTransitionStage(
                incoming: .identity.scale(0.94).opacity(0),
                outgoing: .identity.scale(0.84).opacity(0)
            )
        case .scaleAndFade, .zoom:
            return KVTransitionStage(
                incoming: .identity.scale(0.94).opacity(0),
                outgoing: .identity.scale(0.98).opacity(0.92)
            )
        case .slide(let edge):
            let vector = edge.kvTransitionVector
            return KVTransitionStage(
                incoming: .identity.relativeOffset(
                    x: vector.width,
                    y: vector.height
                ),
                outgoing: .identity.relativeOffset(
                    x: -0.05 * vector.width,
                    y: -0.05 * vector.height
                )
            )
        case .sharedAxis(let axis):
            let vector = axis == .horizontal
                ? CGSize(width: 1, height: 0)
                : CGSize(width: 0, height: 1)
            return KVTransitionStage(
                incoming: .identity
                    .relativeOffset(
                        x: 0.14 * vector.width,
                        y: 0.14 * vector.height
                    )
                    .scale(0.985)
                    .opacity(0),
                outgoing: .identity
                    .relativeOffset(
                        x: -0.07 * vector.width,
                        y: -0.07 * vector.height
                    )
                    .scale(0.985)
                    .opacity(0.58)
            )
        case .depth:
            return KVTransitionStage(
                incoming: .identity.scale(1.09).opacity(0),
                outgoing: .identity.scale(0.90).opacity(0.42)
            )
        case .reveal(let origin):
            return KVTransitionStage(
                incoming: .identity
                    .scale(1.025)
                    .opacity(0.2)
                    .reveal(from: origin),
                outgoing: .identity
                    .scale(0.975)
                    .opacity(0.78)
            )
        case .pageTurn(let edge):
            let page = edge.kvPageGeometry
            return KVTransitionStage(
                // Starts standing on its spine with the free edge toward the
                // viewer, then lays flat. No opacity ramp: paper is opaque, and
                // back-face culling already hides it while it is edge-on.
                incoming: .identity
                    .anchor(page.spine)
                    .rotation3D(
                        .degrees(page.liftAngle),
                        axis: page.axis,
                        perspective: 0.55
                    ),
                // The page underneath, shaded by the one turning over it.
                outgoing: .identity
                    .scale(0.965)
                    .opacity(0.55)
            )
        case .flip3D(let axis):
            let vector: (x: CGFloat, y: CGFloat, z: CGFloat) = axis == .vertical
                ? (0, 1, 0)
                : (1, 0, 0)
            return KVTransitionStage(
                incoming: .identity
                    .rotation3D(
                        .degrees(180),
                        axis: vector,
                        perspective: 1
                    ),
                outgoing: .identity
                    .rotation3D(
                        .degrees(-180),
                        axis: vector,
                        perspective: 1
                    )
            )
        case .custom(let custom):
            return custom.push
        }
    }
}

extension Edge {

    /// Where a page pivots and which way it swings, for
    /// ``KVNavigationTransition/pageTurn(edge:)``.
    ///
    /// The spine is the opposite edge from the one the page lifts at, and the
    /// sign of `liftAngle` is what sends the free edge toward the viewer rather
    /// than away behind the screen.
    var kvPageGeometry: (
        spine: UnitPoint,
        axis: (x: CGFloat, y: CGFloat, z: CGFloat),
        liftAngle: Double
    ) {
        switch self {
        case .trailing:
            return (UnitPoint(x: 0, y: 0.5), (0, 1, 0), -92)
        case .leading:
            return (UnitPoint(x: 1, y: 0.5), (0, 1, 0), 92)
        case .top:
            return (UnitPoint(x: 0.5, y: 1), (1, 0, 0), 92)
        case .bottom:
            return (UnitPoint(x: 0.5, y: 0), (1, 0, 0), -92)
        }
    }
}

private extension Edge {
    var kvTransitionVector: CGSize {
        switch self {
        case .leading:
            CGSize(width: -1, height: 0)
        case .trailing:
            CGSize(width: 1, height: 0)
        case .top:
            CGSize(width: 0, height: -1)
        case .bottom:
            CGSize(width: 0, height: 1)
        }
    }
}
