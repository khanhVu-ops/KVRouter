//
//  KVMiddleware.swift
//  KVRouter
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
    func willDismiss(sheet: KVSheetRoute?, fullCover: KVFullCoverRoute?) async -> Bool
}

public extension KVRouteMiddleware {
    func willPop(from: KVAppRoute?, to: KVAppRoute?) async -> Bool { true }
    func willDismiss(sheet: KVSheetRoute?, fullCover: KVFullCoverRoute?) async -> Bool { true }
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

    public func willDismiss(sheet: KVSheetRoute?, fullCover: KVFullCoverRoute?) async -> Bool {
        #if DEBUG
        if let sheet = sheet {
            print("[KVRouter] dismiss sheet: \(sheet)")
        }
        if let fullCover = fullCover {
            print("[KVRouter] dismiss fullCover: \(fullCover)")
        }
        #endif
        return true
    }
}
