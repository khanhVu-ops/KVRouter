# KVRouterKit Navigation Transitions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the package to KVRouterKit and add selectable, customizable push/pop transitions with native iOS 18 zoom and a custom iOS 16-17 hero fallback.

**Architecture:** Keep `NavigationStack` as the source of truth, but route every programmatic path mutation through a host-owned transition driver. Native `.system` and iOS 18 `.zoom` mutate the stack normally; all other styles use a progress-driven overlay coordinator with bounded in-memory snapshots and an interactive leading-edge pop gesture.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, UIKit for internal snapshot capture, XCTest, Swift Package Manager, Xcode build tooling.

---

## File Structure

After the rename, use these responsibilities:

- `Package.swift`: package, product, target, and test target names.
- `Sources/KVRouterKit/KVNavigationTransition.swift`: public style factories, custom transition erasure, transition context, and animation overrides.
- `Sources/KVRouterKit/KVNavigationEntry.swift`: unique internal path entry and transition request types.
- `Sources/KVRouterKit/KVTransitionDriving.swift`: internal router-to-host driver contract.
- `Sources/KVRouterKit/KVTransitionCoordinator.swift`: backend selection, phase state machine, progress, queue completion, interruption, and interactive settlement.
- `Sources/KVRouterKit/KVTransitionVisualState.swift`: pure built-in transition math.
- `Sources/KVRouterKit/KVTransitionLayer.swift`: SwiftUI rendering for incoming live content, outgoing snapshots, masks, blur, scale, and rotation.
- `Sources/KVRouterKit/KVTransitionSource.swift`: source modifier, shared namespace environment, source registry, and iOS 18 native source modifier.
- `Sources/KVRouterKit/KVSnapshotCapture.swift`: internal UIKit probes, image capture, and bounded snapshot cache.
- `Sources/KVRouterKit/KVInteractivePopGesture.swift`: leading-edge drag recognition and progress/velocity decisions.
- `Sources/KVRouterKit/KVAnimationCompletionObserver.swift`: iOS 16 progress completion callback.
- `Sources/KVRouterKit/KVAppRouter.swift`: internal entry storage, transition metadata, driver attachment, and navigation operation integration.
- `Sources/KVRouterKit/KVRouterHost.swift`: namespace/coordinator ownership, internal-entry `NavigationStack`, overlay composition, lifecycle, and gesture wiring.
- `Sources/KVRouterKit/KVAppRouter+Destinations.swift`: build destination content from `KVNavigationEntry`.
- `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`: public transition value and context helper tests.
- `Tests/KVRouterKitTests/KVNavigationEntryTests.swift`: unique entry and metadata reconciliation tests.
- `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`: backend, state machine, fallback, interruption, and settlement tests.
- `Tests/KVRouterKitTests/KVInteractivePopGestureTests.swift`: progress, threshold, velocity, and layout-direction tests.
- `Tests/KVRouterKitTests/KVAppRouterTests.swift`: migrated existing coverage plus transition-aware router tests.
- `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`: all built-ins, hero source, fallback, and rapid-navigation demos.
- `README.md`: rename, migration, transition API, support matrix, and custom examples.

## Verification Commands

SwiftPM attempts to compile this iOS-only package as macOS when invoked with plain
`swift test`, so use Xcode's iOS destinations for authoritative verification:

```bash
xcodebuild -scheme KVRouterKit -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKitExample -project KVRouterKitExample/KVRouterKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' build
```

When a simulator runtime is available, run:

```bash
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected build result throughout: `** BUILD SUCCEEDED **`. Expected test result
after the final task: `** TEST SUCCEEDED **` with all existing and new tests
passing.

---

### Task 1: Rename Package, Module, Tests, and Example App

**Files:**
- Modify: `Package.swift`
- Move: `Sources/KVRouter` to `Sources/KVRouterKit`
- Move: `Tests/KVRouterTests` to `Tests/KVRouterKitTests`
- Move: `KVRouterExample` to `KVRouterKitExample`
- Move: `KVRouterKitExample/KVRouterExample.xcodeproj` to `KVRouterKitExample/KVRouterKitExample.xcodeproj`
- Move: `KVRouterKitExample/KVRouterExample` to `KVRouterKitExample/KVRouterKitExample`
- Move: `KVRouterKitExample/KVRouterKitExample/KVRouterExampleApp.swift` to `KVRouterKitExample/KVRouterKitExample/KVRouterKitExampleApp.swift`
- Modify: `KVRouterKitExample/KVRouterKitExample.xcodeproj/project.pbxproj`
- Modify: every Swift file importing `KVRouter`

- [ ] **Step 1: Record the current verification limitation and package scheme**

Run:

```bash
xcodebuild -list -json
```

Expected before rename: scheme `KVRouter`. Do not treat plain `swift test` as a
baseline because the manifest currently declares only iOS and SwiftPM selects a
macOS host destination.

- [ ] **Step 2: Move directories and app entry file**

Run exactly:

```bash
mv Sources/KVRouter Sources/KVRouterKit
mv Tests/KVRouterTests Tests/KVRouterKitTests
mv KVRouterExample KVRouterKitExample
mv KVRouterKitExample/KVRouterExample.xcodeproj KVRouterKitExample/KVRouterKitExample.xcodeproj
mv KVRouterKitExample/KVRouterExample KVRouterKitExample/KVRouterKitExample
mv KVRouterKitExample/KVRouterKitExample/KVRouterExampleApp.swift KVRouterKitExample/KVRouterKitExample/KVRouterKitExampleApp.swift
```

Expected: all files remain present under the new paths and no old top-level
source, test, or example directory remains.

- [ ] **Step 3: Replace the package manifest with the renamed targets**

Use this complete `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KVRouterKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "KVRouterKit",
            targets: ["KVRouterKit"]
        )
    ],
    targets: [
        .target(
            name: "KVRouterKit",
            path: "Sources/KVRouterKit"
        ),
        .testTarget(
            name: "KVRouterKitTests",
            dependencies: ["KVRouterKit"],
            path: "Tests/KVRouterKitTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 4: Rename imports and Xcode project identifiers**

Change every package import to:

```swift
import KVRouterKit
```

Change the example app declaration to:

```swift
@main
struct KVRouterKitExampleApp: App {
```

In `project.pbxproj`, replace product dependency `KVRouter` with
`KVRouterKit`, target/project/product `KVRouterExample` with
`KVRouterKitExample`, bundle identifier `hehe.KVRouterExample` with
`hehe.KVRouterKitExample`, and the local package product name with
`KVRouterKit`. Keep all existing object IDs unchanged.

- [ ] **Step 5: Build both renamed schemes**

Run:

```bash
xcodebuild -scheme KVRouterKit -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKitExample -project KVRouterKitExample/KVRouterKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' build
```

Expected: both builds succeed and no source file contains `import KVRouter`.

- [ ] **Step 6: Commit the rename**

```bash
git add Package.swift Sources Tests KVRouterKitExample
git commit -m "chore: rename package to KVRouterKit"
```

---

### Task 2: Add the Public Transition Value and Context API

**Files:**
- Create: `Sources/KVRouterKit/KVNavigationTransition.swift`
- Create: `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`

- [ ] **Step 1: Write failing tests for built-ins, animation override, and context helpers**

Create `KVNavigationTransitionTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import KVRouterKit

@MainActor
final class KVNavigationTransitionTests: XCTestCase {
    func testBuiltInFactoriesKeepTheirKinds() {
        XCTAssertEqual(KVNavigationTransition.system.debugKind, .system)
        XCTAssertEqual(KVNavigationTransition.slide().debugKind, .slide)
        XCTAssertEqual(KVNavigationTransition.fade.debugKind, .fade)
        XCTAssertEqual(KVNavigationTransition.scale.debugKind, .scale)
        XCTAssertEqual(KVNavigationTransition.scaleAndFade.debugKind, .scaleAndFade)
        XCTAssertEqual(KVNavigationTransition.sharedAxis().debugKind, .sharedAxis)
        XCTAssertEqual(KVNavigationTransition.depth.debugKind, .depth)
        XCTAssertEqual(KVNavigationTransition.reveal().debugKind, .reveal)
        XCTAssertEqual(KVNavigationTransition.flip3D().debugKind, .flip3D)
        XCTAssertEqual(KVNavigationTransition.zoom(sourceID: "card").debugKind, .zoom)
    }

    func testAnimationOverridePreservesKind() {
        let transition = KVNavigationTransition.depth
            .animation(.easeInOut(duration: 0.9))

        XCTAssertEqual(transition.debugKind, .depth)
        XCTAssertTrue(transition.hasAnimationOverride)
    }

    func testIncomingHelperMovesFromStartToIdentity() {
        let start = KVTransitionContext(
            progress: 0,
            role: .incoming,
            operation: .push,
            containerSize: CGSize(width: 300, height: 600),
            isInteractive: false,
            reduceMotion: false
        )
        let end = start.withProgress(1)

        XCTAssertEqual(start.opacity(from: 0.2), 0.2, accuracy: 0.001)
        XCTAssertEqual(end.opacity(from: 0.2), 1, accuracy: 0.001)
        XCTAssertEqual(start.scale(from: 0.8), 0.8, accuracy: 0.001)
        XCTAssertEqual(end.scale(from: 0.8), 1, accuracy: 0.001)
    }

    func testOutgoingHelperMovesFromIdentityToEnd() {
        let start = KVTransitionContext(
            progress: 0,
            role: .outgoing,
            operation: .push,
            containerSize: CGSize(width: 300, height: 600),
            isInteractive: false,
            reduceMotion: false
        )
        let end = start.withProgress(1)

        XCTAssertEqual(start.opacity(from: 0.35), 1, accuracy: 0.001)
        XCTAssertEqual(end.opacity(from: 0.35), 0.35, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run:

```bash
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:KVRouterKitTests/KVNavigationTransitionTests
```

Expected: compile failure because `KVNavigationTransition` and
`KVTransitionContext` do not exist.

- [ ] **Step 3: Implement the public value types and internal storage**

Create these types in `KVNavigationTransition.swift`:

```swift
import SwiftUI

public enum KVTransitionRole: Sendable {
    case incoming
    case outgoing
}

public enum KVTransitionOperation: Sendable {
    case push
    case pop
    case replace
}

public enum KVFlip3DAxis: Sendable {
    case horizontal
    case vertical
}

public struct KVTransitionContext: Sendable {
    public let progress: CGFloat
    public let role: KVTransitionRole
    public let operation: KVTransitionOperation
    public let containerSize: CGSize
    public let isInteractive: Bool
    public let reduceMotion: Bool

    init(
        progress: CGFloat,
        role: KVTransitionRole,
        operation: KVTransitionOperation,
        containerSize: CGSize,
        isInteractive: Bool,
        reduceMotion: Bool
    ) {
        self.progress = min(max(progress, 0), 1)
        self.role = role
        self.operation = operation
        self.containerSize = containerSize
        self.isInteractive = isInteractive
        self.reduceMotion = reduceMotion
    }

    func withProgress(_ progress: CGFloat) -> Self {
        Self(
            progress: progress,
            role: role,
            operation: operation,
            containerSize: containerSize,
            isInteractive: isInteractive,
            reduceMotion: reduceMotion
        )
    }

    public func opacity(from boundary: Double) -> Double {
        role == .incoming
            ? boundary + ((1 - boundary) * progress)
            : 1 - ((1 - boundary) * progress)
    }

    public func scale(from boundary: CGFloat) -> CGFloat {
        role == .incoming
            ? boundary + ((1 - boundary) * progress)
            : 1 - ((1 - boundary) * progress)
    }

    public func angle(from degrees: Double) -> Angle {
        let value = role == .incoming
            ? degrees * (1 - progress)
            : -degrees * progress
        return .degrees(value)
    }
}

public struct KVTransitionContent: View {
    private let content: AnyView

    init(_ content: AnyView) {
        self.content = content
    }

    public var body: some View { content }
}

@MainActor
public struct KVNavigationTransition {
    enum Kind {
        case system
        case slide(Edge)
        case fade
        case scale
        case scaleAndFade
        case sharedAxis(Axis)
        case depth
        case reveal(UnitPoint)
        case flip3D(KVFlip3DAxis)
        case zoom(AnyHashable)
        case custom(KVCustomTransition)
    }

    enum DebugKind: Equatable {
        case system, slide, fade, scale, scaleAndFade, sharedAxis
        case depth, reveal, flip3D, zoom, custom
    }

    let kind: Kind
    let animationOverride: Animation?

    public static let system = Self(kind: .system, animationOverride: nil)
    public static let fade = Self(kind: .fade, animationOverride: nil)
    public static let scale = Self(kind: .scale, animationOverride: nil)
    public static let scaleAndFade = Self(kind: .scaleAndFade, animationOverride: nil)
    public static let depth = Self(kind: .depth, animationOverride: nil)

    public static func slide(edge: Edge = .trailing) -> Self {
        Self(kind: .slide(edge), animationOverride: nil)
    }

    public static func sharedAxis(axis: Axis = .horizontal) -> Self {
        Self(kind: .sharedAxis(axis), animationOverride: nil)
    }

    public static func reveal(origin: UnitPoint = .topTrailing) -> Self {
        Self(kind: .reveal(origin), animationOverride: nil)
    }

    public static func flip3D(axis: KVFlip3DAxis = .vertical) -> Self {
        Self(kind: .flip3D(axis), animationOverride: nil)
    }

    public static func zoom<ID: Hashable>(sourceID: ID) -> Self {
        Self(kind: .zoom(AnyHashable(sourceID)), animationOverride: nil)
    }

    public static func custom<Body: View>(
        animation: Animation,
        interactiveBack: Bool = true,
        @ViewBuilder transform: @escaping @MainActor (KVTransitionContent, KVTransitionContext) -> Body
    ) -> Self {
        let custom = KVCustomTransition(
            animation: animation,
            interactiveBack: interactiveBack,
            transform: { content, context in
                AnyView(transform(KVTransitionContent(content), context))
            }
        )
        return Self(kind: .custom(custom), animationOverride: nil)
    }

    public func animation(_ animation: Animation) -> Self {
        Self(kind: kind, animationOverride: animation)
    }

    var hasAnimationOverride: Bool { animationOverride != nil }

    var resolvedAnimation: Animation {
        if let animationOverride { return animationOverride }
        switch kind {
        case .system:
            return .default
        case .fade:
            return .easeInOut(duration: 0.28)
        case .slide, .sharedAxis:
            return .spring(response: 0.42, dampingFraction: 0.88)
        case .scale, .scaleAndFade, .reveal:
            return .easeInOut(duration: 0.36)
        case .depth, .zoom:
            return .spring(response: 0.52, dampingFraction: 0.86)
        case .flip3D:
            return .easeInOut(duration: 0.48)
        case .custom(let custom):
            return custom.animation
        }
    }

    var supportsInteractiveBack: Bool {
        switch kind {
        case .system:
            return false
        case .custom(let custom):
            return custom.interactiveBack
        default:
            return true
        }
    }

    var debugKind: DebugKind {
        switch kind {
        case .system: .system
        case .slide: .slide
        case .fade: .fade
        case .scale: .scale
        case .scaleAndFade: .scaleAndFade
        case .sharedAxis: .sharedAxis
        case .depth: .depth
        case .reveal: .reveal
        case .flip3D: .flip3D
        case .zoom: .zoom
        case .custom: .custom
        }
    }
}

struct KVCustomTransition {
    let animation: Animation
    let interactiveBack: Bool
    let transform: @MainActor (AnyView, KVTransitionContext) -> AnyView
}
```

- [ ] **Step 4: Re-run the focused tests**

Run the Step 2 command. Expected: all four tests pass.

- [ ] **Step 5: Commit the public API**

```bash
git add Sources/KVRouterKit/KVNavigationTransition.swift Tests/KVRouterKitTests/KVNavigationTransitionTests.swift
git commit -m "feat: add navigation transition API"
```

---

### Task 3: Introduce Unique Navigation Entries and Transition Metadata

**Files:**
- Create: `Sources/KVRouterKit/KVNavigationEntry.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter.swift`
- Create: `Tests/KVRouterKitTests/KVNavigationEntryTests.swift`

- [ ] **Step 1: Write failing tests for duplicate routes and path reconciliation**

Create `KVNavigationEntryTests.swift`:

```swift
import XCTest
@testable import KVRouterKit

@MainActor
final class KVNavigationEntryTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDuplicateRoutesReceiveDifferentEntryIDs() async {
        let router = KVAppRouter()
        router.push(.appFeature("detail"), transition: .fade)
        router.push(.appFeature("detail"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }

        XCTAssertNotEqual(router.navigationEntries[0].id, router.navigationEntries[1].id)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[0])?.debugKind, .fade)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[1])?.debugKind, .depth)
    }

    func testDirectPathAssignmentReusesCommonPrefix() {
        let router = KVAppRouter()
        router.path = [.appFeature("a"), .appFeature("b")]
        let originalA = router.navigationEntries[0].id

        router.path = [.appFeature("a"), .appFeature("c")]

        XCTAssertEqual(router.navigationEntries[0].id, originalA)
        XCTAssertEqual(router.navigationEntries.map(\.route), [.appFeature("a"), .appFeature("c")])
        XCTAssertNil(router.transitionOverride(for: router.navigationEntries[1]))
    }

    func testSystemPopRemovesEntryMetadata() async {
        let router = KVAppRouter()
        router.push(.appFeature("a"), transition: .fade)
        router.push(.appFeature("b"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }
        let removed = router.navigationEntries[1]

        router.navigationEntries = [router.navigationEntries[0]]

        XCTAssertNil(router.transitionOverride(for: removed))
        XCTAssertEqual(router.path, [.appFeature("a")])
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm compile failures**

```bash
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:KVRouterKitTests/KVNavigationEntryTests
```

Expected: failure because entry storage and transition-aware push overloads do
not exist.

- [ ] **Step 3: Add the internal entry model**

Create `KVNavigationEntry.swift`:

```swift
import Foundation

struct KVNavigationEntry: Hashable, Identifiable {
    let id: UUID
    let route: KVAppRoute

    init(id: UUID = UUID(), route: KVAppRoute) {
        self.id = id
        self.route = route
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
```

- [ ] **Step 4: Replace route-only storage with entry storage**

In `KVAppRouter`, replace `_path` with:

```swift
private var _navigationEntries: [KVNavigationEntry] = []
private var transitionOverrides: [UUID: KVNavigationTransition] = [:]

public var path: [KVAppRoute] {
    get {
        trackAccess(\.path)
        return _navigationEntries.map(\.route)
    }
    set {
        reconcileEntries(with: newValue)
    }
}

var navigationEntries: [KVNavigationEntry] {
    get {
        trackAccess(\.path)
        return _navigationEntries
    }
    set {
        let oldEntries = _navigationEntries
        withTrackedMutation(\.path) { _navigationEntries = newValue }
        cleanupRemovedEntries(from: oldEntries, to: newValue)
        handlePathChange(
            from: oldEntries.map(\.route),
            to: newValue.map(\.route)
        )
    }
}

func transitionOverride(for entry: KVNavigationEntry) -> KVNavigationTransition? {
    transitionOverrides[entry.id]
}

private func reconcileEntries(with routes: [KVAppRoute]) {
    let oldEntries = _navigationEntries
    let prefixCount = zip(oldEntries.map(\.route), routes)
        .prefix { $0 == $1 }
        .count
    let prefix = oldEntries.prefix(prefixCount)
    let suffix = routes.dropFirst(prefixCount).map(KVNavigationEntry.init(route:))
    navigationEntries = Array(prefix) + suffix
}

private func makeEntry(
    route: KVAppRoute,
    transition: KVNavigationTransition?
) -> KVNavigationEntry {
    let entry = KVNavigationEntry(route: route)
    transitionOverrides[entry.id] = transition
    return entry
}

private func cleanupRemovedEntries(
    from oldEntries: [KVNavigationEntry],
    to newEntries: [KVNavigationEntry]
) {
    let liveIDs = Set(newEntries.map(\.id))
    for entry in oldEntries where !liveIDs.contains(entry.id) {
        transitionOverrides[entry.id] = nil
        cleanupBuilder(for: entry.route)
    }
}
```

Add transition-aware overloads while retaining the existing methods:

```swift
public func push(_ route: KVAppRoute) {
    push(route, transition: nil)
}

public func push(
    _ route: KVAppRoute,
    transition: KVNavigationTransition
) {
    push(route, transition: Optional(transition))
}

private func push(
    _ route: KVAppRoute,
    transition: KVNavigationTransition?
) {
    enqueue { [weak self] in
        guard let self else { return }
        guard let finalRoute = await self.applyMiddlewares(to: route) else { return }
        let entry = self.makeEntry(route: finalRoute, transition: transition)
        self.navigationEntries.append(entry)
    }
}
```

Add these exact public overloads while retaining the existing signatures:

```swift
public func pushView<V: View>(
    tag: String? = nil,
    transition: KVNavigationTransition,
    _ build: @escaping () -> V
)

public func pushView<V: View>(
    _ view: V,
    tag: String? = nil,
    transition: KVNavigationTransition
)

public func replaceTop(
    with route: KVAppRoute,
    transition: KVNavigationTransition
)

public func replaceTopWithView<V: View>(
    tag: String? = nil,
    transition: KVNavigationTransition,
    _ build: @escaping () -> V
)
```

Each existing overload calls a private implementation with
`transition: KVNavigationTransition? = nil`. After middleware and builder
registration, the private implementation creates the entry only through:

```swift
let entry = makeEntry(route: finalRoute, transition: transition)
navigationEntries.append(entry)
```

Replace uses:

```swift
let entry = makeEntry(route: finalRoute, transition: transition)
if navigationEntries.isEmpty {
    navigationEntries = [entry]
} else {
    navigationEntries[navigationEntries.count - 1] = entry
}
```

Update `performPop(toIndex:)`, `pop(count:)`, and `popToRoot()` to calculate the
target entry array first, then assign it once:

```swift
let retainedEntries = Array(navigationEntries.prefix(through: targetIndex))
navigationEntries = retainedEntries
```

For root pop use `navigationEntries = []`. Do not separately clean builders in
these methods; `cleanupRemovedEntries(from:to:)` owns builder and transition
metadata cleanup exactly once.

- [ ] **Step 5: Run entry tests and the migrated router suite**

```bash
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:KVRouterKitTests/KVNavigationEntryTests -only-testing:KVRouterKitTests/KVAppRouterTests
```

Expected: all tests pass, including existing push/pop and builder cleanup tests.

- [ ] **Step 6: Commit entry identity and metadata**

```bash
git add Sources/KVRouterKit/KVNavigationEntry.swift Sources/KVRouterKit/KVAppRouter.swift Tests/KVRouterKitTests
git commit -m "refactor: track unique navigation entries"
```

---

### Task 4: Route Mutations Through a Host Transition Driver

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionDriving.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter.swift`
- Modify: `Tests/KVRouterKitTests/KVNavigationEntryTests.swift`

- [ ] **Step 1: Add a failing fake-driver test**

Append:

```swift
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

func testRouterSendsPushAndPopThroughDriver() async {
    let router = KVAppRouter()
    let driver = RecordingDriver()
    router.transitionDriver = driver

    router.push(.appFeature("detail"), transition: .depth)
    await waitUntil { router.path.count == 1 }
    router.pop()
    await waitUntil { router.path.isEmpty }

    XCTAssertEqual(driver.requests.map(\.operation), [.push, .pop])
    XCTAssertEqual(driver.requests.first?.transitionOverride?.debugKind, .depth)
}
```

- [ ] **Step 2: Run the test and confirm missing driver types**

Run the Task 3 focused test command. Expected: compile failure for
`KVTransitionDriving` and `KVTransitionRequest`.

- [ ] **Step 3: Define the driver contract**

Create `KVTransitionDriving.swift`:

```swift
import Foundation

struct KVTransitionRequest {
    let operation: KVTransitionOperation
    let from: KVNavigationEntry?
    let to: KVNavigationEntry?
    let transitionOverride: KVNavigationTransition?
}

@MainActor
protocol KVTransitionDriving: AnyObject {
    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async
}
```

- [ ] **Step 4: Attach the driver weakly and centralize mutations**

Add to `KVAppRouter`:

```swift
weak var transitionDriver: (any KVTransitionDriving)?

private func performNavigation(
    _ request: KVTransitionRequest,
    mutation: @escaping @MainActor () -> Void
) async {
    if let transitionDriver {
        await transitionDriver.perform(request, mutation: mutation)
    } else {
        mutation()
    }
}
```

Push commits with:

```swift
let entry = makeEntry(route: finalRoute, transition: transition)
let request = KVTransitionRequest(
    operation: .push,
    from: navigationEntries.last,
    to: entry,
    transitionOverride: transition
)
await performNavigation(request) {
    self.navigationEntries.append(entry)
}
```

Replace commits with `.replace`, the old top as `from`, and the new entry as
`to`. Every pop variant resolves its final target index first, creates one
`.pop` request using the current top entry's stored override, and performs one
mutation that truncates `navigationEntries`. This ensures `pop(count:)`,
`popTo`, and `popToRoot` animate once rather than once per removed entry.

- [ ] **Step 5: Run router and driver tests**

Expected: fake driver records push then pop, and all existing router tests pass.

- [ ] **Step 6: Commit driver integration**

```bash
git add Sources/KVRouterKit/KVTransitionDriving.swift Sources/KVRouterKit/KVAppRouter.swift Tests/KVRouterKitTests
git commit -m "feat: route navigation through transition driver"
```

---

### Task 5: Implement Backend Resolution and Coordinator State Machine

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Create: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [ ] **Step 1: Write failing backend and phase tests**

```swift
import XCTest
@testable import KVRouterKit

@MainActor
final class KVTransitionCoordinatorTests: XCTestCase {
    func testBackendSelection() {
        XCTAssertEqual(KVTransitionBackend.resolve(.system, supportsNativeZoom: true), .system)
        XCTAssertEqual(KVTransitionBackend.resolve(.zoom(sourceID: "id"), supportsNativeZoom: true), .nativeZoom)
        XCTAssertEqual(KVTransitionBackend.resolve(.zoom(sourceID: "id"), supportsNativeZoom: false), .custom)
        XCTAssertEqual(KVTransitionBackend.resolve(.depth, supportsNativeZoom: true), .custom)
    }

    func testImmediateDriverReturnsToIdle() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .fade)
        var mutated = false
        let entry = KVNavigationEntry(route: .appFeature("detail"))
        let request = KVTransitionRequest(
            operation: .push,
            from: nil,
            to: entry,
            transitionOverride: .system
        )

        await coordinator.perform(request) { mutated = true }

        XCTAssertTrue(mutated)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testMissingZoomSourceFallsBack() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let resolved = coordinator.resolve(
            override: .zoom(sourceID: "missing"),
            supportsNativeZoom: false
        )

        XCTAssertEqual(resolved.transition.debugKind, .scaleAndFade)
        XCTAssertEqual(resolved.backend, .custom)
    }
}
```

- [ ] **Step 2: Run and confirm missing coordinator failures**

Run the focused coordinator test target. Expected: missing coordinator,
backend, and phase types.

- [ ] **Step 3: Implement backend selection and minimal driver behavior**

```swift
import SwiftUI

enum KVTransitionBackend: Equatable {
    case system
    case nativeZoom
    case custom

    static func resolve(
        _ transition: KVNavigationTransition,
        supportsNativeZoom: Bool
    ) -> Self {
        switch transition.kind {
        case .system:
            return .system
        case .zoom where supportsNativeZoom:
            return .nativeZoom
        default:
            return .custom
        }
    }
}

enum KVTransitionPhase: Equatable {
    case idle
    case preparing
    case animating
    case interactive
    case settling
    case cleaningUp
}

struct KVResolvedTransition {
    let transition: KVNavigationTransition
    let backend: KVTransitionBackend
}

@MainActor
final class KVTransitionCoordinator: ObservableObject, KVTransitionDriving {
    @Published private(set) var phase: KVTransitionPhase = .idle
    @Published private(set) var progress: CGFloat = 0

    let defaultTransition: KVNavigationTransition
    var hasSource: (AnyHashable) -> Bool = { _ in false }

    init(defaultTransition: KVNavigationTransition) {
        self.defaultTransition = defaultTransition
    }

    func resolve(
        override: KVNavigationTransition?,
        supportsNativeZoom: Bool
    ) -> KVResolvedTransition {
        let requested = override ?? defaultTransition
        if case .zoom(let sourceID) = requested.kind,
           !hasSource(sourceID) {
            return KVResolvedTransition(
                transition: .scaleAndFade,
                backend: .custom
            )
        }
        return KVResolvedTransition(
            transition: requested,
            backend: .resolve(requested, supportsNativeZoom: supportsNativeZoom)
        )
    }

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        phase = .preparing
        let resolved = resolve(
            override: request.transitionOverride,
            supportsNativeZoom: {
                if #available(iOS 18.0, *) { return true }
                return false
            }()
        )
        switch resolved.backend {
        case .system, .nativeZoom:
            mutation()
        case .custom:
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, mutation)
        }
        progress = 0
        phase = .cleaningUp
        phase = .idle
    }
}
```

- [ ] **Step 4: Run coordinator tests**

Expected: backend and phase tests pass.

- [ ] **Step 5: Commit coordinator foundation**

```bash
git add Sources/KVRouterKit/KVTransitionCoordinator.swift Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift
git commit -m "feat: add transition coordinator state machine"
```

---

### Task 6: Add Pure Built-in Transition Math and Rendering Layers

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionVisualState.swift`
- Create: `Sources/KVRouterKit/KVTransitionLayer.swift`
- Create: `Sources/KVRouterKit/KVAnimationCompletionObserver.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [ ] **Step 1: Write endpoint tests for every built-in style**

Create one test with this shared context:

```swift
let context = KVTransitionContext(
    progress: 0,
    role: .incoming,
    operation: .push,
    containerSize: CGSize(width: 320, height: 640),
    isInteractive: false,
    reduceMotion: false
)
```

Assert these exact invariants:

```swift
XCTAssertEqual(KVTransitionVisualState.resolve(.fade, context).opacity, 0)
XCTAssertEqual(KVTransitionVisualState.resolve(.fade, context.withProgress(1)).opacity, 1)
XCTAssertEqual(KVTransitionVisualState.resolve(.scale, context).scale, 0.92, accuracy: 0.001)
XCTAssertEqual(KVTransitionVisualState.resolve(.slide(), context).offset.width, 320, accuracy: 0.001)
XCTAssertEqual(KVTransitionVisualState.resolve(.sharedAxis(), context).offset.width, 76.8, accuracy: 0.001)
XCTAssertEqual(KVTransitionVisualState.resolve(.depth, context).scale, 1.04, accuracy: 0.001)
XCTAssertEqual(KVTransitionVisualState.resolve(.reveal(), context).revealProgress, 0, accuracy: 0.001)
XCTAssertEqual(KVTransitionVisualState.resolve(.flip3D(), context).rotationDegrees, 72, accuracy: 0.001)
```

Add an outgoing context and assert every style resolves to identity at progress
`0` and its documented outgoing endpoint at progress `1`.

- [ ] **Step 2: Run tests and confirm missing visual-state failure**

Expected: compile failure for `KVTransitionVisualState`.

- [ ] **Step 3: Implement visual-state resolution**

Define:

```swift
struct KVTransitionVisualState: Equatable {
    var opacity: Double = 1
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var rotationDegrees: Double = 0
    var rotationAxis: (x: CGFloat, y: CGFloat, z: CGFloat) = (0, 1, 0)
    var blurRadius: CGFloat = 0
    var revealProgress: CGFloat = 1

    static func resolve(
        _ transition: KVNavigationTransition,
        _ context: KVTransitionContext
    ) -> Self {
        if context.reduceMotion {
            return Self(opacity: context.opacity(from: 0), revealProgress: 1)
        }

        let p = context.progress
        let incoming = context.role == .incoming
        let amount = incoming ? 1 - p : p
        let direction: CGFloat = context.operation == .pop ? -1 : 1

        switch transition.kind {
        case .system, .custom:
            return Self()
        case .fade:
            return Self(opacity: context.opacity(from: 0))
        case .scale:
            return Self(
                opacity: context.opacity(from: 0.7),
                scale: incoming ? 1 - (0.08 * amount) : 1 - (0.08 * p)
            )
        case .scaleAndFade:
            return Self(
                opacity: context.opacity(from: 0),
                scale: incoming ? 1 - (0.1 * amount) : 1 - (0.06 * p)
            )
        case .slide(let edge):
            let vector = edge.kvUnitVector
            let distance = incoming ? amount : p * 0.28
            return Self(
                opacity: incoming ? 1 : 1 - (0.4 * p),
                offset: CGSize(
                    width: vector.width * context.containerSize.width * distance * direction,
                    height: vector.height * context.containerSize.height * distance
                )
            )
        case .sharedAxis(let axis):
            let distance = incoming ? amount * 0.24 : p * 0.12
            return Self(
                opacity: context.opacity(from: 0),
                scale: 1 - (0.04 * amount),
                offset: axis == .horizontal
                    ? CGSize(width: context.containerSize.width * distance * direction, height: 0)
                    : CGSize(width: 0, height: context.containerSize.height * distance)
            )
        case .depth:
            return incoming
                ? Self(opacity: context.opacity(from: 0), scale: 1 + (0.04 * amount))
                : Self(opacity: 1 - (0.8 * p), scale: 1 - (0.14 * p), blurRadius: 10 * p)
        case .reveal:
            return Self(opacity: context.opacity(from: 0.65), revealProgress: p)
        case .flip3D(let axis):
            return Self(
                opacity: context.opacity(from: 0),
                scale: 1 - (0.08 * amount),
                rotationDegrees: (incoming ? 72 * amount : -72 * p),
                rotationAxis: axis == .vertical ? (0, 1, 0) : (1, 0, 0)
            )
        case .zoom:
            return Self(
                opacity: context.opacity(from: 0.35),
                scale: incoming ? 0.28 + (0.72 * p) : 1 - (0.72 * p)
            )
        }
    }
}
```

Add an internal `Edge.kvUnitVector` mapping leading/trailing/top/bottom to unit
sizes. Implement a custom `Equatable` for the rotation tuple or compare fields
individually in tests.

- [ ] **Step 4: Render visual state and custom closures**

`KVTransitionLayer` accepts `AnyView`, transition, context, and optional hero
geometry. For built-ins it applies opacity, scale, offset, blur, 3D rotation,
and a reveal mask. For `.custom`, call the stored transform closure. Use
`Rectangle().scaleEffect(state.revealProgress, anchor: origin)` as the initial
reveal mask implementation so it works on iOS 16.

Add `KVAnimationCompletionObserver`, an `AnimatableModifier` whose
`animatableData` calls its completion once the target value is reached. Attach
it to the host overlay so iOS 16 custom animations resume the driver's checked
continuation without a sleep.

- [ ] **Step 5: Upgrade coordinator custom perform**

Add:

```swift
struct KVActiveTransition {
    let request: KVTransitionRequest
    let resolved: KVResolvedTransition
}

@Published private(set) var activeTransition: KVActiveTransition?
private var pendingCompletion: CheckedContinuation<Void, Never>?
var isRendererAttached = false
```

For custom backends:

```swift
phase = .preparing
activeTransition = KVActiveTransition(request: request, resolved: resolved)
progress = 0

var transaction = Transaction(animation: nil)
transaction.disablesAnimations = true
withTransaction(transaction, mutation)
await Task.yield()

phase = .animating
await animateProgress(
    to: 1,
    animation: resolved.transition.resolvedAnimation
)
phase = .cleaningUp
activeTransition = nil
phase = .idle
```

`animateProgress` immediately assigns the target and returns when
`isRendererAttached` is false, preserving router use without a host. When a host
is attached, it installs one continuation, changes `progress` inside
`withAnimation`, and resumes only from `KVAnimationCompletionObserver`.

- [ ] **Step 6: Run visual-state and coordinator tests**

Expected: all endpoint invariants and phase cleanup tests pass.

- [ ] **Step 7: Commit built-in rendering**

```bash
git add Sources/KVRouterKit/KVTransitionVisualState.swift Sources/KVRouterKit/KVTransitionLayer.swift Sources/KVRouterKit/KVAnimationCompletionObserver.swift Sources/KVRouterKit/KVTransitionCoordinator.swift Tests/KVRouterKitTests
git commit -m "feat: render built-in navigation transitions"
```

---

### Task 7: Add Snapshot Capture, Cache, and Transition Sources

**Files:**
- Create: `Sources/KVRouterKit/KVSnapshotCapture.swift`
- Create: `Sources/KVRouterKit/KVTransitionSource.swift`
- Modify: `Sources/KVRouterKit/KVRouterEnvironment.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [ ] **Step 1: Write source-registry and cache fallback tests**

Add these three test methods:

```swift
func testVisibleSourceCanBeResolved() {
    let registry = KVTransitionSourceRegistry()
    registry.update(id: "card", frame: CGRect(x: 20, y: 30, width: 80, height: 80), view: nil)
    XCTAssertEqual(registry.source(for: "card")?.frame.width, 80)
}

func testRemovingSourceMakesZoomFallback() {
    let registry = KVTransitionSourceRegistry()
    registry.update(id: "card", frame: .zero, view: nil)
    registry.remove(id: "card")
    XCTAssertNil(registry.source(for: "card"))
}

func testEvictedPreviousSnapshotDisablesInteractivePreview() {
    let cache = KVSnapshotCache(totalCostLimit: 1)
    let entry = KVNavigationEntry(route: .appFeature("a"))
    XCTAssertNil(cache.image(for: entry.id))
}
```

- [ ] **Step 2: Run and confirm missing registry/cache types**

Expected: compile failure.

- [ ] **Step 3: Implement internal UIKit capture and bounded cache**

Start `KVSnapshotCapture.swift` with:

```swift
import SwiftUI
import UIKit

struct KVSnapshot {
    let image: UIImage
    let frame: CGRect
    let cornerRadius: CGFloat

    var cost: Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}

@MainActor
final class KVSnapshotCache {
    private let cache = NSCache<NSUUID, UIImage>()

    init(totalCostLimit: Int = 48 * 1_024 * 1_024) {
        cache.totalCostLimit = totalCostLimit
    }

    func insert(_ snapshot: KVSnapshot, for id: UUID) {
        cache.setObject(snapshot.image, forKey: id as NSUUID, cost: snapshot.cost)
    }

    func image(for id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    func remove(id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
```

Add a `UIViewRepresentable` probe that reports its backing `UIView` and frame to
the coordinator. Capture with `UIGraphicsImageRenderer` and
`view.drawHierarchy(in:afterScreenUpdates:)`; return `nil` if the view has no
window or empty bounds.

- [ ] **Step 4: Implement the source registry and public modifier**

Implement the registry with a weak view box so registry ownership does not keep
SwiftUI backing views alive:

```swift
@MainActor
final class KVTransitionSourceRegistry: ObservableObject {
    struct Source {
        let frame: CGRect
        let viewBox: KVWeakViewBox?
    }

    private var sources: [AnyHashable: Source] = [:]

    func update(id: AnyHashable, frame: CGRect, view: UIView?) {
        sources[id] = Source(
            frame: frame,
            viewBox: view.map(KVWeakViewBox.init)
        )
    }

    func remove(id: AnyHashable) {
        sources[id] = nil
    }

    func source(for id: AnyHashable) -> Source? {
        sources[id]
    }
}

final class KVWeakViewBox {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}
```

The modifier reads a private host namespace from the environment, reports its
probe frame, removes its record on disappear, and uses:

```swift
if #available(iOS 18.0, *), let namespace {
    content.matchedTransitionSource(id: id, in: namespace)
} else {
    content
}
```

Expose:

```swift
public extension View {
    func kvTransitionSource<ID: Hashable>(id: ID) -> some View {
        modifier(KVTransitionSourceModifier(id: AnyHashable(id)))
    }
}
```

- [ ] **Step 5: Connect coordinator source checks and snapshot cache**

Add these coordinator properties:

```swift
@Published private(set) var outgoingSnapshot: KVSnapshot?
@Published private(set) var heroSourceSnapshot: KVSnapshot?
let snapshotCache = KVSnapshotCache()
private(set) var rootSnapshot: UIImage?
weak var containerView: UIView?
var sourceRegistry: KVTransitionSourceRegistry?
```

Set `hasSource` to query `sourceRegistry`. Before a custom mutation, capture the
container into `outgoingSnapshot`; for `.zoom`, also capture the registered
source view into `heroSourceSnapshot`. After a transition settles, cache the
visible screen by destination entry ID and clear the two active snapshots.
Before the first push, retain the root image in `rootSnapshot` so interactive
pop from the first destination can preview the root.
Remove cache entries when router entries are removed. If source or snapshot
capture returns `nil`, resolve to `.scaleAndFade` and issue a `#if DEBUG`
warning.

- [ ] **Step 6: Run source and coordinator tests**

Expected: all registry, fallback, and cache tests pass.

- [ ] **Step 7: Commit source registration and capture**

```bash
git add Sources/KVRouterKit/KVSnapshotCapture.swift Sources/KVRouterKit/KVTransitionSource.swift Sources/KVRouterKit/KVRouterEnvironment.swift Sources/KVRouterKit/KVTransitionCoordinator.swift Tests/KVRouterKitTests
git commit -m "feat: capture transition sources and screen snapshots"
```

---

### Task 8: Integrate Host Overlays and Native iOS 18 Zoom

**Files:**
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter+Destinations.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [ ] **Step 1: Write native-zoom backend tests**

Add these methods to `KVTransitionCoordinatorTests`:

```swift
func testVisibleZoomUsesNativeBackendWhenAvailable() {
    let coordinator = KVTransitionCoordinator(defaultTransition: .system)
    coordinator.hasSource = { $0 == AnyHashable("card") }

    let resolved = coordinator.resolve(
        override: .zoom(sourceID: "card"),
        supportsNativeZoom: true
    )

    XCTAssertEqual(resolved.backend, .nativeZoom)
    XCTAssertEqual(resolved.transition.debugKind, .zoom)
}

func testVisibleZoomUsesCustomBackendBeforeIOS18() {
    let coordinator = KVTransitionCoordinator(defaultTransition: .system)
    coordinator.hasSource = { $0 == AnyHashable("card") }

    let resolved = coordinator.resolve(
        override: .zoom(sourceID: "card"),
        supportsNativeZoom: false
    )

    XCTAssertEqual(resolved.backend, .custom)
    XCTAssertEqual(resolved.transition.debugKind, .zoom)
}

func testNonZoomStyleStaysCustomWhenNativeZoomIsAvailable() {
    let coordinator = KVTransitionCoordinator(defaultTransition: .system)
    let resolved = coordinator.resolve(
        override: .sharedAxis(),
        supportsNativeZoom: true
    )
    XCTAssertEqual(resolved.backend, .custom)
}
```

- [ ] **Step 2: Change the host to bind internal entries**

`KVRouterHost` owns:

```swift
@Namespace private var transitionNamespace
@StateObject private var coordinator: KVTransitionCoordinator
@StateObject private var sourceRegistry = KVTransitionSourceRegistry()
```

Initialize `_coordinator` from `defaultTransition`. In `body`, attach the driver
on appear and detach only if the router still points to this coordinator on
disappear. Set `coordinator.isRendererAttached = true` on appear and `false` on
disappear so routers used without a visible host never wait for an animation
observer.

Bind `NavigationStack` to `router.navigationEntries`, then build destinations by
entry:

```swift
.navigationDestination(for: KVNavigationEntry.self) { entry in
    KVRouterDestinationContent(
        router: router,
        entry: entry,
        transition: router.transitionOverride(for: entry) ?? defaultTransition,
        namespace: transitionNamespace
    )
}
```

- [ ] **Step 3: Compose the live stack and overlay layers**

Wrap the stack in a `GeometryReader` and `ZStack`. Apply the incoming
`KVTransitionLayer` to the live stack whenever the coordinator has an active
custom transition. Place the outgoing snapshot image above it and apply the
outgoing context. Attach the root snapshot probe and animation completion
observer inside this `ZStack`.

For fallback `.zoom`, calculate the live destination transform from source
frame `s`, container frame `c`, and progress `p`:

```swift
let startScaleX = s.width / c.width
let startScaleY = s.height / c.height
let scaleX = startScaleX + ((1 - startScaleX) * p)
let scaleY = startScaleY + ((1 - startScaleY) * p)
let startOffset = CGSize(
    width: s.midX - c.midX,
    height: s.midY - c.midY
)
let offset = CGSize(
    width: startOffset.width * (1 - p),
    height: startOffset.height * (1 - p)
)
let cornerRadius = sourceCornerRadius * (1 - p)
```

Apply `scaleEffect(x:y:anchor:)`, `offset`, and a rounded-rectangle clip to the
live destination. Reverse `p` for pop. Keep the outgoing full-screen snapshot
behind the growing destination and fade it from `1` to `0.72`; do not render a
second live destination tree.

Inject namespace, source registry, coordinator, and a named host coordinate
space through private environment keys.

- [ ] **Step 4: Apply native destination zoom only on iOS 18**

In `KVRouterDestinationContent`:

```swift
@ViewBuilder
private var transitionedContent: some View {
    if #available(iOS 18.0, *),
       case .zoom(let sourceID) = transition.kind {
        router.buildView(for: entry.route)
            .navigationTransition(
                .zoom(sourceID: sourceID, in: namespace)
            )
    } else {
        router.buildView(for: entry.route)
    }
}
```

Do not apply `navigationTransition` to `.system` or any custom style.

- [ ] **Step 5: Build on generic iOS simulator**

Run both verification build commands. Expected: no availability errors and both
builds succeed with deployment target iOS 16.

- [ ] **Step 6: Commit host and native zoom integration**

```bash
git add Sources/KVRouterKit/KVRouterHost.swift Sources/KVRouterKit/KVAppRouter+Destinations.swift Sources/KVRouterKit/KVTransitionCoordinator.swift Tests/KVRouterKitTests
git commit -m "feat: integrate native and custom transition backends"
```

---

### Task 9: Add Interactive Leading-edge Pop

**Files:**
- Create: `Sources/KVRouterKit/KVInteractivePopGesture.swift`
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter.swift`
- Create: `Tests/KVRouterKitTests/KVInteractivePopGestureTests.swift`

- [ ] **Step 1: Write pure decision tests**

```swift
import XCTest
@testable import KVRouterKit

final class KVInteractivePopGestureTests: XCTestCase {
    func testProgressIsClamped() {
        XCTAssertEqual(KVInteractivePopDecision.progress(translation: 160, width: 320), 0.5)
        XCTAssertEqual(KVInteractivePopDecision.progress(translation: -10, width: 320), 0)
        XCTAssertEqual(KVInteractivePopDecision.progress(translation: 500, width: 320), 1)
    }

    func testThresholdCompletesPop() {
        XCTAssertTrue(KVInteractivePopDecision.shouldFinish(progress: 0.36, velocity: 0))
        XCTAssertTrue(KVInteractivePopDecision.shouldFinish(progress: 0.1, velocity: 900))
        XCTAssertFalse(KVInteractivePopDecision.shouldFinish(progress: 0.2, velocity: 100))
    }

    func testRTLNormalizesLeadingTranslation() {
        XCTAssertEqual(
            KVInteractivePopDecision.leadingTranslation(raw: -120, layoutDirection: .rightToLeft),
            120
        )
    }
}
```

- [ ] **Step 2: Run and confirm missing decision helper**

Expected: compile failure.

- [ ] **Step 3: Implement gesture math**

```swift
enum KVInteractivePopDecision {
    static func progress(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(translation / width, 0), 1)
    }

    static func shouldFinish(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress >= 0.35 || velocity >= 800
    }

    static func leadingTranslation(
        raw: CGFloat,
        layoutDirection: LayoutDirection
    ) -> CGFloat {
        layoutDirection == .leftToRight ? raw : -raw
    }
}
```

- [ ] **Step 4: Add coordinator interactive methods**

Implement:

```swift
func beginInteractivePop(
    request: KVTransitionRequest,
    previousSnapshot: UIImage,
    containerSize: CGSize
) -> Bool

func updateInteractivePop(progress: CGFloat)

func finishInteractivePop(
    shouldFinish: Bool,
    commit: @escaping @MainActor () async -> Bool
) async
```

Beginning is allowed only while idle, with a non-empty path, a custom
transition whose built-in or custom definition supports interaction, and a
cached previous image. For a pop from the first entry to root, use
`rootSnapshot`; otherwise use `snapshotCache.image(for: targetEntry.id)`. The
router path remains unchanged while dragging.

On finish, await router pop middleware. If middleware denies, animate progress
back to `0`. If allowed, animate to `1`, commit the pop without native animation,
then clean overlays. Cancel also animates to `0` and leaves entries untouched.

- [ ] **Step 5: Attach a leading-edge host gesture**

Use a transparent 24-point leading-edge region with a `DragGesture`. Require
horizontal movement to exceed vertical movement before beginning. Normalize
translation for RTL, update coordinator progress, and pass predicted end
velocity to the decision helper.

Do not install the custom gesture for `.system` or native iOS 18 `.zoom`; those
continue using the system gesture.

- [ ] **Step 6: Run gesture and router middleware tests**

Add `import UIKit` to `KVTransitionCoordinatorTests.swift`, then add these
coordinator assertions before running the suite:

```swift
func testInteractiveFinishCommitsAndCleansUp() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
    let from = KVNavigationEntry(route: .appFeature("b"))
    let to = KVNavigationEntry(route: .appFeature("a"))
    let request = KVTransitionRequest(
        operation: .pop,
        from: from,
        to: to,
        transitionOverride: .depth
    )
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    XCTAssertTrue(coordinator.beginInteractivePop(
        request: request,
        previousSnapshot: image,
        containerSize: CGSize(width: 320, height: 640)
    ))
    coordinator.updateInteractivePop(progress: 0.6)
    var committed = false

    await coordinator.finishInteractivePop(shouldFinish: true) {
        committed = true
        return true
    }

    XCTAssertTrue(committed)
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertNil(coordinator.activeTransition)
}

func testInteractiveMiddlewareDenialCancels() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
    let request = KVTransitionRequest(
        operation: .pop,
        from: KVNavigationEntry(route: .appFeature("b")),
        to: KVNavigationEntry(route: .appFeature("a")),
        transitionOverride: .depth
    )
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    XCTAssertTrue(coordinator.beginInteractivePop(
        request: request,
        previousSnapshot: image,
        containerSize: CGSize(width: 320, height: 640)
    ))
    coordinator.updateInteractivePop(progress: 0.6)

    await coordinator.finishInteractivePop(shouldFinish: true) { false }

    XCTAssertEqual(coordinator.progress, 0, accuracy: 0.001)
    XCTAssertEqual(coordinator.phase, .idle)
}
```

Also assert `beginInteractivePop` returns `false` when the previous entry has no
cached snapshot. Run the gesture and coordinator test targets; expected: all
pass.

- [ ] **Step 7: Commit interactive pop**

```bash
git add Sources/KVRouterKit/KVInteractivePopGesture.swift Sources/KVRouterKit/KVRouterHost.swift Sources/KVRouterKit/KVTransitionCoordinator.swift Sources/KVRouterKit/KVAppRouter.swift Tests/KVRouterKitTests
git commit -m "feat: add interactive custom pop gesture"
```

---

### Task 10: Handle Reduce Motion, Scene Interruption, and Cleanup

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [ ] **Step 1: Write interruption and Reduce Motion tests**

Add these test methods:

```swift
func testReduceMotionResolvesCustomStyleToCrossfade() {
    let state = KVTransitionVisualState.resolve(
        .flip3D(),
        KVTransitionContext(
            progress: 0,
            role: .incoming,
            operation: .push,
            containerSize: .init(width: 320, height: 640),
            isInteractive: false,
            reduceMotion: true
        )
    )
    XCTAssertEqual(state.opacity, 0)
    XCTAssertEqual(state.rotationDegrees, 0)
    XCTAssertEqual(state.scale, 1)
}

func testInterruptClearsActiveStateAndResumesWaiter() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
    let request = KVTransitionRequest(
        operation: .pop,
        from: KVNavigationEntry(route: .appFeature("b")),
        to: KVNavigationEntry(route: .appFeature("a")),
        transitionOverride: .depth
    )
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    XCTAssertTrue(coordinator.beginInteractivePop(
        request: request,
        previousSnapshot: image,
        containerSize: CGSize(width: 320, height: 640)
    ))
    coordinator.interrupt(settleToEnd: true)
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertNil(coordinator.activeTransition)
}
```

- [ ] **Step 2: Run tests and verify the interruption test fails**

Expected: missing interruption behavior.

- [ ] **Step 3: Implement deterministic interruption**

`interrupt(settleToEnd:)` must:

```swift
progress = settleToEnd ? 1 : 0
pendingCompletion?.resume()
pendingCompletion = nil
activeTransition = nil
outgoingSnapshot = nil
heroSourceSnapshot = nil
phase = .idle
```

Protect checked continuations from double resume by removing them before
resuming. Clear the snapshot cache on memory warning, host disappearance, and
router detachment.

- [ ] **Step 4: Wire SwiftUI environment and scene lifecycle**

In the host read:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
@Environment(\.scenePhase) private var scenePhase
```

Pass `reduceMotion` into every context. When scene phase leaves `.active`, call
`coordinator.interrupt(settleToEnd: true)`. On a Reduce Motion change during an
active transition, settle to the nearest endpoint and clean up.

- [ ] **Step 5: Run coordinator tests and generic builds**

Expected: all tests pass and no overlay remains after interruption tests.

- [ ] **Step 6: Commit lifecycle handling**

```bash
git add Sources/KVRouterKit/KVTransitionCoordinator.swift Sources/KVRouterKit/KVRouterHost.swift Tests/KVRouterKitTests
git commit -m "fix: settle transitions on accessibility and lifecycle changes"
```

---

### Task 11: Build the Example Transition Gallery

**Files:**
- Create: `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`
- Modify: `KVRouterKitExample/KVRouterKitExample/ContentView.swift`
- Modify: `KVRouterKitExample/KVRouterKitExample/ExampleScreens.swift`

- [ ] **Step 1: Add demo models and hero source cards**

Create a stable `DemoCard: Identifiable` model and a two-column lazy grid. Each
card uses:

```swift
.kvTransitionSource(id: card.id)
```

and pushes `DemoCardDetail` with the selected style. Keep card IDs stable for
the life of the view.

- [ ] **Step 2: Add all approved style controls**

The gallery must expose:

```swift
[
    ("System", .system),
    ("Slide", .slide()),
    ("Fade", .fade),
    ("Scale", .scale),
    ("Scale + Fade", .scaleAndFade),
    ("Shared Axis", .sharedAxis()),
    ("Depth", .depth),
    ("Reveal", .reveal()),
    ("3D Flip", .flip3D()),
]
```

Hero zoom is a separate card-driven demo because it requires a source ID. Add a
custom spring/rotation example using `KVNavigationTransition.custom`.

- [ ] **Step 3: Add rapid and fallback demos**

Add buttons that push three differently styled screens quickly and one button
that requests `.zoom(sourceID: "missing")` so the `.scaleAndFade` fallback is
visible and the debug warning can be inspected.

- [ ] **Step 4: Build the example app**

```bash
xcodebuild -scheme KVRouterKitExample -project KVRouterKitExample/KVRouterKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' build
```

Expected: build succeeds.

- [ ] **Step 5: Commit the gallery**

```bash
git add KVRouterKitExample
git commit -m "feat: demonstrate navigation transitions"
```

---

### Task 12: Update Documentation and Run Final Verification

**Files:**
- Modify: `README.md`
- Modify: source documentation comments containing `KVRouter`
- Modify: `docs/superpowers/specs/2026-08-11-kvrouterkit-navigation-transitions-design.md` only if implementation names changed during development

- [ ] **Step 1: Rewrite installation and migration documentation**

README must use:

```swift
.package(
    url: "https://github.com/khanhVu-ops/KVRouter.git",
    from: "2.0.0"
)
```

and `import KVRouterKit`. Add a migration note stating that public router type
names remain unchanged.

- [ ] **Step 2: Document default, per-push, hero, and custom usage**

Include complete examples for:

```swift
KVRouterHost(router: router, defaultTransition: .sharedAxis()) {
    HomeView()
}

router.pushView(transition: .depth) {
    DetailView()
}

CardView(item: item)
    .kvTransitionSource(id: item.id)
    .onTapGesture {
        router.pushView(transition: .zoom(sourceID: item.id)) {
            DetailView(item: item)
        }
    }
```

Add the support matrix from the design: native system all OS, native zoom iOS
18+, custom zoom iOS 16-17, custom engine for all other styles.

- [ ] **Step 3: Scan for stale names and placeholders**

Run:

```bash
rg -n 'import KVRouter\b|KVRouterExample|Sources/KVRouter|Tests/KVRouterTests|TBD|TODO|FIXME' Package.swift Sources Tests KVRouterKitExample README.md docs/superpowers
```

Expected: no stale module/example paths and no plan/spec placeholders. References
to public types such as `KVRouterHost` are expected and must remain.

- [ ] **Step 4: Run formatting and diff checks**

Run:

```bash
git diff --check
swift package dump-package
```

Expected: no whitespace errors and manifest product/target names are
`KVRouterKit`.

- [ ] **Step 5: Run the full build and test matrix**

```bash
xcodebuild -scheme KVRouterKit -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKitExample -project KVRouterKitExample/KVRouterKitExample.xcodeproj -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: two successful builds and one successful test run. If the named
simulator runtime is unavailable, list available devices with
`xcrun simctl list devices available`, select an installed iOS simulator, and
rerun the same test command with its exact name.

- [ ] **Step 6: Manually verify interaction behavior**

In the example app verify:

1. Each built-in pushes and pops with its documented reverse motion.
2. Swipe-back completes above threshold and cancels below threshold.
3. Horizontal scrolling away from the leading 24-point edge does not trigger pop.
4. Hero zoom uses native behavior on iOS 18+.
5. Hero zoom uses the custom expansion on iOS 16-17 when a runtime is available.
6. Missing source falls back without blocking the queue.
7. Reduce Motion changes custom styles to a short crossfade.
8. Three rapid pushes retain FIFO order and leave no stale overlay.

- [ ] **Step 7: Commit documentation and final fixes**

```bash
git add README.md Sources Tests KVRouterKitExample docs/superpowers
git commit -m "docs: document KVRouterKit transitions"
```
