//
//  KVTransitionEndpoint+Assertions.swift
//  KVRouterKit
//
//  Readable views over a descriptor endpoint, for assertions. These lived in
//  KVTransitionDescriptor.swift until 3.0 even though nothing in Sources called
//  them — the animator works off `state` directly.
//

import SwiftUI
@testable import KVRouterKit

extension KVTransitionEndpoint {

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
