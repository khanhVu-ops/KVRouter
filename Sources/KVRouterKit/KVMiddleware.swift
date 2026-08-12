//
//  KVMiddleware.swift
//  KVRouterKit
//

import SwiftUI

/// Middleware can mutate/redirect/deny a route (auth, feature flags, interstitial ads, …).
///
/// `@MainActor` because middleware runs as part of main-actor navigation
/// operations; hop to a background task inside a method if you need heavy work.
@MainActor
public protocol KVRouteMiddleware {
    func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute?
    func willPop(from: KVAppRoute?, to: KVAppRoute?) async -> Bool
}

public extension KVRouteMiddleware {
    func willPop(from: KVAppRoute?, to: KVAppRoute?) async -> Bool { true }
}

/// Debug logging for navigation (prints in DEBUG builds only).
public final class KVLoggingMiddleware: KVRouteMiddleware {
    public init() {}

    public func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? {
        #if DEBUG
        print("[KVRouter] navigate: \(String(describing: from)) -> \(to)")
        #endif
        return to
    }

    public func willPop(from: KVAppRoute?, to: KVAppRoute?) async -> Bool {
        #if DEBUG
        print("[KVRouter] pop: \(String(describing: from)) -> \(String(describing: to))")
        #endif
        return true
    }
}
