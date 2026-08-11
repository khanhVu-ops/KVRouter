# KVRouterKit Scoped Navigation Animation Forcing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore single push and pop animations on iOS 18 and later for custom transitions, `.system`, and native zoom while keeping each backend's animator ownership unchanged.

**Architecture:** Install one process-wide Objective-C method-exchange shim for UIKit navigation mutation methods. Scope every behavior change through a weak associated policy installed only by `KVNavigationControllerBridge`. `KVTransitionCoordinator` forces animation for matching custom transactions, one-shot router intents for `.system` and native zoom, and metadata-backed managed pops. Only custom backends return a custom animator.

**Tech Stack:** Swift 6, SwiftUI `NavigationStack`, UIKit, Objective-C runtime, XCTest, Xcode Simulator.

---

## File Structure

- Create `Sources/KVRouterKit/KVNavigationAnimationForcing.swift`: one-time runtime installation, associated policy storage, stack mutation classification, and exchanged UIKit methods.
- Modify `Sources/KVRouterKit/KVNavigationControllerBridge.swift`: install and attach the scoped policy, clear it on detach, and forward force-animation decisions to the coordinator.
- Modify `Sources/KVRouterKit/KVTransitionCoordinator.swift`: decide whether a classified UIKit operation belongs to a custom pending transaction, a router-driven system/native intent, or a metadata-backed managed pop.
- Modify `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`: regression and isolation coverage using real `UINavigationController` mutations requested with `animated: false`.

### Task 1: Reproduce the iOS 18+ Animated-Flag Failure

**Files:**
- Modify: `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`

- [ ] **Step 1: Add a failing custom-push regression test**

Create a visible navigation controller, attach the coordinator, perform a custom push whose UIKit mutation explicitly requests `animated: false`, and assert that the forwarded delegate receives `animated: true` and that the pending transaction owns a `KVViewControllerTransitionAnimator`.

```swift
func testAttachedCustomPushForcesUIKitAnimationWhenRequestedFalse() async {
    let coordinator = KVTransitionCoordinator(defaultTransition: .system)
    let root = UIViewController()
    let detail = UIViewController()
    let navigationController = UINavigationController(rootViewController: root)
    let original = RecordingNavigationDelegate()
    navigationController.delegate = original
    let window = makeVisibleWindow(rootViewController: navigationController)
    coordinator.attach(to: navigationController)
    original.reset()

    let task = Task { @MainActor in
        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: KVNavigationEntry(route: .appFeature("detail")),
                transitionOverride: .depth
            )
        ) {
            navigationController.setViewControllers(
                [root, detail],
                animated: false
            )
        }
    }

    await waitUntil { original.lastWillShowAnimated != nil }
    XCTAssertEqual(original.lastWillShowAnimated, true)
    XCTAssertTrue(
        coordinator.pendingTransaction?.animator
            is KVViewControllerTransitionAnimator
    )

    coordinator.completePendingTransition(cancelled: false)
    await task.value
    _ = window
}
```

Add focused helpers that retain a `UIWindow`, record `willShow(animated:)`, and reset initial-root callbacks.

- [ ] **Step 2: Run the regression test and verify RED**

Run:

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVNavigationControllerBridgeTests/testAttachedCustomPushForcesUIKitAnimationWhenRequestedFalse
```

Expected: FAIL because the delegate receives `animated: false` and the custom animator is not requested.

### Task 2: Add the Scoped Runtime Compatibility Layer

**Files:**
- Create: `Sources/KVRouterKit/KVNavigationAnimationForcing.swift`

- [ ] **Step 1: Define the internal policy contract and stack classifier**

```swift
@MainActor
protocol KVNavigationAnimationPolicy: AnyObject {
    func shouldForceAnimation(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to toViewController: UIViewController?
    ) -> Bool
}
```

Classify `setViewControllers` as a push only for one appended controller with an identity-equal prefix, and as a pop only for one removed top controller with an identity-equal prefix. Return no operation for initial root setup, replacement, reordering, and bulk changes.

- [ ] **Step 2: Add weak associated policy storage**

Use `objc_getAssociatedObject` and `objc_setAssociatedObject` with a retained box containing a weak policy reference. Provide internal install and clear functions on `UINavigationController`.

- [ ] **Step 3: Exchange UIKit mutation methods once**

Use `class_getInstanceMethod` and `method_exchangeImplementations` for:

```swift
#selector(UINavigationController.setViewControllers(_:animated:))
#selector(UINavigationController.pushViewController(_:animated:))
#selector(UINavigationController.popViewController(animated:))
#selector(UINavigationController.popToViewController(_:animated:))
#selector(UINavigationController.popToRootViewController(animated:))
```

Each exchanged method computes:

```swift
let effectiveAnimated = animated || kvShouldForceAnimation(
    operation: operation,
    from: fromViewController,
    to: toViewController
)
```

Then call the exchanged selector exactly once so it reaches the original UIKit implementation.

- [ ] **Step 4: Compile the package**

Run:

```bash
xcodebuild build \
  -scheme KVRouterKit \
  -destination 'generic/platform=iOS Simulator'
```

Expected: BUILD SUCCEEDED with Swift 6 actor isolation and Objective-C selectors accepted.

### Task 3: Scope the Policy Through the Existing Bridge

**Files:**
- Modify: `Sources/KVRouterKit/KVNavigationControllerBridge.swift`
- Modify: `Sources/KVRouterKit/KVTransitionCoordinator.swift`

- [ ] **Step 1: Make the bridge the navigation animation policy**

Conform `KVNavigationControllerBridge` to `KVNavigationAnimationPolicy`. At the beginning of `attach`, install the runtime shim and associate `self` with the current navigation controller. In `detach`, clear the association only when the installed policy is still this bridge.

- [ ] **Step 2: Forward policy decisions to the coordinator**

```swift
func shouldForceAnimation(
    for operation: UINavigationController.Operation,
    from fromViewController: UIViewController?,
    to toViewController: UIViewController?
) -> Bool {
    coordinator.shouldForceNavigationAnimation(
        for: operation,
        from: fromViewController,
        to: toViewController
    )
}
```

- [ ] **Step 3: Resolve only matching managed operations**

Add `KVTransitionCoordinator.shouldForceNavigationAnimation`:

```swift
func shouldForceNavigationAnimation(
    for operation: UINavigationController.Operation,
    from fromViewController: UIViewController?,
    to _: UIViewController?
) -> Bool {
    if let intent = navigationAnimationIntent,
       operation.matches(intent.request.operation) {
        navigationAnimationIntent = nil
        return true
    }

    if let transaction = pendingTransaction {
        return transaction.resolved.backend == .custom
            && operation.matches(transaction.request.operation)
    }

    guard operation == .pop,
          let fromViewController,
          let metadata = controllerMetadata[ObjectIdentifier(fromViewController)],
          metadata.controller === fromViewController else {
        return false
    }
    return true
}
```

Router-driven `.system` and native zoom prepare a one-shot intent before the
path mutation. Consuming that intent changes only UIKit's animated flag; the
delegate still returns no custom animator. Initial setup, bulk mutations,
unattached controllers, and direct external pushes remain unchanged.

- [ ] **Step 4: Run the custom-push regression test and verify GREEN**

Run the Task 1 command again.

Expected: PASS; the original delegate receives `animated: true` and the coordinator has a custom animator.

### Task 4: Cover Pop, Native/System Animation, Isolation, and Detachment

**Files:**
- Modify: `Tests/KVRouterKitTests/KVNavigationControllerBridgeTests.swift`

- [ ] **Step 1: Add router-driven custom-pop coverage**

Build a two-controller stack, attach a coordinator with custom metadata, create a matching pending pop transaction, mutate to one controller with `animated: false`, and assert `animated: true` plus a reverse custom animator.

- [ ] **Step 2: Add system-initiated custom-pop coverage**

Synchronize custom metadata, perform `setViewControllers([root], animated: false)` without a pending transaction, and assert the metadata fallback forces animation and returns a custom pop animator.

- [ ] **Step 3: Add isolation tests**

Verify unrelated operations remain `animated: false`:

```swift
// Unattached controller.
navigationController.setViewControllers([root, detail], animated: false)

// Attached controller with no matching router request.
navigationController.setViewControllers([root, detail], animated: false)

// Attached controller after coordinator.detach().
coordinator.detach()
navigationController.setViewControllers([root, detail], animated: false)
```

Add router-driven `.system` push/pop coverage and assert UIKit reports an
animated transition without a custom animator. On iOS 18 or later, add the
equivalent native-zoom coverage. Add a detach test proving an unconsumed intent
cannot leak into a later external navigation mutation.

- [ ] **Step 4: Verify RED then GREEN for each new behavior**

Run each new test before adding its corresponding production branch when possible, confirm the expected failure, implement only that branch, and rerun until it passes.

- [ ] **Step 5: Run the bridge and coordinator test groups**

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3' \
  -only-testing:KVRouterKitTests/KVNavigationControllerBridgeTests \
  -only-testing:KVRouterKitTests/KVTransitionCoordinatorTests
```

Expected: all selected tests pass with no failures.

### Task 5: Live OS Matrix Verification

**Files:**
- No production changes expected.

- [ ] **Step 1: Run the full package suite on iOS 26.2**

```bash
xcodebuild test \
  -scheme KVRouterKit \
  -destination 'platform=iOS Simulator,id=272044F2-4A8C-4A04-891C-23F564BD9FC3'
```

Expected: full suite passes.

- [ ] **Step 2: Run transition regression tests on iOS 18.4 and iOS 16.0**

Run the bridge regression group with destinations:

```text
9EADA50C-DB1D-424C-A05C-DC53991C422D
D90D9E6E-145A-4DC1-BBD2-7BC3B3C4517C
```

Expected: custom and `.system` false-requested pushes and pops animate on both
runtimes; iOS 16 does not double animate. Native zoom tests run only on iOS 18+
and confirm the native transition receives `animated: true`.

- [ ] **Step 3: Build and run the Example on each runtime**

Use `KVRouterKitExample/KVRouterKitExample.xcodeproj`, scheme `KVRouterKitExample`, and manually exercise Shared Axis, Depth, Reveal, Scale, 3D Flip, router pop, system dismiss, and edge swipe.

Expected: custom styles animate on all three runtimes; native hero zoom remains native on iOS 18.4 and iOS 26.2.

- [ ] **Step 4: Run final build and whitespace verification**

```bash
xcodebuild build \
  -scheme KVRouterKit \
  -destination 'generic/platform=iOS Simulator'
git diff --check
```

Expected: BUILD SUCCEEDED and `git diff --check` produces no output.
