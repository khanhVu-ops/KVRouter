//
//  KVAppRouter+KVRouting.swift
//  KVRouterKit
//

import SwiftUI
import KVRouterCore

// MARK: - ================================
// MARK: View-Layer Port
// MARK: ================================

/// Everything ``KVRouting`` has, plus the commands that only make sense where
/// views exist: building a destination inline, and choosing an animation.
///
/// Inject `any KVRouting` into a ViewModel and `any KVViewRouting` into view
/// code. Both are mockable; the narrower one is what keeps SwiftUI out of the
/// presentation layer.
@MainActor
public protocol KVViewRouting: KVRouting {

    func push(_ route: any KVRoute, transition: KVNavigationTransition)

    func replaceTop(with route: any KVRoute, transition: KVNavigationTransition)

    func pushView<V: View>(tag: String?, _ build: @escaping () -> V)

    func pushView<V: View>(
        tag: String?,
        transition: KVNavigationTransition,
        _ build: @escaping () -> V
    )

    func replaceTopWithView<V: View>(tag: String?, _ build: @escaping () -> V)

    /// Pop back to the nearest screen below pushed with this tag.
    ///
    /// Tags come from `pushView(tag:)`, which is why this is here rather than on
    /// ``KVRouting``: a typed route needs no tag, `popTo(_:)` already finds it.
    func popTo(tag: String)

    /// Pop back to the nearest screen below built from this view type.
    func popTo<V: View>(_ viewType: V.Type)
}

// MARK: - ================================
// MARK: Conformance
// MARK: ================================

// The declarations live on `KVAppRouter` itself; both protocols are satisfied
// as written, so there is nothing to bridge.
extension KVAppRouter: KVViewRouting {

    /// Number of screens above the root.
    ///
    /// - Important: A snapshot, not an observable property.
    public var stackDepth: Int {
        navigationEntries.count
    }

    /// The route on top of the stack, or `nil` at the root.
    ///
    /// - Important: A snapshot, not an observable property.
    public var topRoute: (any KVRoute)? {
        navigationEntries.last?.route.base
    }
}
