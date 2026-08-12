import XCTest
import KVRouterCore
@testable import KVRouterKit

private final class RecordingDriver: KVTransitionDriving {
    var requests: [KVTransitionRequest] = []

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        requests.append(request)
        mutation()
    }
}

@MainActor
private final class SuspendedDriver: KVTransitionDriving {
    private(set) var requests: [KVTransitionRequest] = []
    private(set) var mutationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        requests.append(request)
        mutation()
        mutationCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class KVNavigationEntryTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testDuplicateRoutesReceiveDifferentEntryIDs() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("detail"), transition: .fade)
        router.push(TestRoute.screen("detail"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }

        XCTAssertNotEqual(router.navigationEntries[0].id, router.navigationEntries[1].id)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[0])?.debugKind, .fade)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[1])?.debugKind, .depth)
    }

    func testDirectPathAssignmentReusesCommonPrefix() {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let originalA = router.navigationEntries[0].id

        router.path = [.screen("a"), .screen("c")]

        XCTAssertEqual(router.navigationEntries[0].id, originalA)
        XCTAssertEqual(router.navigationEntries.map(\.route), [.screen("a"), .screen("c")])
        XCTAssertNil(router.transitionOverride(for: router.navigationEntries[1]))
    }

    func testSystemPopRemovesEntryMetadata() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"), transition: .fade)
        router.push(TestRoute.screen("b"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }
        let removed = router.navigationEntries[1]

        router.navigationEntries = [router.navigationEntries[0]]

        XCTAssertNil(router.transitionOverride(for: removed))
        XCTAssertEqual(router.path, [.screen("a")])
    }

    func testRouterSendsPushAndPopThroughDriver() async {
        let router = KVAppRouter()
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.push(TestRoute.screen("detail"), transition: .depth)
        await waitUntil { router.path.count == 1 }
        router.pop()
        await waitUntil { router.path.isEmpty }

        XCTAssertEqual(driver.requests.map(\.operation), [.push, .pop])
        XCTAssertEqual(driver.requests.first?.transitionOverride?.debugKind, .depth)
    }

    func testRouterWaitsForTransitionCompletionAndMutatesOnce() async {
        let router = KVAppRouter()
        router.path = [.screen("detail")]
        let driver = SuspendedDriver()
        router.transitionDriver = driver

        router.pop()
        await waitUntil { driver.mutationCount == 1 }
        router.push(TestRoute.screen("next"), transition: .fade)
        await Task.yield()

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(driver.requests.count, 1)
        XCTAssertEqual(driver.mutationCount, 1)

        driver.resume()
        await waitUntil { driver.requests.count == 2 }

        XCTAssertEqual(driver.mutationCount, 2)
        driver.resume()
    }

    /// A replace cannot be animated, so it does not go through the driver.
    ///
    /// The custom animator hangs off `UINavigationControllerDelegate`, and
    /// SwiftUI does not hand UIKit a same-depth stack mutation for a changed top
    /// entry, so the delegate is never asked. 2.x accepted a `transition:` here
    /// and silently ignored it; 3.0 does not offer one.
    func testReplaceTopBypassesCustomTransitionDriver() async {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.replaceTop(with: TestRoute.screen("c"))
        await waitUntil { router.path.last == .screen("c") }

        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertEqual(router.path, [.screen("a"), .screen("c")])
    }

    /// A bulk pop still bypasses the driver: only single-screen changes have a
    /// UIKit operation to animate against.
    func testBulkPopBypassesCustomTransitionDriver() async {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b"), .screen("c")]
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.popToRoot()
        await waitUntil { router.path.isEmpty }

        XCTAssertTrue(driver.requests.isEmpty)
    }
}
