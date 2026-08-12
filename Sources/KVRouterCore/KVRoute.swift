//
//  KVRoute.swift
//  KVRouterCore
//

import Foundation

/// A destination the router can navigate to.
///
/// Routes are plain values: declare them in whichever layer owns the navigation
/// intent (feature module, presentation layer) without importing SwiftUI. The
/// mapping from route to view lives in the composition root — see
/// `KVRouteRegistry` in `KVRouterKit`.
///
/// ```swift
/// enum ShopRoute: KVRoute {
///     case productDetail(id: Int)
///     case cart
/// }
///
/// router.push(ShopRoute.productDetail(id: 42))
/// ```
public protocol KVRoute: Hashable, Sendable {}

/// A type-erased ``KVRoute``, for storing routes of mixed concrete types in one
/// collection (the navigation stack) and for comparing them in assertions.
public struct AnyKVRoute: Hashable, Sendable {

    /// The wrapped route. Recover the concrete type with ``unwrap(_:)``.
    public let base: any KVRoute

    /// Deliberately not itself a ``KVRoute``: leaving it outside the protocol
    /// makes nested erasure unrepresentable, so equality never has to reason
    /// about how many layers of wrapping two routes carry.
    public init(_ base: any KVRoute) {
        self.base = base
    }

    /// The wrapped route as `R`, or `nil` if it is a different concrete type.
    public func unwrap<R: KVRoute>(_ type: R.Type = R.self) -> R? {
        base as? R
    }

    // `AnyHashable` is computed rather than stored: it is not `Sendable`, and
    // storing it would forfeit this type's `Sendable` conformance.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        AnyHashable(lhs.base) == AnyHashable(rhs.base)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(base))
    }
}

/// A route that survives being persisted and decoded — i.e. it can take part in
/// state restoration.
///
/// Routes backed by an in-memory view builder (``KVViewRouting/pushView(tag:_:)``)
/// cannot conform: their view exists only for the lifetime of the process.
public protocol KVRestorableRoute: KVRoute, Codable {

    /// Stable key used to pick the right decoder when restoring a persisted path.
    ///
    /// Defaults to the fully qualified type name. Override it when you rename
    /// the type but need previously persisted paths to keep decoding.
    static var restorationID: String { get }
}

public extension KVRestorableRoute {
    static var restorationID: String { String(reflecting: Self.self) }
}
