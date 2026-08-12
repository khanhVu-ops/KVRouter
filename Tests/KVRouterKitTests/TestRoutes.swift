//
//  TestRoutes.swift
//  KVRouterKit
//
//  Shared route fixtures. 3.0 has no built-in route enum — every app declares
//  its own — so the suite declares one too.
//

import Foundation
import KVRouterCore
@testable import KVRouterKit

/// Stands in for an app's route enum.
enum TestRoute: KVRoute {
    case screen(String)

    var name: String {
        switch self {
        case .screen(let name): return name
        }
    }
}

/// A second, unrelated route type — for asserting that identically shaped routes
/// of different types never compare equal.
enum OtherTestRoute: KVRoute {
    case screen(String)
}

extension AnyKVRoute {
    /// Sugar so stack assertions stay readable: `router.path == [.screen("a")]`.
    static func screen(_ name: String) -> AnyKVRoute {
        AnyKVRoute(TestRoute.screen(name))
    }
}

extension KVAppRouter {
    /// The stack as plain names, for assertions that do not care about types.
    var screenNames: [String] {
        routes.compactMap { ($0 as? TestRoute)?.name }
    }
}

/// A route that opts into persistence, for asserting the restorable/not-restorable
/// distinction.
struct TestRestorableRoute: KVRestorableRoute {
    let id: String
}
