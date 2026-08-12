//
//  KVMiddleware.swift
//  KVRouterKit
//

import SwiftUI
import KVRouterCore

/// Middleware can mutate/redirect/deny a route (auth, feature flags, interstitial ads, …).
///
/// `@MainActor` because middleware runs as part of main-actor navigation
/// operations; hop to a background task inside a method if you need heavy work.
@MainActor
public protocol KVRouteMiddleware {
    func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)?
    func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool
}

public extension KVRouteMiddleware {
    func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool { true }
}

/// Debug logging for navigation (prints in DEBUG builds only).
public final class KVLoggingMiddleware: KVRouteMiddleware {
    public init() {}

    public func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
        #if DEBUG
        print("[KVRouter] navigate: \(String(describing: from)) -> \(to)")
        #endif
        return to
    }

    public func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool {
        #if DEBUG
        print("[KVRouter] pop: \(String(describing: from)) -> \(String(describing: to))")
        #endif
        return true
    }
}
