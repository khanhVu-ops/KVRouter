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

    var opacity: CGFloat {
        state.primitives.reversed().compactMap { primitive -> CGFloat? in
            guard case .opacity(let value) = primitive else { return nil }
            return value
        }.first ?? 1
    }

    var relativeOffset: CGSize {
        state.primitives.reduce(.zero) { result, primitive in
            guard case .relativeOffset(let value) = primitive else { return result }
            return CGSize(
                width: result.width + value.width,
                height: result.height + value.height
            )
        }
    }

    var scale: CGSize {
        state.primitives.reduce(CGSize(width: 1, height: 1)) { result, primitive in
            guard case .scale(let value) = primitive else { return result }
            return CGSize(
                width: result.width * value.width,
                height: result.height * value.height
            )
        }
    }

    var revealOrigin: UnitPoint? {
        state.primitives.reversed().compactMap { primitive -> UnitPoint? in
            guard case .reveal(let origin) = primitive else { return nil }
            return origin
        }.first
    }

    var rotation3DDegrees: Double {
        state.primitives.reversed().compactMap { primitive -> Double? in
            guard case .rotation3D(let angle, _, _) = primitive else { return nil }
            return angle * 180 / .pi
        }.first ?? 0
    }

    var transforms: [KVTransitionPrimitive] {
        state.primitives.filter { primitive in
            switch primitive {
            case .offset, .relativeOffset, .scale, .rotation, .rotation3D:
                return true
            case .opacity, .cornerRadius, .zPosition, .reveal:
                return false
            }
        }
    }

    var isIdentity: Bool { state.primitives.isEmpty }
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
        case .push, .replace:
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
