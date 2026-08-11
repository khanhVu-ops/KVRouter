# KVRouterKit Transition Renderer V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom transition renderer with a stable, operation-aware pipeline that preserves SwiftUI screen state, fixes black snapshots and layer ordering, and reduces animation cost.

**Architecture:** Keep one stable `NavigationStack` surface for the host lifetime. A pure render plan decides live/snapshot roles and path-mutation timing; custom push mutates before animation, while custom pop mutates only after the outgoing live screen finishes. Capture the host's actual `UIWindow` region once before push, reuse cached snapshots for pop, and scope coordinator observation away from destination content.

**Tech Stack:** Swift 6.2, SwiftUI, UIKit window capture, XCTest, Xcode iOS Simulator builds.

**Repository note:** Work continues directly on `main` with explicit user approval. Commit steps are omitted because this harness exposes `.git` as read-only.

---

## File Structure

- Create `Sources/KVRouterKit/KVTransitionRenderPlan.swift`: pure operation/role/mutation-timing model.
- Modify `Sources/KVRouterKit/KVTransitionCoordinator.swift`: operation-aware preparation, deferred pop mutation, snapshot reuse and fallback.
- Modify `Sources/KVRouterKit/KVSnapshotCapture.swift`: window/frame capture and reliable fallback rendering.
- Modify `Sources/KVRouterKit/KVRouterHost.swift`: stable navigation surface, snapshot below live content, narrow observation.
- Modify `Sources/KVRouterKit/KVTransitionVisualState.swift`: restrained motion endpoints without full-screen blur.
- Modify `Sources/KVRouterKit/KVNavigationTransition.swift`: faster, highly damped default timings.
- Modify `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`: render-plan, mutation timing, capture fallback and metadata regressions.
- Modify `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`: revised visual endpoint and timing behavior where appropriate.
- Modify `README.md`: renderer behavior and fallback notes only if the public description becomes inaccurate.

## Verification Destination

Use the installed simulator already proven by the package test suite:

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

### Task 1: Add the Pure Render Plan

**Files:**
- Create: `Sources/KVRouterKit/KVTransitionRenderPlan.swift`
- Test: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [x] **Step 1: Write failing render-plan tests**

Add tests that express the required ordering and mutation semantics:

```swift
func testPushRenderPlanPlacesSnapshotBelowIncomingLiveContent() {
    let plan = KVTransitionRenderPlan.resolve(operation: .push, isInteractive: false)

    XCTAssertEqual(plan.snapshotRole, .outgoing)
    XCTAssertEqual(plan.liveRole, .incoming)
    XCTAssertEqual(plan.mutationTiming, .beforeAnimation)
}

func testProgrammaticPopDefersMutationUntilAfterAnimation() {
    let plan = KVTransitionRenderPlan.resolve(operation: .pop, isInteractive: false)

    XCTAssertEqual(plan.snapshotRole, .incoming)
    XCTAssertEqual(plan.liveRole, .outgoing)
    XCTAssertEqual(plan.mutationTiming, .afterAnimation)
}

func testInteractivePopOnlyMutatesOnCommit() {
    let plan = KVTransitionRenderPlan.resolve(operation: .pop, isInteractive: true)

    XCTAssertEqual(plan.snapshotRole, .incoming)
    XCTAssertEqual(plan.liveRole, .outgoing)
    XCTAssertEqual(plan.mutationTiming, .interactiveCommit)
}
```

- [x] **Step 2: Run the focused tests and verify RED**

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=B563CD86-650B-4D14-B6D1-954F5C983B7F' \
  test -only-testing:KVRouterKitTests/KVTransitionCoordinatorTests
```

Expected: compile failure because `KVTransitionRenderPlan` and `KVPathMutationTiming` do not exist.

- [x] **Step 3: Implement the minimal pure model**

First add `Equatable` to the existing role and operation enums:

```swift
public enum KVTransitionRole: Sendable, Equatable {
    case incoming
    case outgoing
}

public enum KVTransitionOperation: Sendable, Equatable {
    case push
    case pop
    case replace
}
```

Then create:

```swift
import Foundation

enum KVPathMutationTiming: Equatable {
    case beforeAnimation
    case afterAnimation
    case interactiveCommit
}

struct KVTransitionRenderPlan: Equatable {
    let snapshotRole: KVTransitionRole
    let liveRole: KVTransitionRole
    let mutationTiming: KVPathMutationTiming

    static func resolve(
        operation: KVTransitionOperation,
        isInteractive: Bool
    ) -> Self {
        if operation == .pop {
            return Self(
                snapshotRole: .incoming,
                liveRole: .outgoing,
                mutationTiming: isInteractive ? .interactiveCommit : .afterAnimation
            )
        }

        return Self(
            snapshotRole: .outgoing,
            liveRole: .incoming,
            mutationTiming: .beforeAnimation
        )
    }
}
```

- [x] **Step 4: Run the focused tests and verify GREEN**

Expected: the three render-plan tests pass.

---

### Task 2: Defer Custom Pop Mutation and Reuse the Previous Snapshot

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [x] **Step 1: Write failing coordinator sequencing tests**

Use a valid cached image and an unattached renderer so progress resolves synchronously:

```swift
func testCustomPushMutatesAtProgressZero() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
    coordinator.captureVisibleSnapshot = { self.testSnapshot() }
    let destination = KVNavigationEntry(route: .appFeature("detail"))
    let request = KVTransitionRequest(
        operation: .push,
        from: nil,
        to: destination,
        transitionOverride: .slide()
    )
    var mutationProgress: CGFloat?

    await coordinator.perform(request) {
        mutationProgress = coordinator.progress
    }

    XCTAssertEqual(mutationProgress, 0)
}

func testCustomPopMutatesOnlyAtProgressOne() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
    let from = KVNavigationEntry(route: .appFeature("detail"))
    let to = KVNavigationEntry(route: .appFeature("home"))
    coordinator.snapshotCache.insert(testSnapshot(), for: to.id)
    let request = KVTransitionRequest(
        operation: .pop,
        from: from,
        to: to,
        transitionOverride: .slide()
    )
    var mutationProgress: CGFloat?

    await coordinator.perform(request) {
        mutationProgress = coordinator.progress
    }

    XCTAssertEqual(mutationProgress, 1)
}

func testMissingPreviousSnapshotFallsBackToSystemPop() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
    let request = KVTransitionRequest(
        operation: .pop,
        from: KVNavigationEntry(route: .appFeature("detail")),
        to: KVNavigationEntry(route: .appFeature("home")),
        transitionOverride: .slide()
    )

    var hadActiveCustomTransition: Bool?
    await coordinator.perform(request) {
        hadActiveCustomTransition = coordinator.activeTransition != nil
    }

    XCTAssertEqual(hadActiveCustomTransition, false)
}
```

Add a private `testSnapshot()` helper that creates a small opaque `UIImage` and wraps it in `KVSnapshot`.

- [x] **Step 2: Run the focused coordinator tests and verify RED**

Expected: compile failure for `captureVisibleSnapshot`, followed by behavioral failure until pop mutation is deferred and missing snapshots bypass custom rendering.

- [x] **Step 3: Add injectable capture and render-plan state**

Add internal coordinator state used by production and tests:

```swift
var captureVisibleSnapshot: @MainActor () -> KVSnapshot? = { nil }
var captureFrame: CGRect = .zero
```

Extend active transition state so the host consumes the pure plan instead of
re-deriving z-order from `isInteractive`:

```swift
struct KVActiveTransition {
    let request: KVTransitionRequest
    let resolved: KVResolvedTransition
    let isInteractive: Bool
    let renderPlan: KVTransitionRenderPlan
}
```

Construct the plan with `KVTransitionRenderPlan.resolve(operation:isInteractive:)`
at every active-transition creation site.

- [x] **Step 4: Split custom preparation by operation**

Replace unconditional current-screen capture with:

```swift
private func prepareBackground(
    for request: KVTransitionRequest,
    resolved: KVResolvedTransition
) -> KVResolvedTransition {
    if request.operation == .pop {
        guard let image = previousSnapshot(for: request) else {
            return KVResolvedTransition(transition: .system, backend: .system)
        }
        outgoingSnapshot = KVSnapshot(
            image: image,
            frame: captureFrame,
            cornerRadius: 0
        )
        return prepareHeroSnapshot(for: request, resolved: resolved)
    }

    guard let snapshot = captureVisibleSnapshot() else {
        return KVResolvedTransition(transition: .system, backend: .system)
    }
    outgoingSnapshot = snapshot
    if request.operation == .push {
        if let from = request.from {
            snapshotCache.insert(snapshot, for: from.id)
        } else {
            rootSnapshot = snapshot.image
        }
    }
    return prepareHeroSnapshot(for: request, resolved: resolved)
}
```

Store the latest host size/frame so cached images can be wrapped without recapturing.

If this preparation returns `.system`, skip custom render-state installation,
run the path mutation once, record `.system`, and use the common cleanup path.

- [x] **Step 5: Apply mutation timing inside `perform`**

Use the pure render plan:

```swift
let renderPlan = KVTransitionRenderPlan.resolve(
    operation: request.operation,
    isInteractive: false
)

if renderPlan.mutationTiming == .beforeAnimation {
    performWithoutAnimation(mutation)
}

phase = .animating
await animateProgress(to: 1, animation: resolvedAnimation)

if renderPlan.mutationTiming == .afterAnimation {
    performWithoutAnimation(mutation)
}
```

Add one helper that disables system animation for a mutation:

```swift
private func performWithoutAnimation(_ mutation: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, mutation)
}
```

Remove `cacheVisibleDestination(for:)`; snapshots are now captured only before push/replace.

- [x] **Step 6: Run focused tests and verify GREEN**

Expected: render-plan and mutation-timing tests pass, existing coordinator tests remain green.

---

### Task 3: Capture the Actual Window Region Reliably

**Files:**
- Modify: `Sources/KVRouterKit/KVSnapshotCapture.swift`
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Test: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [x] **Step 1: Write failing geometry validation tests**

Expose a pure validation helper and test invalid capture regions:

```swift
func testSnapshotCaptureRejectsInvalidFrames() {
    XCTAssertFalse(KVSnapshotCapture.isValid(frame: .zero))
    XCTAssertFalse(KVSnapshotCapture.isValid(
        frame: CGRect(x: .infinity, y: 0, width: 100, height: 100)
    ))
    XCTAssertTrue(KVSnapshotCapture.isValid(
        frame: CGRect(x: 0, y: 0, width: 320, height: 640)
    ))
}
```

- [x] **Step 2: Run the test and verify RED**

Expected: compile failure because `isValid(frame:)` does not exist.

- [x] **Step 3: Add a dedicated host window probe and window-region capture**

Keep `KVViewProbe` unchanged because hero sources use it to retain their
concrete `UIView`. Add a host-only probe:

```swift
struct KVHostCaptureProbe: UIViewRepresentable {
    let onUpdate: @MainActor (UIWindow, CGRect) -> Void

    func makeUIView(context: Context) -> KVHostCaptureUIView {
        let view = KVHostCaptureUIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onLayout = onUpdate
        return view
    }

    func updateUIView(_ uiView: KVHostCaptureUIView, context: Context) {
        uiView.onLayout = onUpdate
        uiView.reportLayout()
    }
}

final class KVHostCaptureUIView: UIView {
    var onLayout: (@MainActor (UIWindow, CGRect) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        reportLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportLayout()
    }

    func reportLayout() {
        guard let window else { return }
        onLayout?(window, convert(bounds, to: window))
    }
}
```

Add the capture API:

```swift
static func isValid(frame: CGRect) -> Bool {
    frame.width.isFinite
        && frame.height.isFinite
        && frame.minX.isFinite
        && frame.minY.isFinite
        && frame.width > 0
        && frame.height > 0
}

static func capture(window: UIWindow, frame: CGRect) -> KVSnapshot? {
    guard isValid(frame: frame) else { return nil }

    let localBounds = CGRect(origin: .zero, size: frame.size)
    let format = UIGraphicsImageRendererFormat()
    format.scale = window.screen.scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(bounds: localBounds, format: format)
    var hierarchySucceeded = false
    let image = renderer.image { context in
        UIColor.systemBackground.setFill()
        context.fill(localBounds)
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
        hierarchySucceeded = window.drawHierarchy(
            in: window.bounds,
            afterScreenUpdates: false
        )
        if !hierarchySucceeded {
            window.layer.render(in: context.cgContext)
        }
        context.cgContext.restoreGState()
    }

    return KVSnapshot(image: image, frame: frame, cornerRadius: 0)
}
```

- [x] **Step 4: Install the production capture closure from the host probe**

In the stable host background probe:

```swift
KVHostCaptureProbe { window, frame in
    coordinator.captureFrame = CGRect(origin: .zero, size: frame.size)
    coordinator.captureVisibleSnapshot = { [weak window] in
        guard let window else { return nil }
        return KVSnapshotCapture.capture(window: window, frame: frame)
    }
}
```

Reset the closure to `{ nil }` on host disappearance.

- [x] **Step 5: Run focused tests and generic package build**

Expected: validation tests pass and the package compiles for iOS 16.

---

### Task 4: Keep the NavigationStack Structurally Stable

**Files:**
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Modify: `Sources/KVRouterKit/KVTransitionLayer.swift`
- Test: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [x] **Step 1: Re-run the render-plan regression tests as a GREEN baseline**

Add tests that assert host rendering can derive roles without inspecting interactivity directly:

```swift
func testPushLiveSurfaceUsesIncomingRole() {
    XCTAssertEqual(
        KVTransitionRenderPlan.resolve(operation: .push, isInteractive: false).liveRole,
        .incoming
    )
}

func testPopLiveSurfaceUsesOutgoingRole() {
    XCTAssertEqual(
        KVTransitionRenderPlan.resolve(operation: .pop, isInteractive: false).liveRole,
        .outgoing
    )
}
```

These tests already pass after Task 1. They are the behavioral guard while the
host implementation is refactored without changing the public API.

- [x] **Step 2: Replace conditional stack ownership with one permanent surface**

The host Z-stack must always use this order:

```swift
ZStack {
    transitionBackground(size: proxy.size)
    liveNavigationSurface(size: proxy.size)
    interactivePopRegion(size: proxy.size)
}
```

`liveNavigationSurface` always returns the same `KVTransitionLayer` structure:

```swift
KVTransitionLayer(
    content: AnyView(navigationStack),
    transition: active?.resolved.transition ?? .system,
    context: transitionContext(
        role: active?.renderPlan.liveRole ?? .incoming,
        operation: active?.request.operation ?? .push,
        size: size,
        progress: active == nil ? 1 : coordinator.progress
    )
)
```

The idle path uses progress `1` and identity state; it does not return a different raw `NavigationStack` branch.

- [x] **Step 3: Render the cached snapshot only below the live surface**

Use `active.renderPlan.snapshotRole` for its context. There is no branch that places the previous-screen snapshot above an incoming push destination.

- [x] **Step 4: Remove destination-level coordinator observation**

Change `KVRouterRootDestinations` and `KVRouterDestinationContent` from:

```swift
@ObservedObject var coordinator: KVTransitionCoordinator
```

to:

```swift
let coordinator: KVTransitionCoordinator
```

The native zoom lookup is one-time when the destination is created; interactive progress must not invalidate destination bodies.

- [x] **Step 5: Build the package and run coordinator tests**

Expected: build succeeds; pure z-order tests and all existing coordinator tests pass.

---

### Task 5: Retune Built-In and Hero Motion

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionVisualState.swift`
- Modify: `Sources/KVRouterKit/KVNavigationTransition.swift`
- Modify: `Sources/KVRouterKit/KVRouterHost.swift`
- Test: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`

- [x] **Step 1: Replace old endpoint assertions with restrained endpoints**

Assert representative values:

```swift
XCTAssertEqual(
    KVTransitionVisualState.resolve(.scale, incoming).scale,
    0.96,
    accuracy: 0.001
)
XCTAssertEqual(
    KVTransitionVisualState.resolve(.sharedAxis(), incoming).offset.width,
    38.4,
    accuracy: 0.001
)
XCTAssertEqual(
    KVTransitionVisualState.resolve(.depth, outgoing.withProgress(1)).blurRadius,
    0,
    accuracy: 0.001
)
XCTAssertEqual(
    KVTransitionVisualState.resolve(.flip3D(), incoming).rotationDegrees,
    22,
    accuracy: 0.001
)
```

For a `320` point container, shared-axis `38.4` is a `12%` entrance.

- [x] **Step 2: Run focused visual-state tests and verify RED**

Expected: failures show the old `0.92`, `24%`, blur `10`, and `72` degree values.

- [x] **Step 3: Implement the revised visual states**

Use these constraints:

```swift
case .scale:
    return Self(
        opacity: context.opacity(from: 0.84),
        scale: incoming ? 1 - (0.04 * amount) : 1 - (0.015 * progress)
    )
case .scaleAndFade:
    return Self(
        opacity: context.opacity(from: 0),
        scale: incoming ? 1 - (0.06 * amount) : 1 - (0.02 * progress)
    )
case .sharedAxis(let axis):
    let distance = incoming ? amount * 0.12 : progress * 0.05
    return Self(
        opacity: context.opacity(from: incoming ? 0.15 : 0.82),
        scale: 1,
        offset: axis == .horizontal
            ? CGSize(width: context.containerSize.width * distance * direction, height: 0)
            : CGSize(width: 0, height: context.containerSize.height * distance)
    )
case .depth:
    return incoming
        ? Self(opacity: context.opacity(from: 0.4), scale: 1 - (0.03 * amount))
        : Self(opacity: 1 - (0.22 * progress), scale: 1 - (0.025 * progress))
case .flip3D(let axis):
    return Self(
        opacity: context.opacity(from: incoming ? 0.35 : 0.72),
        scale: 1 - (0.02 * amount),
        rotationDegrees: incoming ? 22 * amount : -12 * progress,
        rotationAxis: axis == .vertical ? (0, 1, 0) : (1, 0, 0)
    )
```

Keep reveal transform-only and remove full-screen blur from all cases.

- [x] **Step 4: Tighten default timings**

Use high-damping navigation curves:

```swift
case .fade:
    return .easeOut(duration: 0.24)
case .slide, .sharedAxis:
    return .spring(response: 0.34, dampingFraction: 0.94)
case .scale, .scaleAndFade, .reveal:
    return .easeOut(duration: 0.3)
case .depth, .zoom:
    return .spring(response: 0.38, dampingFraction: 0.94)
case .flip3D:
    return .easeInOut(duration: 0.34)
```

- [x] **Step 5: Simplify custom hero fallback**

Keep the source-geometry transform, but do not strongly fade/transform both full-screen layers. The background snapshot remains restrained while the live destination uses the source expansion only for the relevant incoming/outgoing role. Reduce Motion remains opacity-only.

- [x] **Step 6: Run focused tests and package build**

Expected: revised endpoint tests pass and the package builds without warnings introduced by this task.

---

### Task 6: Full Regression and Documentation Check

**Files:**
- Modify: `README.md` only if fallback behavior text needs correction.
- Modify: `docs/superpowers/plans/2026-08-11-kvrouterkit-transition-renderer-v2.md` checkboxes as work completes.

- [x] **Step 1: Run the full package test suite**

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=B563CD86-650B-4D14-B6D1-954F5C983B7F' test
```

Expected: all tests pass with zero failures.

- [x] **Step 2: Build the package and example app**

Run both generic build commands from the verification section. Expected: two `BUILD SUCCEEDED` results.

- [x] **Step 3: Run static checks**

```bash
git diff --check
rg -n 'TODO|FIXME|TBD|import KVRouter\b|KVRouterExample' \
  Package.swift Sources Tests KVRouterKitExample README.md
```

Expected: no whitespace errors, placeholders, stale imports, or stale example names.

- [ ] **Step 4: Manual Simulator verification handoff**

Ask the user to verify in Debug Simulator:

1. mutate local state on screen A, push B with every custom style, then pop and confirm A retains state;
2. confirm A is below B during push and B is above A during pop;
3. confirm no black snapshot appears;
4. compare slide/shared-axis/depth/flip smoothness;
5. verify interactive pop completion and cancellation;
6. verify native iOS 18 hero zoom and custom fallback where runtimes are available.

The current harness cannot use CoreSimulator UI inspection, so do not claim these visual checks passed until the user confirms them.
