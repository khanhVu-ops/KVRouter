# KVRouterKit Scale and Flip Motion Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the built-in scale preset with Collapse and Reveal motion and replace the 3D preset with a reversible true 180-degree live-view card flip.

**Architecture:** Keep the public transition API and the existing live-view UIKit engine. Compile the new presets into `KVTransitionDescriptor`, add internal endpoint delay factors for staged scale motion, and have the interruptible property animator schedule incoming and outgoing endpoint animations independently.

**Tech Stack:** Swift 6.2, SwiftUI, UIKit, `UIViewPropertyAnimator`, XCTest, Xcode Simulator.

---

## File Map

- `Sources/KVRouterKit/KVTransitionDescriptor.swift`: Compile scale and flip presets into endpoint states and internal delay factors.
- `Sources/KVRouterKit/KVNavigationTransition.swift`: Define the built-in durations and cubic timing curves.
- `Sources/KVRouterKit/KVTransitionAnimator.swift`: Apply incoming and outgoing endpoint animations with independent delay factors while preserving the interruptible animator.
- `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`: Lock scale/flip push and pop geometry, opacity, perspective, and delay behavior.
- `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`: Lock the new preset timing curves and durations.
- `Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift`: Verify live-view 3D state and restoration remain safe.

### Task 1: Compile Collapse and Reveal Scale Motion

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionDescriptor.swift:3`
- Modify: `Sources/KVRouterKit/KVTransitionDescriptor.swift:68`
- Modify: `Sources/KVRouterKit/KVTransitionAnimator.swift:327`
- Test: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`

- [ ] **Step 1: Write failing descriptor tests for scale push and pop**

Add these tests to `KVTransitionDescriptorTests`:

```swift
func testScalePushCollapsesOutgoingAndRevealsIncoming() {
    let descriptor = KVNavigationTransition.scale.descriptor(
        operation: .push,
        reduceMotion: false
    )

    XCTAssertEqual(
        descriptor.incoming.scale,
        CGSize(width: 0.94, height: 0.94)
    )
    XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(
        descriptor.outgoing.scale,
        CGSize(width: 0.84, height: 0.84)
    )
    XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(descriptor.incomingDelayFactor, 0.08, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoingDelayFactor, 0, accuracy: 0.001)
}

func testScalePopMirrorsCollapseAndRevealEndpoints() {
    let descriptor = KVNavigationTransition.scale.descriptor(
        operation: .pop,
        reduceMotion: false
    )

    XCTAssertEqual(
        descriptor.incoming.scale,
        CGSize(width: 0.84, height: 0.84)
    )
    XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(
        descriptor.outgoing.scale,
        CGSize(width: 0.94, height: 0.94)
    )
    XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(descriptor.incomingDelayFactor, 0.08, accuracy: 0.001)
}

func testScaleReduceMotionRemovesEndpointDelays() {
    let descriptor = KVNavigationTransition.scale.descriptor(
        operation: .push,
        reduceMotion: true
    )

    XCTAssertEqual(descriptor.incomingDelayFactor, 0, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoingDelayFactor, 0, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests
```

Expected: FAIL because the current scale values are `0.96` and `0.985`, opacity remains `1`, and delay-factor properties do not exist.

- [ ] **Step 3: Add internal endpoint timing to the descriptor**

Replace the stored-only descriptor declaration with an initializer that preserves zero-delay defaults:

```swift
struct KVTransitionDescriptor {
    let incoming: KVTransitionEndpoint
    let outgoing: KVTransitionEndpoint
    let animation: KVTransitionAnimation
    let supportsInteractiveBack: Bool
    let incomingDelayFactor: CGFloat
    let outgoingDelayFactor: CGFloat

    init(
        incoming: KVTransitionEndpoint,
        outgoing: KVTransitionEndpoint,
        animation: KVTransitionAnimation,
        supportsInteractiveBack: Bool,
        incomingDelayFactor: CGFloat = 0,
        outgoingDelayFactor: CGFloat = 0
    ) {
        self.incoming = incoming
        self.outgoing = outgoing
        self.animation = animation
        self.supportsInteractiveBack = supportsInteractiveBack
        self.incomingDelayFactor = incomingDelayFactor
        self.outgoingDelayFactor = outgoingDelayFactor
    }
}
```

In `descriptor(operation:reduceMotion:)`, resolve and pass the incoming delay before returning the descriptor:

```swift
let incomingDelayFactor: CGFloat
if case .scale = kind {
    incomingDelayFactor = 0.08
} else {
    incomingDelayFactor = 0
}

return KVTransitionDescriptor(
    incoming: KVTransitionEndpoint(state: stage.incoming),
    outgoing: KVTransitionEndpoint(state: stage.outgoing),
    animation: resolvedAnimation,
    supportsInteractiveBack: supportsInteractiveBack,
    incomingDelayFactor: incomingDelayFactor
)
```

Reduce Motion descriptors keep both default delays at zero.

- [ ] **Step 4: Replace the scale push stage**

Change the `.scale` stage to:

```swift
case .scale:
    return KVTransitionStage(
        incoming: .identity.scale(0.94).opacity(0),
        outgoing: .identity.scale(0.84).opacity(0)
    )
```

- [ ] **Step 5: Schedule the two live-view endpoints independently**

Replace the combined `animator.addAnimations` block in `KVTransitionAnimator.swift` with:

```swift
animator.addAnimations({
    incoming.applyIdentity()
}, delayFactor: activeDescriptor.incomingDelayFactor)

animator.addAnimations({
    if self.operation == .pop, let heroGeometry {
        outgoing.applyHero(heroGeometry, fullFrame: fromView.frame)
    } else {
        outgoing.apply(
            activeDescriptor.outgoing.state,
            containerSize: size
        )
    }
}, delayFactor: activeDescriptor.outgoingDelayFactor)
```

Keep the existing completion block unchanged so cancellation continues to restore both live views and reinsert the visible hosting view.

- [ ] **Step 6: Run descriptor tests and verify GREEN**

Run the focused command from Step 2.

Expected: all `KVTransitionDescriptorTests` pass.

- [ ] **Step 7: Record the task checkpoint**

Inspect:

```bash
git diff -- Sources/KVRouterKit/KVTransitionDescriptor.swift Sources/KVRouterKit/KVTransitionAnimator.swift Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift
```

If git metadata is writable, commit with:

```bash
git add Sources/KVRouterKit/KVTransitionDescriptor.swift Sources/KVRouterKit/KVTransitionAnimator.swift Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift
git commit -m "feat: polish scale transition motion"
```

### Task 2: Compile the True 180-Degree Flip

**Files:**
- Modify: `Sources/KVRouterKit/KVTransitionDescriptor.swift:164`
- Test: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift:99`
- Test: `Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift:16`

- [ ] **Step 1: Replace the old flip assertion with failing 180-degree tests**

Replace `testFlipAvoidsEdgeOnOrBackFaceEndpoint` with:

```swift
func testFlipPushUsesTwoMatching180DegreeFaces() {
    let descriptor = KVNavigationTransition.flip3D().descriptor(
        operation: .push,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.rotation3DDegrees, 180, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.rotation3DDegrees, -180, accuracy: 0.001)
    XCTAssertEqual(descriptor.incoming.opacity, 1, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.opacity, 1, accuracy: 0.001)

    let size = CGSize(width: 390, height: 844)
    let incoming = descriptor.incoming.state.resolved(containerSize: size)
    let outgoing = descriptor.outgoing.state.resolved(containerSize: size)
    XCTAssertEqual(incoming.transform.m34, outgoing.transform.m34, accuracy: 0.000_001)
    XCTAssertNotEqual(incoming.transform.m34, 0)
}

func testFlipPopReversesTheCardFaces() {
    let descriptor = KVNavigationTransition.flip3D().descriptor(
        operation: .pop,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.rotation3DDegrees, -180, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.rotation3DDegrees, 180, accuracy: 0.001)
}

func testHorizontalFlipRotatesAroundXAxis() {
    let descriptor = KVNavigationTransition.flip3D(axis: .horizontal).descriptor(
        operation: .push,
        reduceMotion: false
    )
    let resolved = descriptor.incoming.state.resolved(
        containerSize: CGSize(width: 390, height: 844)
    )

    XCTAssertEqual(resolved.transform.m11, 1, accuracy: 0.001)
    XCTAssertEqual(resolved.transform.m22, -1, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run the Task 1 focused test command.

Expected: FAIL because the current endpoints are `70` and `-12` degrees and their perspectives have opposite signs.

- [ ] **Step 3: Replace the flip stage with two live card faces**

Change `.flip3D` to:

```swift
case .flip3D(let axis):
    let vector: (x: CGFloat, y: CGFloat, z: CGFloat) = axis == .vertical
        ? (0, 1, 0)
        : (1, 0, 0)
    return KVTransitionStage(
        incoming: .identity.rotation3D(
            .degrees(180),
            axis: vector,
            perspective: 1
        ),
        outgoing: .identity.rotation3D(
            .degrees(-180),
            axis: vector,
            perspective: 1
        )
    )
```

- [ ] **Step 4: Add a live-view backface restoration test**

Add to `KVTransitionAnimatorTests`:

```swift
func testManagedViewRestoresDoubleSidedAfterFlipState() {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    view.layer.isDoubleSided = true
    let managed = KVManagedTransitionView(view)

    managed.apply(
        .identity.rotation3D(
            .degrees(180),
            axis: (x: 0, y: 1, z: 0),
            perspective: 1
        ),
        containerSize: view.bounds.size
    )

    XCTAssertFalse(view.layer.isDoubleSided)
    managed.restore()
    XCTAssertTrue(view.layer.isDoubleSided)
}
```

- [ ] **Step 5: Run descriptor and animator tests**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests \
  -only-testing:KVRouterKitTests/KVTransitionAnimatorTests
```

Expected: both test classes pass.

- [ ] **Step 6: Record the task checkpoint**

Inspect the focused diff. If git metadata is writable, commit with:

```bash
git add Sources/KVRouterKit/KVTransitionDescriptor.swift Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift
git commit -m "feat: add true 180 degree flip transition"
```

### Task 3: Update Built-In Timing Curves

**Files:**
- Modify: `Sources/KVRouterKit/KVNavigationTransition.swift:285`
- Test: `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`

- [ ] **Step 1: Write failing preset timing tests**

Add:

```swift
func testScaleUsesCollapseAndRevealTiming() {
    let animation = KVNavigationTransition.scale.resolvedAnimation

    XCTAssertEqual(animation.duration, 0.34, accuracy: 0.001)
    XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
}

func testFlipUsesSymmetricCardTurnTiming() {
    let animation = KVNavigationTransition.flip3D().resolvedAnimation

    XCTAssertEqual(animation.duration, 0.50, accuracy: 0.001)
    XCTAssertEqual(animation.debugTiming, .cubic(0.65, 0, 0.35, 1))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KVRouterKitTests/KVNavigationTransitionTests
```

Expected: FAIL because scale is currently a `0.30` ease-out and flip is a `0.34` ease-in-out.

- [ ] **Step 3: Split scale and flip from their old timing groups**

Use:

```swift
case .scale:
    return .timingCurve(0.22, 1, 0.36, 1, duration: 0.34)
case .scaleAndFade, .reveal:
    return .easeOut(duration: 0.3)
case .flip3D:
    return .timingCurve(0.65, 0, 0.35, 1, duration: 0.50)
```

Leave all other preset timing unchanged.

- [ ] **Step 4: Run timing tests and verify GREEN**

Run the focused command from Step 2.

Expected: all `KVNavigationTransitionTests` pass.

- [ ] **Step 5: Record the task checkpoint**

Inspect the focused diff. If git metadata is writable, commit with:

```bash
git add Sources/KVRouterKit/KVNavigationTransition.swift Tests/KVRouterKitTests/KVNavigationTransitionTests.swift
git commit -m "feat: tune scale and flip timing curves"
```

### Task 4: Full Verification and Simulator QA

**Files:**
- Verify: `Sources/KVRouterKit/`
- Verify: `Tests/KVRouterKitTests/`
- Verify: `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`

- [ ] **Step 1: Run the full package test suite**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build the package and example app**

Run:

```bash
xcodebuild build \
  -scheme KVRouterKit \
  -destination 'generic/platform=iOS Simulator'

xcodebuild build \
  -project KVRouterKitExample/KVRouterKitExample.xcodeproj \
  -scheme KVRouterKitExample \
  -destination 'generic/platform=iOS Simulator'
```

Expected: both builds exit successfully.

- [ ] **Step 3: Run simulator visual QA**

In the Transition Gallery, verify `.scale` and `.flip3D()` for:

1. Normal push.
2. Navigation-bar back.
3. `@Environment(\.dismiss)` pop.
4. Completed edge-swipe pop.
5. Cancelled edge-swipe pop at approximately 25%, 50%, and 75% progress.
6. Five repeated push/pop cycles.

Expected: no black frames, no stale view state, no hierarchy inversion, a full 180-degree flip, and a clear collapse-then-reveal scale replacement.

- [ ] **Step 4: Check formatting and legacy behavior**

Run:

```bash
git diff --check
rg -n "snapshotView|drawHierarchy|UIGraphicsImageRenderer" Sources/KVRouterKit
```

Expected: `git diff --check` exits zero, and the source scan finds no snapshot renderer introduced by this change.

- [ ] **Step 5: Review the final diff**

Run:

```bash
git diff -- Sources/KVRouterKit Tests/KVRouterKitTests docs/superpowers
```

Confirm the public API is unchanged and only the selected scale/flip behavior, internal scheduling, tests, and documentation changed.
