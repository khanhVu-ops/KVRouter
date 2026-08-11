# KVRouterKit UIKit Transition Engine V3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the snapshot-driven SwiftUI transition renderer with a UIKit navigation-controller engine that animates live views, preserves screen state, supports interactive pop, and uses native iOS 18 hero zoom with an iOS 16-17 live-view fallback.

**Architecture:** Keep `NavigationStack` as the source of navigation truth and introspect its `UINavigationController`. A delegate proxy supplies an interruptible `UIViewPropertyAnimator` built from value-based transition descriptors, while `UIPercentDrivenInteractiveTransition` owns custom edge-pop progress. System transitions and iOS 18 native zoom bypass the custom animator.

**Tech Stack:** Swift 6.2, SwiftUI, UIKit, SwiftUIIntrospect 26.x, XCTest, Xcode iOS Simulator.

---

## Repository Constraints

- Work directly on `main`; the user explicitly approved this workflow.
- `.git` is read-only in the harness, so commit steps are intentionally omitted.
- Preserve the existing package rename and unrelated dirty-worktree changes.
- Use Xcode iOS destinations for tests; plain `swift test` is not authoritative for this iOS-only package.

## File Structure

- Modify `Package.swift`: add SwiftUIIntrospect.
- Replace `Sources/KVRouterKit/KVNavigationTransition.swift`: public animation and compositor-safe custom DSL.
- Create `Sources/KVRouterKit/KVTransitionDescriptor.swift`: compile built-ins and custom definitions into operation-specific endpoint states.
- Create `Sources/KVRouterKit/KVTransitionAnimator.swift`: apply endpoint states to live UIKit views and restore them.
- Create `Sources/KVRouterKit/KVNavigationControllerBridge.swift`: introspection attachment, delegate proxy, and forwarding.
- Create `Sources/KVRouterKit/KVInteractiveTransitionController.swift`: edge recognizer and percent-driven pop lifecycle.
- Replace `Sources/KVRouterKit/KVTransitionCoordinator.swift`: transaction resolution and UIKit completion ownership.
- Simplify `Sources/KVRouterKit/KVRouterHost.swift`: stable `NavigationStack` plus introspection.
- Modify `Sources/KVRouterKit/KVTransitionSource.swift`: weak live source geometry for hero fallback and native iOS 18 source modifier.
- Modify `Sources/KVRouterKit/KVAppRouter.swift`: router-controlled interactive-pop hooks and immediate custom path mutations.
- Remove obsolete renderer files after integration: `KVAnimationCompletionObserver.swift`, `KVSnapshotCapture.swift`, `KVTransitionLayer.swift`, `KVTransitionRenderPlan.swift`, and `KVTransitionVisualState.swift`.
- Replace transition tests with descriptor, animator, bridge, coordinator, and interaction coverage.
- Update `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift` and `README.md` for the new DSL.

## Verification Destination

Use the available booted simulator discovered at execution time. The previously working destination was:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=B563CD86-650B-4D14-B6D1-954F5C983B7F' test
```

Generic builds:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'generic/platform=iOS Simulator' build

xcodebuild -scheme KVRouterKitExample \
  -project KVRouterKitExample/KVRouterKitExample.xcodeproj \
  -destination 'generic/platform=iOS Simulator' build
```

---

### Task 1: Add SwiftUIIntrospect and the Value-Based Public DSL

**Files:**
- Modify: `Package.swift`
- Replace: `Sources/KVRouterKit/KVNavigationTransition.swift`
- Replace: `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`

- [ ] **Step 1: Write failing animation and custom-DSL tests**

Add tests that require the new API:

```swift
func testTimingCurveStoresDurationAndControlPoints() {
    let animation = KVTransitionAnimation.timingCurve(
        0.22, 1, 0.36, 1, duration: 0.38
    )

    XCTAssertEqual(animation.duration, 0.38)
    XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
}

func testCustomTransitionStoresPushAndMirroredPop() {
    let transition = KVNavigationTransition.custom(
        push: .init(
            incoming: .identity.relativeOffset(x: 1).opacity(0),
            outgoing: .identity.relativeOffset(x: -0.08).scale(0.97)
        ),
        pop: .mirrored,
        animation: .easeInOut(duration: 0.35)
    )

    XCTAssertEqual(transition.debugKind, .custom)
    XCTAssertTrue(transition.supportsInteractiveBack)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild -scheme KVRouterKit -destination "$KV_SIM_DESTINATION" \
  test -only-testing:KVRouterKitTests/KVNavigationTransitionTests
```

Expected: compilation fails because `KVTransitionAnimation`, `KVTransitionStage`, `KVTransitionViewState`, and the new `.custom` overload do not exist.

- [ ] **Step 3: Add the package dependency**

Use SwiftUIIntrospect 26.x:

```swift
dependencies: [
    .package(
        url: "https://github.com/siteline/swiftui-introspect",
        .upToNextMajor(from: "26.0.1")
    )
],
targets: [
    .target(
        name: "KVRouterKit",
        dependencies: [
            .product(name: "SwiftUIIntrospect", package: "swiftui-introspect")
        ],
        path: "Sources/KVRouterKit"
    )
]
```

- [ ] **Step 4: Implement the minimal value types**

Define:

```swift
public struct KVTransitionAnimation: Sendable, Equatable {
    public enum Timing: Sendable, Equatable {
        case cubic(Double, Double, Double, Double)
        case spring(dampingRatio: Double, initialVelocity: Double)
    }

    public let duration: TimeInterval
    let timing: Timing

    public static func easeInOut(duration: TimeInterval) -> Self
    public static func easeOut(duration: TimeInterval) -> Self
    public static func timingCurve(
        _ c0x: Double, _ c0y: Double,
        _ c1x: Double, _ c1y: Double,
        duration: TimeInterval
    ) -> Self
    public static func spring(
        response: TimeInterval,
        dampingFraction: Double,
        blendDuration: TimeInterval = 0
    ) -> Self
}

public struct KVTransitionViewState: Sendable, Equatable {
    public static let identity = Self()
    public func opacity(_ value: CGFloat) -> Self
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> Self
    public func relativeOffset(x: CGFloat = 0, y: CGFloat = 0) -> Self
    public func scale(_ value: CGFloat) -> Self
    public func scale(x: CGFloat, y: CGFloat) -> Self
    public func rotation(_ angle: Angle) -> Self
    public func rotation3D(
        _ angle: Angle,
        axis: (x: CGFloat, y: CGFloat, z: CGFloat),
        perspective: CGFloat = 1
    ) -> Self
    public func cornerRadius(_ value: CGFloat) -> Self
    public func zPosition(_ value: CGFloat) -> Self
    public func reveal(from origin: UnitPoint) -> Self
}

public struct KVTransitionStage: Sendable, Equatable {
    public let incoming: KVTransitionViewState
    public let outgoing: KVTransitionViewState
}

public enum KVPopTransition: Sendable, Equatable {
    case mirrored
    case custom(KVTransitionStage)
}
```

Keep existing built-in factory names and replace `SwiftUI.Animation` overrides with `KVTransitionAnimation`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Expected: all `KVNavigationTransitionTests` pass.

---

### Task 2: Compile Built-In and Custom Transition Descriptors

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionDescriptor.swift`
- Create: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`

- [ ] **Step 1: Write failing descriptor tests**

Cover operation endpoints and Reduce Motion:

```swift
func testSlidePushUsesFullIncomingAndSubtleOutgoingOffsets() {
    let descriptor = KVNavigationTransition.slide().descriptor(
        operation: .push,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.relativeOffset, CGSize(width: 1, height: 0))
    XCTAssertEqual(descriptor.outgoing.relativeOffset, CGSize(width: -0.05, height: 0))
}

func testMirroredPopSwapsPushRoles() {
    let push = KVTransitionStage(
        incoming: .identity.relativeOffset(x: 1),
        outgoing: .identity.relativeOffset(x: -0.08)
    )
    let transition = KVNavigationTransition.custom(
        push: push,
        pop: .mirrored,
        animation: .easeInOut(duration: 0.35)
    )
    let pop = transition.descriptor(operation: .pop, reduceMotion: false)

    XCTAssertEqual(pop.incoming.relativeOffset.width, -0.08)
    XCTAssertEqual(pop.outgoing.relativeOffset.width, 1)
}

func testReduceMotionCompilesToFadeOnly() {
    let descriptor = KVNavigationTransition.flip3D().descriptor(
        operation: .push,
        reduceMotion: true
    )

    XCTAssertEqual(descriptor.incoming.opacity, 0)
    XCTAssertTrue(descriptor.incoming.transforms.isEmpty)
}
```

- [ ] **Step 2: Run descriptor tests and verify RED**

Expected: compile failure because `descriptor(operation:reduceMotion:)` does not exist.

- [ ] **Step 3: Implement descriptor compilation**

Create operation-specific `KVTransitionDescriptor` with incoming/outgoing endpoint states, animation, reveal metadata, and interactive-back support. Use explicit built-in stages for push and pop; `.mirrored` swaps push incoming/outgoing endpoints without re-running SwiftUI code.

Default motion values:

```swift
slide: incoming relative 1.0, outgoing -0.05
sharedAxis: incoming relative 0.12 with opacity 0.15, outgoing -0.05 with opacity 0.82
depth: incoming scale 1.04 with opacity 0.4, outgoing scale 0.96 with opacity 0.9
flip3D: incoming 70 degrees, outgoing -12 degrees
scaleAndFade: incoming scale 0.94 with opacity 0, outgoing scale 0.98 with opacity 0.92
```

Reduce Motion always returns incoming opacity zero, outgoing identity, and an ease-in-out duration of 0.18 seconds.

- [ ] **Step 4: Run descriptor and public API tests and verify GREEN**

Expected: descriptor and navigation-transition tests pass.

---

### Task 3: Build the Live UIKit Animator

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionAnimator.swift`
- Create: `Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift`

- [ ] **Step 1: Write failing resolved-state tests**

```swift
func testRelativeOffsetResolvesAgainstContainerSize() {
    let resolved = KVTransitionViewState.identity
        .relativeOffset(x: 0.5, y: -0.25)
        .resolved(containerSize: CGSize(width: 320, height: 640))

    XCTAssertEqual(resolved.translation, CGSize(width: 160, height: -160))
}

func testThreeDimensionalStateAddsPerspective() {
    let resolved = KVTransitionViewState.identity
        .rotation3D(.degrees(70), axis: (0, 1, 0), perspective: 1)
        .resolved(containerSize: CGSize(width: 320, height: 640))

    XCTAssertNotEqual(resolved.transform.m34, 0)
}
```

- [ ] **Step 2: Run animator tests and verify RED**

Expected: compile failure because resolved UIKit state does not exist.

- [ ] **Step 3: Implement transient view property storage and state application**

Create `KVTransitionViewSnapshot` and `KVResolvedTransitionViewState`. Resolve ordered primitives into one `CATransform3D`, alpha, corner radius, z-position, and optional reveal origin. Apply them through one helper that can restore all original values.

- [ ] **Step 4: Write failing hierarchy and cancellation tests**

Use a controlled `UIViewControllerContextTransitioning` test double to assert push inserts `toView` above `fromView`, pop inserts it below, and cancellation restores transforms, masks, interaction, and hierarchy.

- [ ] **Step 5: Implement `KVViewControllerTransitionAnimator`**

Implement `transitionDuration`, `animateTransition`, and `interruptibleAnimator`. Cache one `UIViewPropertyAnimator` per context. Apply initial states before animation, identity/final states inside the animation block, and call `completeTransition` exactly once in completion.

- [ ] **Step 6: Run animator tests and verify GREEN**

Expected: resolved-state, hierarchy, completion, and cancellation tests pass.

---

### Task 4: Add the Navigation Controller Delegate Bridge and Coordinator Transactions

**Files:**
- Create: `Sources/KVRouterKit/KVNavigationControllerBridge.swift`
- Replace: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Replace: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`
- Create: `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`

- [ ] **Step 1: Write failing backend and transaction tests**

```swift
func testSystemTransitionDoesNotCreateCustomAnimator() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .system)
    let request = testPushRequest(transition: .system)

    await coordinator.perform(request) {}

    XCTAssertNil(coordinator.pendingTransaction)
}

func testCustomTransitionWaitsForUIKitCompletion() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
    coordinator.isBridgeAttached = true
    let request = testPushRequest(transition: .slide())
    var finished = false

    let task = Task { @MainActor in
        await coordinator.perform(request) {}
        finished = true
    }
    await Task.yield()
    XCTAssertFalse(finished)

    coordinator.completePendingTransition(cancelled: false)
    await task.value
    XCTAssertTrue(finished)
}
```

- [ ] **Step 2: Run coordinator tests and verify RED**

Expected: compile failure because transaction-based coordinator state does not exist.

- [ ] **Step 3: Implement transaction-based coordinator**

Replace progress and snapshot state with one pending transaction. Resolve `.system`, `.nativeZoom`, and `.custom`; mutate custom paths inside a short SwiftUI animation transaction; wait only when a bridge is attached; complete idempotently from animator, `didShow`, interruption, or watchdog.

- [ ] **Step 4: Write failing bridge attachment and forwarding tests**

Verify attach is idempotent, detach restores the original delegate, and custom animation resolution returns an animator only for a matching pending custom transaction.

- [ ] **Step 5: Implement delegate proxy and bridge**

The proxy retains the base delegate, implements `responds(to:)` and `forwardingTarget(for:)`, forwards `willShow`/`didShow`, and asks the coordinator for animator and interaction controllers.

- [ ] **Step 6: Run coordinator and bridge tests and verify GREEN**

Expected: all focused tests pass without published progress or snapshots.

---

### Task 5: Integrate the Stable Host and Router Mutation Pipeline

**Files:**
- Simplify: `Sources/KVRouterKit/KVRouterHost.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter.swift`
- Modify: `Tests/KVRouterKitTests/KVAppRouterTests.swift`

- [ ] **Step 1: Write failing router sequencing tests**

Add a test transition driver that records whether mutation happens exactly once and whether FIFO operations wait for the driver's completion.

- [ ] **Step 2: Run router tests and verify RED against the new driver contract**

Expected: failures until the host/coordinator path uses UIKit completion rather than deferred snapshot progress.

- [ ] **Step 3: Simplify `KVRouterHost`**

Render one stable `NavigationStack`, sheet, cover, URL handling, environment values, and:

```swift
.introspect(
    .navigationStack,
    on: .iOS(.v16, .v17, .v18, .v26),
    scope: [.receiver, .ancestor]
) { navigationController in
    coordinator.attach(to: navigationController)
}
```

Remove `GeometryReader`, transition ZStack layers, animation completion observation, capture probe, and SwiftUI drag gesture.

- [ ] **Step 4: Update router coordination hooks**

Keep the existing `KVTransitionDriving.perform` contract. Ensure custom push/pop path mutation happens once inside the coordinator-owned animated transaction. Keep replace and bulk path changes system-owned.

- [ ] **Step 5: Run router, coordinator, and package build verification**

Expected: focused tests pass and the package builds with the stable host.

---

### Task 6: Implement UIKit Interactive Edge Pop

**Files:**
- Create: `Sources/KVRouterKit/KVInteractiveTransitionController.swift`
- Modify: `Sources/KVRouterKit/KVNavigationControllerBridge.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Sources/KVRouterKit/KVAppRouter.swift`
- Replace: `Tests/KVRouterKitTests/KVInteractivePopGestureTests.swift`

- [ ] **Step 1: Write failing gesture decision and lifecycle tests**

Test LTR/RTL translation, progress clamping, velocity threshold, middleware denial, cancellation, and one-time finish.

- [ ] **Step 2: Run interaction tests and verify RED**

Expected: compile failure for the UIKit interaction controller.

- [ ] **Step 3: Implement the interaction controller**

Attach one `UIScreenEdgePanGestureRecognizer` to the navigation controller. On begin, create `UIPercentDrivenInteractiveTransition`, start middleware evaluation, mark the operation router-controlled, and call `popViewController(animated: true)`. On change call `update`; on end call `finish` or `cancel` after combining gesture intent with middleware.

- [ ] **Step 4: Add path-gating only if the runtime checkpoint requires it**

Run an integration probe on available iOS runtimes. If SwiftUI proposes path removal before cancellation resolves, gate cleanup and commit/discard the proposal with the interaction outcome. If it updates only on completion, keep the simpler binding path.

- [ ] **Step 5: Run interaction and router tests and verify GREEN**

Expected: interactive finish pops once, cancellation preserves entries and builders, and no SwiftUI state changes per frame.

---

### Task 7: Implement Native and Live Hero Zoom

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionSource.swift`
- Modify: `Sources/KVRouterKit/KVTransitionAnimator.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Add tests to descriptor, animator, and coordinator suites.

- [ ] **Step 1: Write failing source-geometry and fallback tests**

Test finite/non-empty frame validation, weak source lifetime, container coordinate conversion, native backend persistence for an entry, and scale-and-fade fallback when source geometry disappears.

- [ ] **Step 2: Run hero tests and verify RED**

Expected: failures until the registry exposes live source views and the animator supports hero geometry.

- [ ] **Step 3: Preserve native iOS 18 zoom**

Keep `matchedTransitionSource` on `kvTransitionSource` and `.navigationTransition(.zoom)` on destination entries marked native by the coordinator. Return no custom animator for native zoom.

- [ ] **Step 4: Implement iOS 16-17 live hero state**

Resolve source geometry into the transition container. Push initializes the live destination at source center, X/Y scale, corner radius, and clipping before animating to identity. Pop resolves the current source in the live previous screen and animates the outgoing screen into it. Missing geometry resolves to scale-and-fade before mutation.

- [ ] **Step 5: Run hero and animator tests and verify GREEN**

Expected: native and fallback backend tests pass with no snapshot allocation.

---

### Task 8: Remove Renderer V2, Update Examples, and Verify Performance

**Files:**
- Remove obsolete renderer files listed in File Structure.
- Update: `README.md`
- Update: `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`
- Update remaining tests that reference snapshots, progress, or SwiftUI transition contexts.

- [ ] **Step 1: Replace gallery custom-transition examples with the new DSL**

Demonstrate built-ins plus one custom card transition using `KVTransitionStage` and `KVTransitionAnimation`.

- [ ] **Step 2: Remove obsolete renderer code and tests**

Delete snapshot caches/capture, SwiftUI transition layer, visual progress state, render plan, and completion observer after no production references remain.

- [ ] **Step 3: Run source scans**

```bash
rg -n "drawHierarchy|KVSnapshot|KVTransitionLayer|@Published.*progress|KVTransitionContext" \
  Sources/KVRouterKit Tests/KVRouterKitTests
```

Expected: no production transition path contains snapshot capture or progress-driven SwiftUI rendering.

- [ ] **Step 4: Run full verification**

```bash
xcodebuild -scheme KVRouterKit -destination "$KV_SIM_DESTINATION" test
xcodebuild -scheme KVRouterKit -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKitExample \
  -project KVRouterKitExample/KVRouterKitExample.xcodeproj \
  -destination 'generic/platform=iOS Simulator' build
git diff --check
```

Expected: all tests and builds pass and diff check is clean.

- [ ] **Step 5: Run Simulator behavior and performance verification**

Launch the transition gallery in Debug for correctness, then Release for performance. Exercise system, slide, shared-axis, depth, reveal, flip3D, and zoom push/pop plus interactive finish/cancel. Verify state retention, no black frames, no stale hierarchy, and no snapshot allocations. Record a Time Profiler trace on Simulator if transition hitches remain.
