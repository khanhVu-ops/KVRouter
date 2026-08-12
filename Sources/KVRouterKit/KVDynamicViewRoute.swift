//
//  KVDynamicViewRoute.swift
//  KVRouterKit
//

import Foundation
import KVRouterCore

/// The route behind `pushView { }`: a screen whose view is a closure held by the
/// router, rather than a value the route registry can map to a destination.
///
/// Deliberately not a ``KVRestorableRoute`` — the closure lives only as long as
/// the process, so a decoded copy would have nothing to build.
///
/// Being an ordinary ``KVRoute`` is what lets the rest of the router treat
/// dynamic screens and typed routes the same way; only view building has to
/// tell them apart.
struct KVDynamicViewRoute: KVRoute {

    /// Key into the router's builder registry.
    let id: UUID

    /// Caller-chosen tag from `pushView(tag:)`, for ``KVViewRouting/popTo(tag:)``.
    let tag: String?

    /// Fully qualified name of the concrete view type, e.g. `MyApp.DetailView`,
    /// for `popTo(SomeView.self)`.
    let typeName: String

    // Identity is the id alone: tag and type name describe the same screen, so
    // including them would let two references to one screen compare unequal.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
