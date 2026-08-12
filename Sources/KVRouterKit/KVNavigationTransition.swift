import SwiftUI
import UIKit

public enum KVTransitionOperation: Sendable, Equatable {
    case push
    case pop
}

public enum KVFlip3DAxis: Sendable {
    case horizontal
    case vertical
}

public struct KVTransitionAnimation: Sendable, Equatable {
    public enum Timing: Sendable, Equatable {
        case cubic(Double, Double, Double, Double)
        case spring(dampingRatio: Double, initialVelocity: Double)
    }

    public let duration: TimeInterval
    let timing: Timing

    init(duration: TimeInterval, timing: Timing) {
        self.duration = max(0, duration)
        self.timing = timing
    }

    public static func easeInOut(duration: TimeInterval) -> Self {
        timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }

    public static func easeOut(duration: TimeInterval) -> Self {
        timingCurve(0, 0, 0.58, 1, duration: duration)
    }

    public static func linear(duration: TimeInterval) -> Self {
        timingCurve(0, 0, 1, 1, duration: duration)
    }

    public static func timingCurve(
        _ c0x: Double,
        _ c0y: Double,
        _ c1x: Double,
        _ c1y: Double,
        duration: TimeInterval
    ) -> Self {
        Self(
            duration: duration,
            timing: .cubic(c0x, c0y, c1x, c1y)
        )
    }

    public static func spring(
        response: TimeInterval,
        dampingFraction: Double,
        blendDuration: TimeInterval = 0
    ) -> Self {
        _ = blendDuration
        return Self(
            duration: response,
            timing: .spring(
                dampingRatio: min(max(dampingFraction, 0), 1),
                initialVelocity: 0
            )
        )
    }

    var debugTiming: Timing { timing }

    @MainActor
    var timingParameters: UITimingCurveProvider {
        switch timing {
        case .cubic(let c0x, let c0y, let c1x, let c1y):
            return UICubicTimingParameters(
                controlPoint1: CGPoint(x: c0x, y: c0y),
                controlPoint2: CGPoint(x: c1x, y: c1y)
            )
        case .spring(let dampingRatio, let initialVelocity):
            return UISpringTimingParameters(
                dampingRatio: dampingRatio,
                initialVelocity: CGVector(
                    dx: initialVelocity,
                    dy: initialVelocity
                )
            )
        }
    }

}

struct KVTransitionAxis3D: Sendable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let z: CGFloat
}

enum KVTransitionPrimitive: Sendable, Equatable {
    case opacity(CGFloat)
    case offset(CGSize)
    case relativeOffset(CGSize)
    case scale(CGSize)
    case rotation(Double)
    case rotation3D(
        angle: Double,
        axis: KVTransitionAxis3D,
        perspective: CGFloat
    )
    case cornerRadius(CGFloat)
    case zPosition(CGFloat)
    case reveal(UnitPoint)
}

public struct KVTransitionViewState: Sendable, Equatable {
    let primitives: [KVTransitionPrimitive]

    public static let identity = Self()

    public init() {
        primitives = []
    }

    private init(primitives: [KVTransitionPrimitive]) {
        self.primitives = primitives
    }

    public func opacity(_ value: CGFloat) -> Self {
        appending(.opacity(value))
    }

    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> Self {
        appending(.offset(CGSize(width: x, height: y)))
    }

    public func relativeOffset(x: CGFloat = 0, y: CGFloat = 0) -> Self {
        appending(.relativeOffset(CGSize(width: x, height: y)))
    }

    public func scale(_ value: CGFloat) -> Self {
        scale(x: value, y: value)
    }

    public func scale(x: CGFloat, y: CGFloat) -> Self {
        appending(.scale(CGSize(width: x, height: y)))
    }

    public func rotation(_ angle: Angle) -> Self {
        appending(.rotation(angle.radians))
    }

    public func rotation3D(
        _ angle: Angle,
        axis: (x: CGFloat, y: CGFloat, z: CGFloat),
        perspective: CGFloat = 1
    ) -> Self {
        appending(.rotation3D(
            angle: angle.radians,
            axis: KVTransitionAxis3D(x: axis.x, y: axis.y, z: axis.z),
            perspective: perspective
        ))
    }

    public func cornerRadius(_ value: CGFloat) -> Self {
        appending(.cornerRadius(value))
    }

    public func zPosition(_ value: CGFloat) -> Self {
        appending(.zPosition(value))
    }

    public func reveal(from origin: UnitPoint) -> Self {
        appending(.reveal(origin))
    }

    private func appending(_ primitive: KVTransitionPrimitive) -> Self {
        Self(primitives: primitives + [primitive])
    }
}

public struct KVTransitionStage: Sendable, Equatable {
    public let incoming: KVTransitionViewState
    public let outgoing: KVTransitionViewState

    public init(
        incoming: KVTransitionViewState,
        outgoing: KVTransitionViewState = .identity
    ) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

public enum KVPopTransition: Sendable, Equatable {
    case mirrored
    case custom(KVTransitionStage)
}

struct KVCustomTransitionSpec: Sendable, Equatable {
    let push: KVTransitionStage
    let pop: KVPopTransition
    let animation: KVTransitionAnimation
    let interactiveBack: Bool
}

@MainActor
public struct KVNavigationTransition {
    enum Kind {
        case system
        case slide(Edge)
        case fade
        case scale
        case scaleAndFade
        case sharedAxis(Axis)
        case depth
        case reveal(UnitPoint)
        case flip3D(KVFlip3DAxis)
        case zoom(AnyHashable)
        case custom(KVCustomTransitionSpec)
    }

    enum DebugKind: Equatable {
        case system
        case slide
        case fade
        case scale
        case scaleAndFade
        case sharedAxis
        case depth
        case reveal
        case flip3D
        case zoom
        case custom
    }

    let kind: Kind
    let animationOverride: KVTransitionAnimation?

    public static let system = Self(kind: .system, animationOverride: nil)
    public static let fade = Self(kind: .fade, animationOverride: nil)
    public static let scale = Self(kind: .scale, animationOverride: nil)
    public static let scaleAndFade = Self(kind: .scaleAndFade, animationOverride: nil)
    public static let depth = Self(kind: .depth, animationOverride: nil)

    public static func slide(edge: Edge = .trailing) -> Self {
        Self(kind: .slide(edge), animationOverride: nil)
    }

    public static func sharedAxis(axis: Axis = .horizontal) -> Self {
        Self(kind: .sharedAxis(axis), animationOverride: nil)
    }

    public static func reveal(origin: UnitPoint = .topTrailing) -> Self {
        Self(kind: .reveal(origin), animationOverride: nil)
    }

    public static func flip3D(axis: KVFlip3DAxis = .vertical) -> Self {
        Self(kind: .flip3D(axis), animationOverride: nil)
    }

    public static func zoom<ID: Hashable>(sourceID: ID) -> Self {
        Self(kind: .zoom(AnyHashable(sourceID)), animationOverride: nil)
    }

    public static func custom(
        push: KVTransitionStage,
        pop: KVPopTransition = .mirrored,
        animation: KVTransitionAnimation,
        interactiveBack: Bool = true
    ) -> Self {
        Self(
            kind: .custom(KVCustomTransitionSpec(
                push: push,
                pop: pop,
                animation: animation,
                interactiveBack: interactiveBack
            )),
            animationOverride: nil
        )
    }

    public func animation(_ animation: KVTransitionAnimation) -> Self {
        Self(kind: kind, animationOverride: animation)
    }

    var resolvedAnimation: KVTransitionAnimation {
        if let animationOverride { return animationOverride }

        switch kind {
        case .system:
            return .easeInOut(duration: 0.35)
        case .fade:
            return .easeOut(duration: 0.24)
        case .slide:
            return .timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
        case .sharedAxis:
            return .timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
        case .scale:
            return .timingCurve(0.22, 1, 0.36, 1, duration: 0.34)
        case .scaleAndFade:
            return .easeOut(duration: 0.3)
        case .reveal:
            return .timingCurve(0.16, 1, 0.30, 1, duration: 0.42)
        case .depth:
            return .timingCurve(0.20, 0.80, 0.20, 1, duration: 0.40)
        case .zoom:
            return .spring(response: 0.38, dampingFraction: 0.94)
        case .flip3D:
            return .timingCurve(0.65, 0, 0.35, 1, duration: 0.50)
        case .custom(let custom):
            return custom.animation
        }
    }

    var supportsInteractiveBack: Bool {
        switch kind {
        case .system:
            return false
        case .custom(let custom):
            return custom.interactiveBack
        default:
            return true
        }
    }

    var debugKind: DebugKind {
        switch kind {
        case .system: .system
        case .slide: .slide
        case .fade: .fade
        case .scale: .scale
        case .scaleAndFade: .scaleAndFade
        case .sharedAxis: .sharedAxis
        case .depth: .depth
        case .reveal: .reveal
        case .flip3D: .flip3D
        case .zoom: .zoom
        case .custom: .custom
        }
    }
}
