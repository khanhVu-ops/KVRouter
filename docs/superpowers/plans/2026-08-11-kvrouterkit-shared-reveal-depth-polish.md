# KVRouterKit Shared Axis, Reveal, and Depth Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved Shared Axis Flow, Radial Reveal, and Depth Dolly presets without changing KVRouterKit's public transition API.

**Architecture:** Keep preset compilation in `KVTransitionDescriptor`, timing selection in `KVNavigationTransition`, and live-view rendering in `KVManagedTransitionView`. Replace the rectangular reveal mask with a circular `UIView` mask whose transform remains fully driven by the existing interruptible `UIViewPropertyAnimator`.

**Tech Stack:** Swift 6.2, SwiftUI, UIKit, Core Animation layer geometry, `UIViewPropertyAnimator`, XCTest, Xcode Simulator.

---

## File Map

- `Sources/KVRouterKit/KVTransitionDescriptor.swift`: Compile the three approved push/pop endpoint states.
- `Sources/KVRouterKit/KVNavigationTransition.swift`: Define exact default durations and cubic timing curves.
- `Sources/KVRouterKit/KVTransitionAnimator.swift`: Build and restore the circular reveal mask.
- `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`: Verify endpoint geometry, opacity, mirroring, and Reduce Motion.
- `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`: Verify built-in timing curves.
- `Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift`: Verify circular mask geometry and restoration.

### Task 1: Lock Shared Axis and Depth Endpoints

**Files:**
- Modify: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`
- Modify: `Sources/KVRouterKit/KVTransitionDescriptor.swift`

- [ ] **Step 1: Add failing Shared Axis descriptor tests**

Add:

```swift
func testSharedAxisPushUsesCohesiveHorizontalFlow() {
    let descriptor = KVNavigationTransition.sharedAxis().descriptor(
        operation: .push,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.relativeOffset, CGSize(width: 0.14, height: 0))
    XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 0.985, height: 0.985))
    XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.relativeOffset, CGSize(width: -0.07, height: 0))
    XCTAssertEqual(descriptor.outgoing.scale, CGSize(width: 0.985, height: 0.985))
    XCTAssertEqual(descriptor.outgoing.opacity, 0.58, accuracy: 0.001)
}

func testSharedAxisVerticalUsesYAxisAndPopMirrorsEndpoints() {
    let descriptor = KVNavigationTransition.sharedAxis(axis: .vertical).descriptor(
        operation: .pop,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.relativeOffset, CGSize(width: 0, height: -0.07))
    XCTAssertEqual(descriptor.incoming.opacity, 0.58, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.relativeOffset, CGSize(width: 0, height: 0.14))
    XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
}
```

- [ ] **Step 2: Add failing Depth descriptor tests**

Add:

```swift
func testDepthPushUsesForegroundToBackgroundDolly() {
    let descriptor = KVNavigationTransition.depth.descriptor(
        operation: .push,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 1.09, height: 1.09))
    XCTAssertEqual(descriptor.incoming.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.scale, CGSize(width: 0.90, height: 0.90))
    XCTAssertEqual(descriptor.outgoing.opacity, 0.42, accuracy: 0.001)
}

func testDepthPopMirrorsDollyEndpoints() {
    let descriptor = KVNavigationTransition.depth.descriptor(
        operation: .pop,
        reduceMotion: false
    )

    XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 0.90, height: 0.90))
    XCTAssertEqual(descriptor.incoming.opacity, 0.42, accuracy: 0.001)
    XCTAssertEqual(descriptor.outgoing.scale, CGSize(width: 1.09, height: 1.09))
    XCTAssertEqual(descriptor.outgoing.opacity, 0, accuracy: 0.001)
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests
```

Expected: Shared Axis fails on the current `0.12/-0.05`, `0.15/0.82` values, and Depth fails on the current `1.04/0.96`, `0.4/0.9` values.

- [ ] **Step 4: Implement the Shared Axis Flow stage**

Replace the `.sharedAxis` stage with:

```swift
case .sharedAxis(let axis):
    let vector = axis == .horizontal
        ? CGSize(width: 1, height: 0)
        : CGSize(width: 0, height: 1)
    return KVTransitionStage(
        incoming: .identity
            .relativeOffset(
                x: 0.14 * vector.width,
                y: 0.14 * vector.height
            )
            .scale(0.985)
            .opacity(0),
        outgoing: .identity
            .relativeOffset(
                x: -0.07 * vector.width,
                y: -0.07 * vector.height
            )
            .scale(0.985)
            .opacity(0.58)
    )
```

- [ ] **Step 5: Implement the Depth Dolly stage**

Replace `.depth` with:

```swift
case .depth:
    return KVTransitionStage(
        incoming: .identity.scale(1.09).opacity(0),
        outgoing: .identity.scale(0.90).opacity(0.42)
    )
```

- [ ] **Step 6: Run descriptor tests and verify GREEN**

Run the focused command from Step 3.

Expected: all descriptor tests pass.

### Task 2: Implement Radial Reveal Geometry

**Files:**
- Modify: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionAnimatorTests.swift`
- Modify: `Sources/KVRouterKit/KVTransitionDescriptor.swift`
- Modify: `Sources/KVRouterKit/KVTransitionAnimator.swift`

- [ ] **Step 1: Expand the reveal descriptor test before production changes**

Replace the existing reveal test with:

```swift
func testRevealUsesRadialIncomingAndRecessedOutgoingStates() {
    let descriptor = KVNavigationTransition.reveal(
        origin: .topTrailing
    ).descriptor(operation: .push, reduceMotion: false)

    XCTAssertEqual(descriptor.incoming.revealOrigin, .topTrailing)
    XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 1.025, height: 1.025))
    XCTAssertEqual(descriptor.incoming.opacity, 0.2, accuracy: 0.001)
    XCTAssertNil(descriptor.outgoing.revealOrigin)
    XCTAssertEqual(descriptor.outgoing.scale, CGSize(width: 0.975, height: 0.975))
    XCTAssertEqual(descriptor.outgoing.opacity, 0.78, accuracy: 0.001)
}

func testRevealPopContractsOutgoingMaskToOrigin() {
    let descriptor = KVNavigationTransition.reveal(
        origin: .bottomLeading
    ).descriptor(operation: .pop, reduceMotion: false)

    XCTAssertNil(descriptor.incoming.revealOrigin)
    XCTAssertEqual(descriptor.incoming.scale, CGSize(width: 0.975, height: 0.975))
    XCTAssertEqual(descriptor.outgoing.revealOrigin, .bottomLeading)
    XCTAssertEqual(descriptor.outgoing.scale, CGSize(width: 1.025, height: 1.025))
}
```

- [ ] **Step 2: Add a failing circular mask geometry test**

Add to `KVTransitionAnimatorTests`:

```swift
func testRevealMaskIsCircleCenteredAtOriginAndCoversFarthestCorner() throws {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    let managed = KVManagedTransitionView(view)

    managed.prepareReveal(
        for: .identity.reveal(from: .topTrailing),
        containerSize: view.bounds.size
    )

    let mask = try XCTUnwrap(view.mask)
    let radius = hypot(view.bounds.width, view.bounds.height)
    XCTAssertEqual(mask.center.x, view.bounds.maxX, accuracy: 0.001)
    XCTAssertEqual(mask.center.y, view.bounds.minY, accuracy: 0.001)
    XCTAssertEqual(mask.bounds.width, radius * 2, accuracy: 0.001)
    XCTAssertEqual(mask.bounds.height, radius * 2, accuracy: 0.001)
    XCTAssertEqual(mask.layer.cornerRadius, radius, accuracy: 0.001)
    XCTAssertTrue(mask.layer.masksToBounds)
}
```

- [ ] **Step 3: Run reveal tests and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests/testRevealUsesRadialIncomingAndRecessedOutgoingStates \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests/testRevealPopContractsOutgoingMaskToOrigin \
  -only-testing:KVRouterKitTests/KVTransitionAnimatorTests/testRevealMaskIsCircleCenteredAtOriginAndCoversFarthestCorner
```

Expected: descriptor values fail and the current rectangular mask bounds do not match the required diameter.

- [ ] **Step 4: Implement the Radial Reveal stage**

Replace `.reveal` with:

```swift
case .reveal(let origin):
    return KVTransitionStage(
        incoming: .identity
            .scale(1.025)
            .opacity(0.2)
            .reveal(from: origin),
        outgoing: .identity
            .scale(0.975)
            .opacity(0.78)
    )
```

- [ ] **Step 5: Replace the rectangular mask with circular geometry**

Replace `makeMask(origin:)` with:

```swift
private func makeMask(origin: UnitPoint) -> UIView {
    let center = CGPoint(
        x: view.bounds.width * origin.x,
        y: view.bounds.height * origin.y
    )
    let farthestX = max(center.x, view.bounds.width - center.x)
    let farthestY = max(center.y, view.bounds.height - center.y)
    let radius = hypot(farthestX, farthestY)
    let diameter = max(radius * 2, 1)
    let mask = UIView(frame: CGRect(
        x: 0,
        y: 0,
        width: diameter,
        height: diameter
    ))
    mask.center = center
    mask.backgroundColor = .black
    mask.isUserInteractionEnabled = false
    mask.layer.cornerRadius = diameter / 2
    mask.layer.masksToBounds = true
    view.mask = mask
    transitionMask = mask
    return mask
}
```

Keep `prepareReveal`, `apply`, `applyIdentity`, and `restore` unchanged so the circular mask continues to use the existing interruptible transform timeline.

- [ ] **Step 6: Run reveal tests and verify GREEN**

Run the focused command from Step 3.

Expected: all three reveal tests pass.

### Task 3: Update Timing Curves and Reduce Motion Coverage

**Files:**
- Modify: `Tests/KVRouterKitTests/KVNavigationTransitionTests.swift`
- Modify: `Tests/KVRouterKitTests/KVTransitionDescriptorTests.swift`
- Modify: `Sources/KVRouterKit/KVNavigationTransition.swift`

- [ ] **Step 1: Add failing timing tests**

Add:

```swift
func testSharedAxisUsesFlowTiming() {
    let animation = KVNavigationTransition.sharedAxis().resolvedAnimation
    XCTAssertEqual(animation.duration, 0.36, accuracy: 0.001)
    XCTAssertEqual(animation.debugTiming, .cubic(0.22, 1, 0.36, 1))
}

func testRevealUsesRadialTiming() {
    let animation = KVNavigationTransition.reveal().resolvedAnimation
    XCTAssertEqual(animation.duration, 0.42, accuracy: 0.001)
    XCTAssertEqual(animation.debugTiming, .cubic(0.16, 1, 0.30, 1))
}

func testDepthUsesDollyTiming() {
    let animation = KVNavigationTransition.depth.resolvedAnimation
    XCTAssertEqual(animation.duration, 0.40, accuracy: 0.001)
    XCTAssertEqual(animation.debugTiming, .cubic(0.20, 0.80, 0.20, 1))
}
```

- [ ] **Step 2: Add Reduce Motion regression coverage**

Add:

```swift
func testPolishedPresetsReduceToFadeOnly() {
    let transitions: [KVNavigationTransition] = [
        .sharedAxis(),
        .reveal(),
        .depth,
    ]

    for transition in transitions {
        let descriptor = transition.descriptor(operation: .push, reduceMotion: true)
        XCTAssertEqual(descriptor.incoming.opacity, 0)
        XCTAssertTrue(descriptor.incoming.transforms.isEmpty)
        XCTAssertNil(descriptor.incoming.revealOrigin)
        XCTAssertTrue(descriptor.outgoing.isIdentity)
    }
}
```

- [ ] **Step 3: Run timing tests and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVNavigationTransitionTests \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests/testPolishedPresetsReduceToFadeOnly
```

Expected: the three timing tests fail while the Reduce Motion regression test already passes against the common fallback path.

- [ ] **Step 4: Split the built-in timing groups**

Use these cases in `resolvedAnimation`:

```swift
case .slide:
    return .timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
case .sharedAxis:
    return .timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
case .scaleAndFade:
    return .easeOut(duration: 0.3)
case .reveal:
    return .timingCurve(0.16, 1, 0.30, 1, duration: 0.42)
case .depth:
    return .timingCurve(0.20, 0.80, 0.20, 1, duration: 0.40)
case .zoom:
    return .spring(response: 0.38, dampingFraction: 0.94)
```

Leave system, fade, scale, flip, and custom timing unchanged.

- [ ] **Step 5: Run timing and Reduce Motion tests**

Run the focused command from Step 3.

Expected: all selected tests pass.

### Task 4: Full Verification and Simulator QA

**Files:**
- Verify: `Sources/KVRouterKit/`
- Verify: `Tests/KVRouterKitTests/`
- Verify: `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`

- [ ] **Step 1: Run all transition-focused tests on iOS 26.2**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVTransitionDescriptorTests \
  -only-testing:KVRouterKitTests/KVNavigationTransitionTests \
  -only-testing:KVRouterKitTests/KVTransitionAnimatorTests
```

Expected: all selected tests pass.

- [ ] **Step 2: Run focused compatibility tests on iOS 16**

Run the same selected classes using destination:

```text
platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C,arch=arm64
```

Expected: all selected transition tests pass.

- [ ] **Step 3: Run the full current-runtime suite and both builds**

Run:

```bash
xcodebuild test -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' -quiet

xcodebuild build -scheme KVRouterKit \
  -destination 'generic/platform=iOS Simulator' -quiet

xcodebuild build \
  -project KVRouterKitExample/KVRouterKitExample.xcodeproj \
  -scheme KVRouterKitExample \
  -destination 'generic/platform=iOS Simulator' -quiet
```

Expected: all three commands exit zero.

- [ ] **Step 4: Run Simulator visual QA**

For Shared Axis, Reveal, and Depth, verify normal push, router pop, navigation back, system dismiss, short cancelled edge swipe, and repeated push/pop. Confirm the circular reveal has no rectangular edge and no black frame at its origin or farthest corner.

- [ ] **Step 5: Run final source checks**

Run:

```bash
git diff --check
rg -n "snapshotView|drawHierarchy|UIGraphicsImageRenderer|CIFilter" Sources/KVRouterKit
```

Expected: formatting check exits zero and no snapshot or filter renderer is introduced.
