//
//  KVRouterSpy.swift
//  KVRouterTesting
//

import Foundation
import KVRouterCore

/// A recording ``KVRouting`` for unit tests.
///
/// Synchronous and dependency-free: no operation queue to drain, no middleware,
/// no SwiftUI. Inject it wherever production code takes `any KVRouting`.
///
/// ```swift
/// @MainActor
/// @Test func tapProductNavigatesToDetail() {
///     let router = KVRouterSpy()
///     let sut = ProductListViewModel(router: router)
///
///     sut.didTapProduct(42)
///
///     #expect(router.operations == [.push(AnyKVRoute(ShopRoute.productDetail(id: 42)))])
/// }
/// ```
///
/// The spy also keeps a simulated stack, so ``stackDepth`` and ``topRoute``
/// answer sensibly across a sequence of commands — enough to test code that
/// branches on "am I at the root?".
@MainActor
public final class KVRouterSpy: KVRouting {

    /// One recorded navigation command.
    public enum Operation: Equatable, Sendable {
        case push(AnyKVRoute)
        case replaceTop(AnyKVRoute)
        case setPath([AnyKVRoute])
        case pop
        case popCount(Int)
        case popToRoot
        case popTo(AnyKVRoute)
        /// ``KVRouting/popTo(where:)`` — the predicate itself is not comparable,
        /// so only the call is recorded.
        case popToMatching
    }

    /// Every command received, oldest first.
    public private(set) var operations: [Operation] = []

    /// The simulated stack above the root, oldest first.
    public private(set) var stack: [AnyKVRoute] = []

    /// - Parameter stack: Routes to pre-seed above the root, for tests that
    ///   start mid-flow.
    public init(stack: [any KVRoute] = []) {
        self.stack = stack.map(AnyKVRoute.init)
    }

    /// Clear recorded commands and the simulated stack.
    public func reset() {
        operations.removeAll()
        stack.removeAll()
    }

    /// Every route pushed so far whose concrete type is `R`, oldest first.
    public func pushed<R: KVRoute>(_ type: R.Type = R.self) -> [R] {
        operations.compactMap { operation in
            guard case .push(let route) = operation else { return nil }
            return route.unwrap(R.self)
        }
    }

    // MARK: - KVRouting

    public var stackDepth: Int { stack.count }

    public var topRoute: (any KVRoute)? { stack.last?.base }

    public func push(_ route: any KVRoute) {
        operations.append(.push(AnyKVRoute(route)))
        stack.append(AnyKVRoute(route))
    }

    public func replaceTop(with route: any KVRoute) {
        operations.append(.replaceTop(AnyKVRoute(route)))
        if stack.isEmpty {
            stack = [AnyKVRoute(route)]
        } else {
            stack[stack.count - 1] = AnyKVRoute(route)
        }
    }

    public func setPath(_ routes: [any KVRoute]) {
        let erased = routes.map(AnyKVRoute.init)
        operations.append(.setPath(erased))
        stack = erased
    }

    public func pop() {
        operations.append(.pop)
        if !stack.isEmpty { stack.removeLast() }
    }

    public func pop(count: Int) {
        operations.append(.popCount(count))
        stack.removeLast(min(max(count, 0), stack.count))
    }

    public func popToRoot() {
        operations.append(.popToRoot)
        stack.removeAll()
    }

    public func popTo(_ route: any KVRoute) {
        operations.append(.popTo(AnyKVRoute(route)))
        guard let index = stack.lastIndex(of: AnyKVRoute(route)) else { return }
        stack.removeSubrange(stack.index(after: index)...)
    }

    public func popTo(where predicate: @escaping (any KVRoute) -> Bool) {
        operations.append(.popToMatching)
        guard let index = stack.lastIndex(where: { predicate($0.base) }) else { return }
        stack.removeSubrange(stack.index(after: index)...)
    }
}
