# KVRouterKit System Pop Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make swipe cancellation reverse the active custom pop and make navigation-bar back plus SwiftUI `dismiss()` reuse the transition selected for the outgoing route.

**Architecture:** Keep router-owned transitions unchanged, but retain resolved transition metadata for every live destination view controller after navigation completes. When UIKit requests a `.pop` animator without a pending router transaction, resolve a short-lived external animator from the outgoing controller metadata; system and native iOS 18 zoom transitions continue returning `nil`.

**Tech Stack:** Swift 6, SwiftUI `NavigationStack`, UIKit `UINavigationControllerDelegate`, `UIViewPropertyAnimator`, `UIPercentDrivenInteractiveTransition`, XCTest.

---

## File Structure

- Modify `Sources/KVRouterKit/KVTransitionCoordinator.swift`: retain weak controller metadata, synchronize it with router entries, and construct external pop animators.
- Modify `Sources/KVRouterKit/KVNavigationControllerBridge.swift`: pass controller context to animator resolution and synchronize metadata after attachment and `didShow`.
- Modify `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`: cover external pop backend selection and metadata cleanup.
- Modify `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`: cover delegate-driven external pop animator resolution.
- Modify `Tests/KVRouterKitTests/KVInteractivePopGestureTests.swift`: retain regression coverage for finish/cancel and mirrored pop behavior.

### Task 1: Retain Destination Transition Metadata

**Files:**
- Modify: `Tests/KVRouterKitTests/KVTransitionCoordinatorTests.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`

- [ ] **Step 1: Write failing metadata tests**

Add tests that build a navigation controller with root/detail controllers and matching router entries, synchronize the coordinator, and assert external `.pop` resolution:

```swift
func testExternalPopUsesOutgoingControllerCustomTransition() {
    let router = KVAppRouter()
    let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
    coordinator.router = router
    let root = UIViewController()
    let detail = UIViewController()
    let navigationController = UINavigationController(rootViewController: root)
    navigationController.setViewControllers([root, detail], animated: false)

    let entry = KVNavigationEntry(route: .appFeature("detail"))
    router.navigationEntries = [entry]
    coordinator.synchronizeControllerMetadata(in: navigationController)

    XCTAssertTrue(
        coordinator.animator(for: .pop, from: detail, to: root)
            is KVViewControllerTransitionAnimator
    )
}
```

Also cover `.system`, native zoom, an unknown controller, and removal of metadata after the controller leaves `viewControllers`.

- [ ] **Step 2: Run coordinator tests and verify RED**

Run:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C' \
  -only-testing:KVRouterKitTests/KVTransitionCoordinatorTests test
```

Expected: compile failures because controller synchronization and controller-aware animator resolution do not exist.

- [ ] **Step 3: Implement weak controller metadata**

Add an internal record and synchronization entry point:

```swift
private struct KVControllerTransitionMetadata {
    weak var controller: UIViewController?
    let entryID: UUID
    let resolved: KVResolvedTransition
}

private var controllerMetadata: [ObjectIdentifier: KVControllerTransitionMetadata] = [:]

func synchronizeControllerMetadata(in navigationController: UINavigationController) {
    let controllers = Array(navigationController.viewControllers.dropFirst())
    let entries = router?.navigationEntries ?? []
    let liveControllers = Set(navigationController.viewControllers.map(ObjectIdentifier.init))
    controllerMetadata = controllerMetadata.filter {
        $0.value.controller != nil && liveControllers.contains($0.key)
    }
    for (controller, entry) in zip(controllers, entries) {
        controllerMetadata[ObjectIdentifier(controller)] = .init(
            controller: controller,
            entryID: entry.id,
            resolved: resolvedPopTransition(for: entry)
        )
    }
}
```

Resolve zoom through a pop request so entries previously marked native remain native even if the source view is temporarily unavailable.

- [ ] **Step 4: Implement external pop animator resolution**

Extend coordinator resolution without changing pending transaction behavior:

```swift
func animator(
    for operation: UINavigationController.Operation,
    from fromVC: UIViewController,
    to toVC: UIViewController
) -> KVViewControllerTransitionAnimator? {
    if let animator = pendingAnimator(for: operation) {
        return animator
    }
    guard operation == .pop,
          let metadata = controllerMetadata[ObjectIdentifier(fromVC)],
          metadata.resolved.backend == .custom else {
        return nil
    }
    return makeAnimator(
        operation: .pop,
        resolved: metadata.resolved,
        onCompletion: { _ in }
    )
}
```

Extract one animator factory so router-owned, interactive, and external pop paths share descriptor, hero-provider, fallback, and restoration behavior.

- [ ] **Step 5: Run coordinator tests and verify GREEN**

Run the focused command from Step 2. Expected: all coordinator tests pass.

### Task 2: Route UIKit System Pops Through Metadata

**Files:**
- Modify: `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`
- Modify: `Sources/KVRouterKit/KVNavigationControllerBridge.swift`

- [ ] **Step 1: Write failing delegate tests**

Add a test that attaches the coordinator, synchronizes a custom destination, and invokes the delegate without a pending transaction:

```swift
let animator = navigationController.delegate?.navigationController?(
    navigationController,
    animationControllerFor: .pop,
    from: detail,
    to: root
)
XCTAssertTrue(animator is KVViewControllerTransitionAnimator)
XCTAssertNil(coordinator.pendingTransaction)
```

Add companion assertions that `.system` and native zoom return `nil`.

- [ ] **Step 2: Run bridge tests and verify RED**

Run:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C' \
  -only-testing:KVRouterKitTests/KVNavigationControllerBridgeTests test
```

Expected: external pop returns `nil` until the proxy passes `fromVC` and `toVC` to the coordinator.

- [ ] **Step 3: Wire controller-aware delegate resolution**

Update the proxy callback:

```swift
coordinator?.animator(
    for: operation,
    from: fromVC,
    to: toVC
)
```

Call metadata synchronization after attach and after forwarding `didShow`:

```swift
coordinator?.navigationControllerDidShow(navigationController)
```

Synchronization must happen after forwarding to SwiftUI's original delegate so the final controller stack and bound path are stable.

- [ ] **Step 4: Run bridge tests and verify GREEN**

Run the focused command from Step 2. Expected: all bridge tests pass.

### Task 3: Protect Interactive Reverse and Router Sequencing

**Files:**
- Modify: `Tests/KVRouterKitTests/KVInteractivePopGestureTests.swift`
- Modify if required: `Sources/KVRouterKit/KVInteractiveTransitionController.swift`
- Modify if required: `Sources/KVRouterKit/KVTransitionCoordinator.swift`

- [ ] **Step 1: Add regression assertions**

Assert that an interactive transaction takes precedence over external metadata, cancellation preserves the router entry, and finish removes it exactly once. Keep `UIPercentDrivenInteractiveTransition.cancel()` as the only cancellation mechanism so UIKit reverses the interruptible animator from its current fraction.

- [ ] **Step 2: Run interaction tests**

Run:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C' \
  -only-testing:KVRouterKitTests/KVInteractivePopGestureTests test
```

Expected: all tests pass; if metadata resolution steals the interactive transaction, fix ordering so pending transaction matching runs first.

- [ ] **Step 3: Run router sequencing tests**

Run:

```bash
xcodebuild -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C' \
  -only-testing:KVRouterKitTests/KVAppRouterTests test
```

Expected: system-initiated path changes still invoke middleware once and router-owned pops still wait for animator completion.

### Task 4: Simulator and Full Verification

**Files:**
- Modify if needed: `KVRouterKitExample/KVRouterKitExample/TransitionGalleryView.swift`

- [ ] **Step 1: Build and launch the iOS 16 example**

Exercise slide, shared axis, depth, reveal, 3D flip, custom, and fallback hero transitions through navigation-bar back, router pop, interactive finish, and interactive cancel. Verify cancellation returns to the exact destination state and no black frame or hierarchy inversion appears.

- [ ] **Step 2: Exercise SwiftUI dismiss**

Add or use an example destination whose button calls `@Environment(\.dismiss)`. Verify its outgoing route transition is used, its path changes once, and post-pop middleware runs once.

- [ ] **Step 3: Verify iOS 18+ native zoom**

Run on the iOS 26.2 simulator and confirm zoom push, system back, and swipe pop remain native rather than receiving `KVViewControllerTransitionAnimator`.

- [ ] **Step 4: Run full automated verification**

```bash
xcodebuild -scheme KVRouterKit -destination 'platform=iOS Simulator,id=D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C' test
xcodebuild -scheme KVRouterKit -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme KVRouterKitExample \
  -project KVRouterKitExample/KVRouterKitExample.xcodeproj \
  -destination 'generic/platform=iOS Simulator' build
git diff --check
```

Expected: tests and builds exit zero, and `git diff --check` reports no whitespace errors.
