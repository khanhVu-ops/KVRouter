//
//  KVAppRouterTests.swift
//  KVRouter
//

import XCTest
import SwiftUI
@testable import KVRouter

@MainActor
final class KVAppRouterTests: XCTestCase {

    // Router mutations are scheduled via Task { @MainActor }, so tests poll
    // until the expected state lands (or the timeout expires).
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - Push / Pop

    func testPushAppendsRoute() async {
        let router = KVAppRouter()
        router.push(.appFeature("home"))
        await waitUntil { router.path == [.appFeature("home")] }
        XCTAssertEqual(router.path, [.appFeature("home")])
    }

    func testPopRemovesTopRoute() async {
        let router = KVAppRouter()
        router.push(.appFeature("a"))
        router.push(.appFeature("b"))
        await waitUntil { router.path.count == 2 }

        router.pop()
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.appFeature("a")])
    }

    func testPopToRootClearsPath() async {
        let router = KVAppRouter()
        router.push(.appFeature("a"))
        router.push(.appFeature("b"))
        router.push(.appFeature("c"))
        await waitUntil { router.path.count == 3 }

        router.popToRoot()
        await waitUntil { router.path.isEmpty }
        XCTAssertTrue(router.path.isEmpty)
    }

    func testPopToSpecificRoute() async {
        let router = KVAppRouter()
        router.setPath([.appFeature("a"), .appFeature("b"), .appFeature("c")])
        await waitUntil { router.path.count == 3 }

        router.popTo(.appFeature("a"))
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.appFeature("a")])
    }

    func testPopCount() async {
        let router = KVAppRouter()
        router.setPath([.appFeature("a"), .appFeature("b"), .appFeature("c")])
        await waitUntil { router.path.count == 3 }

        router.pop(count: 2)
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.appFeature("a")])
    }

    func testReplaceTop() async {
        let router = KVAppRouter()
        router.push(.appFeature("a"))
        await waitUntil { router.path.count == 1 }

        router.replaceTop(with: .appFeature("b"))
        await waitUntil { router.path == [.appFeature("b")] }
        XCTAssertEqual(router.path, [.appFeature("b")])
    }

    func testRestorePathDropsCustomViewRoutes() async {
        let router = KVAppRouter()
        router.restorePath([.appFeature("a"), .customView(UUID()), .appFeature("b")])
        await waitUntil { router.path.count == 2 }
        XCTAssertEqual(router.path, [.appFeature("a"), .appFeature("b")])
    }

    // MARK: - Operation Ordering

    /// Middleware that is slow only for the first route — without the FIFO
    /// operation queue, the second push would land before the first.
    private struct SlowFirstMiddleware: KVRouteMiddleware {
        func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? {
            if to == .appFeature("slow") {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return to
        }
    }

    func testConsecutivePushesKeepOrderWithAsyncMiddleware() async {
        let router = KVAppRouter(middlewares: [SlowFirstMiddleware()])
        router.push(.appFeature("slow"))
        router.push(.appFeature("fast"))
        await waitUntil { router.path.count == 2 }
        XCTAssertEqual(router.path, [.appFeature("slow"), .appFeature("fast")])
    }

    // MARK: - Middleware

    private struct RedirectMiddleware: KVRouteMiddleware {
        func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? {
            if to == .appFeature("blocked") { return .appFeature("login") }
            return to
        }
    }

    private struct DenyAllMiddleware: KVRouteMiddleware {
        func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? { nil }
        func willPop(from: KVAppRoute?, to: KVAppRoute?) async -> Bool { false }
        func willDismiss(sheet: KVSheetRoute?, fullCover: KVFullCoverRoute?) async -> Bool { false }
    }

    func testMiddlewareRedirectsRoute() async {
        let router = KVAppRouter(middlewares: [RedirectMiddleware()])
        router.push(.appFeature("blocked"))
        await waitUntil { !router.path.isEmpty }
        XCTAssertEqual(router.path, [.appFeature("login")])
    }

    func testMiddlewareCancelsPush() async {
        let router = KVAppRouter(middlewares: [DenyAllMiddleware()])
        router.push(.appFeature("anything"))
        // Give the scheduled task time to run, then confirm nothing was pushed.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(router.path.isEmpty)
    }

    func testMiddlewareCancelsSheetDismiss() async {
        let router = KVAppRouter(middlewares: [DenyAllMiddleware()])
        router.presentSheet { Text("Sheet") }
        await waitUntil { router.sheet != nil }

        router.dismissSheet()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(router.sheet, "Dismiss middleware returning false should keep the sheet presented")
    }

    // MARK: - Sheets & Full Covers

    func testPresentAndDismissSheet() async {
        let router = KVAppRouter()
        router.presentSheet { Text("Sheet") }
        await waitUntil { router.sheet != nil }
        XCTAssertNotNil(router.sheet)

        router.dismissSheet()
        await waitUntil { router.sheet == nil }
        XCTAssertNil(router.sheet)
    }

    func testPresentFullCoverDismissesSheetFirst() async {
        let router = KVAppRouter()
        router.presentSheet { Text("Sheet") }
        await waitUntil { router.sheet != nil }

        router.presentFullCover { Text("Cover") }
        await waitUntil { router.fullCover != nil }
        XCTAssertNil(router.sheet)
        XCTAssertNotNil(router.fullCover)
    }

    // MARK: - Deep Link

    func testDeepLinkIgnoredWithoutBuilder() async {
        let router = KVAppRouter()
        router.handle(url: URL(string: "myapp://profile/123")!)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(router.path.isEmpty)
    }

    func testDeepLinkPushesWhenBuilderResolves() async {
        let router = KVAppRouter()
        router.deepLinkViewBuilder = { payload in
            payload.hasPrefix("profile") ? AnyView(Text("Profile")) : nil
        }

        router.handle(url: URL(string: "myapp://profile/123?ref=home")!)
        await waitUntil { !router.path.isEmpty }
        XCTAssertEqual(router.path, [.deepLink("profile/123?ref=home")])
    }
}
