# Changelog

All notable changes to KVRouterKit are documented in this file.

## 3.8.0 - 2026-10-02

### Added

- `KVNavigationTransition.interactiveDismissDisabled(_:)`: a screen pushed with this
  transition cannot be dragged back — only a `pop()` from code closes it. Built for zooms
  into screens with horizontally scrolling content, where a stray swipe dismissed the screen
  and lost what the user was typing. A native zoom (iOS 18+) has its three dismissal gestures
  switched off (leading-edge pan, swipe down, pinch — SwiftUI's `.navigationTransition(.zoom)`
  offers no way to); a transition on the router's own animator (anchored zoom, custom) loses
  its back swipe, and UIKit's edge pan with it, which would otherwise pick up the swipe and pop
  the screen anyway. Other screens are untouched: a `.system` push keeps its back swipe.
  Measured on iOS 26.2.

## 3.7.2 - 2026-10-02

### Fixed

- Anchored zoom (`zoom(sourceID:destinationID:)`) ended every pop, and began every
  push, with a jump: it only scales, so the destination view landed on the source and
  the real source replaced it in one frame. That is seamless only when the two look
  alike at that size, and an input bar opening a composer never does — the buttons
  moved and the border popped in a quarter-second after the movement had stopped. A
  picture of the source now travels with the clip and cross-fades with it (out early
  on a push, in on a pop), riding the same animator so a back swipe scrubs it.
- An anchored pop measured the destination view once and then clipped the live
  screen, which kept laying out: a keyboard going down mid-pop (a close button with
  the keyboard up, or a back swipe) slid the destination view out of the clip, and
  what landed on the source was whatever had moved into its place. The pop now
  animates a still copy of the outgoing screen.
- The anchored clip is installed before the animation block, so a scrubbed back swipe
  starts from it instead of interpolating an uncommitted mask.

Measured on iOS 26.2.

## 3.7.1 - 2026-10-02

### Fixed

- Popping a `pushView { }` screen on the router's own animator — an anchored zoom
  (`zoom(sourceID:destinationID:)`), and every custom transition — dropped the screen's
  builder as soon as the path changed, which is before the pop animation runs. The
  outgoing screen re-rendered mid-transition as an empty view: a black first frame, and an
  anchored zoom lost its destination view and fell back to `.scaleAndFade`, so the image
  never flew back to its thumbnail. The builder now lives until the navigation controller
  reports the transition finished, like the native-zoom metadata does. Measured on iOS 26.2.

## 3.7.0 - 2026-10-01

### Added

- `KVNavigationTransition.zoom(sourceID:destinationID:)` and
  `View.kvTransitionDestination(id:cornerRadius:)`: an anchored zoom. The incoming
  screen starts clipped to one of its own views, laid over the source, and opens to
  the full screen while that view travels to its place; the pop lands it back on
  the source. Built for a source that is the screen's own control in miniature — a
  home input bar opening a chat whose composer sits at the bottom — where
  `.zoom(sourceID:)` squeezed the top of the chat into the bar and the composer then
  landed somewhere else. The source is hidden while it runs. Always on the router's
  own animator (SwiftUI's zoom cannot align to a destination view), so the back
  swipe is interactive on every iOS version. Missing source or destination →
  `.scaleAndFade`, as with `zoom`.

### Fixed

- `router.pop()` of a screen pushed with native zoom (iOS 18+) cut straight to the
  screen below instead of zooming back into the source. The pop only edited the
  path, which reaches UIKit as `animated: false`, and SwiftUI plays the zoom back
  only for its own dismissal. It looked fine whenever the two screens disagreed on
  the navigation bar — SwiftUI animated the bar and the zoom rode along — so an app
  hiding the bar on both screens saw every router pop cut. Measured on iOS 26.2.

  The router now pops such a screen through the destination's own `DismissAction`,
  the same pop a swipe or back button runs, and holds the queue until the path has
  changed (editing the path itself if SwiftUI ignored the dismiss). Forcing UIKit's
  `animated` flag instead was tried and rejected: it ran a second transition next to
  SwiftUI's and left the screen below shifted half a screen sideways.

## 3.6.2 - 2026-09-30

### Fixed

- A push without a call-site transition ignored the route type's default declared
  with `routes.registerTransition(_:_:)` and animated with the host's
  `defaultTransition` instead — while the pop of the same screen did use the route
  default, so the two directions animated differently. Measured in an app whose
  ViewModels push typed routes through `KVRouting`: a route-level `.reveal` and a
  route-level `.zoom(sourceID:)` both pushed as `.system`.

  `push(_:)` and `pushView(_:)` handed the driver the call-site value alone. They
  now read the same funnel the pop side reads, `transitionOverride(for:)`: call
  site first, then the route type's default, then (via `nil`) the host. A
  `pushView` that middleware redirects to a typed route picks up that route's
  default too. Call-site transitions still win, and a route type that declared
  nothing still falls through to the host.

  The existing test only checked the value stored with the entry, which was
  already right; the new ones check the request the driver receives at push time.

## 3.6.1 - 2026-09-30

### Fixed

- The back swipe on `.system` did nothing when the navigation bar was hidden —
  the usual setup for a SwiftUI app that draws its own header with
  `.toolbar(.hidden, for: .navigationBar)`. Measured on iOS 26.2: the same swipe
  popped with the bar shown and did nothing with it hidden. Screens on a custom
  transition were never affected, since the router drives those itself.

  UIKit's own delegate on the system recognizer refuses the swipe while the bar
  is hidden, and it does so through an underscored delegate question asked before
  any public one, so neither `gestureRecognizer(_:shouldReceive:)` nor
  `gestureRecognizerShouldBegin` ever ran. The router now wraps that delegate.
  The wrapper declines underscored selectors (it neither implements nor names
  one), so UIKit falls back to the public questions, and answers them by allowing
  a pop only when it is sound on its own: more than one screen, no transition
  running, nothing presented on top. Every other public delegate question still
  goes to UIKit's delegate. Detaching hands UIKit its own delegate back.

- On iOS 26, `interactiveContentPopGestureRecognizer` (pop from anywhere in the
  content) is now wrapped the same way and follows the same availability as the
  edge recognizer. It is switched off for custom transitions and when the host
  opts out with `interactivePopEnabled: false`. Left alone, it could start a UIKit
  pop over a screen the router was driving.

## 3.6.0 - 2026-09-30

### Changed

- Requires swiftui-introspect **27.x** (was 26.x). 27.0.0 needs Swift tools 6.2,
  which this package already declares, and adds range-based platform predicates.
  An app that pins swiftui-introspect 26 directly has to move to 27 alongside this
  release, which is why it is a minor rather than a patch.

### Fixed

- `KVRouterHost` attached to its `UINavigationController` only on the iOS versions
  it listed by name (`.v16, .v17, .v18, .v26`). On any OS outside that list, iOS 27
  included, the introspection closure never ran, so the router never attached — and
  custom transitions, zoom and the host's back-swipe settings all go through that
  attachment. The host now matches `.iOS(.v16...)`. NavigationStack uses the same
  navigation-controller selector on every release since iOS 16, so a range covers
  future versions without a package update.

## 3.5.3 - 2026-09-13

### Fixed

- A transition source could leave its old logical ID registered after the caller
  moved that ID to another source. The stale entry still resolved — to a view
  that had started answering to a different ID — so a zoom grew from the wrong
  item. A source now holds exactly one logical ID at a time and releases the
  previous one as it registers, without disturbing an entry another source has
  already claimed. Tightens the ownership rule added in 3.5.2.

## 3.5.2 - 2026-09-12

### Fixed

- A zoom could silently become a fade after two sources traded logical IDs.
  `kvTransitionSource(id:)` removed its registry entry by ID alone when its
  subtree went away, and a logical ID is the caller's, not a view's — callers
  legitimately move one from view to view, which is how a paged viewer hands its
  zoom identity to whichever thumbnail is now on screen. SwiftUI installs the new
  subtrees first and runs the old ones' `onDisappear` afterwards, so the teardown
  deleted the entry its successor had just written. With no source registered,
  `resolve` treats the ID as off screen and substitutes `.scaleAndFade` — no
  error, no log, just a zoom that stopped being a zoom. Each source now claims
  its entry and can only clear what it still owns. A source that has not been
  laid out yet is held to the same rule, so its zero-sized measurement can no
  longer wipe another source's geometry.

## 3.5.1 - 2026-08-25

### Fixed

- A native iOS 18+ zoom dismissal can leave `matchedTransitionSource` carrying
  SwiftUI's private hidden state after the animation is over. The source keeps
  its layout slot and remains tappable, but renders nothing. KVRouterKit now
  gives each native zoom a package-owned identity and rotates that identity only
  after UIKit reports the pop complete. The destination therefore keeps its
  original match for the whole dismissal, while stale hidden state cannot attach
  to the returned source or the next zoom from that item.

## 3.5.0 - 2026-08-14

### Added

- `KVRouterHost(interactivePopEdgeWidth:)` sets how far in from the leading edge a
  back swipe may start on screens using a **custom** transition — the ones the
  router's own recognizer drives. Defaults to 44 points, one standard touch target,
  and is read on every change so it can be bound to state. Widen it if the swipe is
  hard to catch, narrow it if it argues with content near the edge such as a
  horizontally scrolling row or a slider. `.system` and native zoom screens are
  swiped with UIKit's own recognizer, whose region UIKit owns, so it does not apply
  to them.

### Fixed

- The back swipe on custom-transition screens is much easier to catch. It used to
  demand a drag starting within a few points of the bezel **and** a fast one, which
  is why it felt so much worse than the system swipe. Two separate causes:

  The recognizer was a `UIScreenEdgePanGestureRecognizer`, whose hit region belongs
  to UIKit and cannot be widened by any API. It is now a plain
  `UIPanGestureRecognizer` with the region enforced in
  `gestureRecognizerShouldBegin`, which is what made the width above settable at
  all.

  And that check read the pan's **velocity** to decide direction. A slow,
  deliberate drag carries almost none by the time UIKit asks, so it was rejected
  outright — the swipe worked only if you flicked. Direction now comes from
  translation, with velocity as a tie-break only when translation is still zero.

  One trade-off worth knowing: a plain pan does not get the touch-delaying UIKit
  grants a screen-edge recognizer, so content sitting right against the leading
  edge can now compete with the swipe. That is what the width parameter is for.

- The leading-edge back swipe works on `.system`, the default transition — so on
  any app that never picked a custom one. 3.3.0 claimed this fix and did not
  deliver it; the entry below is wrong, and the swipe was still dead in 3.3.0 and
  3.4.0. The recognizer was enabled and idle the whole time, which is why
  enabling it harder never helped.

  UIKit suppresses `interactivePopGestureRecognizer` when the navigation
  controller's delegate merely **responds to**
  `navigationController(_:animationControllerFor:from:to:)` — whatever that method
  returns. `KVNavigationControllerDelegateProxy` answered `responds(to:)` `true`
  unconditionally, so on `.system`, where the router contributes nothing and
  UIKit's own transition should run, UIKit believed someone else owned the
  transition and declined to start the gesture. Returning `nil` from the method is
  not a fix: UIKit never gets that far, and `interactionControllerFor` is never
  called at all.

  The proxy now claims those two selectors only when the router really has an
  animator for the navigation about to happen, decided per screen from the top
  view controller's recorded transition — so a stack mixing custom and `.system`
  screens gets the right answer on each. `UINavigationController` snapshots those
  answers when the delegate is assigned, so the bridge re-assigns it when the
  answer changes, and never while a gesture is mid-flight, which tears down the
  in-flight interactive transition.

  Verified by hand on iOS 26.2: `.system` screens pop by swipe, and custom
  transition screens still pop with their own animation. Worth knowing for
  anything in this area — the package's own `UIScreenEdgePanGestureRecognizer`,
  which drives the pop on custom screens, cannot be driven by synthetic touch
  injection at all, so automation cannot tell a real regression there from its own
  blind spot. Only a finger can.

## 3.4.0 - 2026-08-14

### Added

- `routes.register(_:transition:destination:)` and
  `routes.registerTransition(_:_:)` declare the transition a route type animates
  with, so motion that belongs to a screen is stated once where the screen is
  wired up rather than repeated at every `push`. Resolution runs most-specific
  first: a `transition:` on the call site, then the route type's, then the host's
  `defaultTransition`. The per-value form returns an optional, so one case of a
  route enum can zoom while its siblings keep the host default.

  It resolves through `transitionOverride(for:)`, the one place every push, pop
  and pop-to path already asks that question, which is why it also covers
  back-swipes and entries that never went through `push` — a restored path or a
  deep link picks up route defaults too.

- `KVNavigationTransition` is `Sendable` and no longer `@MainActor`. It can now
  be stored in a `Sendable` type — which is what a route-level default is — and
  `.fade` and friends are reachable off the main actor without an `await`. None
  of what it holds was ever UIKit state; turning one into an actual animation
  still happens on the main actor.

### Changed

- **Breaking, narrowly:** `KVNavigationTransition.zoom(sourceID:)` now requires
  `Hashable & Sendable` rather than `Hashable`. `AnyHashable` is not `Sendable`,
  so storing one is what kept the transition off `Sendable`; the id is held in a
  constrained existential instead and erased only where it reaches the source
  registry or SwiftUI. `String`, `Int`, `UUID` and plain enums already qualify.
  `kvTransitionSource(id:)` is unchanged.

### Documentation

- `.kvRoutes` documents that its closure runs **exactly once** per view
  identity, and that a destination capturing surrounding state therefore freezes
  it at the first render — a failure with no warning and no crash. Both the
  symbol doc and the README now show the fix: pass identity, and let the
  destination read the live value.

## 3.3.0 - 2026-08-13

### Fixed

- **This did not actually fix the back swipe** — see 3.5.0 above. The latched
  `isEnabled` described here was a real bug and is really fixed, but it was not
  what kept the gesture from starting, so the swipe stayed dead on `.system`
  through 3.3.0 and 3.4.0. Left as written, with this correction, rather than
  rewritten.
- The leading-edge back swipe works again on `.system`, the default transition —
  so on any app that never picked a custom one. `attach(to:)` snapshotted
  `interactivePopGestureRecognizer.isEnabled` and then used that snapshot to gate
  every later enable. It runs from the host's `.introspect`, i.e. while the stack
  is at its root and UIKit keeps the recognizer disabled because there is nothing
  to pop back to, so the snapshot was `false` and never re-read: the gesture was
  latched off for the life of the navigation controller. UIKit gates its own
  recognizer through the delegate it installs, so the router now enables it
  whenever it is not driving the pop itself, and hands it back enabled on
  `detach()` rather than restoring that same misleading capture. Custom
  transitions were unaffected: they run the package's own recognizer.

### Added

- `KVRouterHost(interactivePopEnabled:)` turns the back swipe off for the whole
  stack, covering both the custom engine and UIKit's recognizer. The router owns
  that recognizer while it is attached, so an app setting `isEnabled = false` on
  it directly has the value overwritten at the next availability refresh; this is
  the supported way to say no. It is read on every change, so it can be bound to
  state. To deny a pop per screen instead, return `false` from a middleware's
  `willPop(from:to:)`.

## 3.2.1 - 2026-08-12

### Fixed

- `KVUnhostedRouter.init()` is `nonisolated`, so the placeholder can be
  constructed where it is meant to be: the default value of a dependency key,
  which is a `nonisolated static`. Shipped in 3.2.0 inheriting the class's
  `@MainActor`, which made every intended use — including the example in its own
  documentation — fail with *main actor-isolated default value in a nonisolated
  context*. Nothing about the initializer needs the isolation; it sets one stored
  `Bool`. A `nonisolated static` declaration in the tests now constructs it, so
  the mistake cannot come back: no runtime assertion can catch a call that does
  not compile.

### Added

- `KVUnhostedRouter`: a public placeholder for `any KVRouting`, in
  `KVRouterCore`. A dependency graph needs a value before the composition root
  builds a router, and both obvious candidates are bad — a real unhosted
  `KVAppRouter` swallows pushes into an invisible stack, and a silent no-op reads
  as a broken button. This one no-ops and trips `assertionFailure` on the first
  command, naming it. Apps were writing this class themselves because
  `KVNullRouter` is internal, and would not fit anyway: it lives in
  `KVRouterKit`, imports SwiftUI, conforms to the richer `KVViewRouting`, and
  diagnoses a different problem (a view with no host above it).

## 3.1.1 - 2026-08-12

### Fixed

- UIKit's back-swipe recognizer is no longer enabled or disabled while it is
  mid-recognition. `refreshAvailability()` decides who owns the back gesture and
  runs from `navigationControllerDidShow` — for a drag dismissal, exactly as the
  transition settles. Assigning `isEnabled` to a recognizer that is tracking
  touches cancels it on the spot, and UIKit drives that transition with it, so a
  drag could be cut off as it settled. The flip now waits for the recognizer to
  leave `began`/`changed`/`ended`.
- Animation forcing no longer applies to a native-zoom pop the router did not
  drive. 3.0 removed the forcing from the router-driven path, on the reasoning
  that a second, concurrent UIKit transition is what stops SwiftUI un-hiding the
  `matchedTransitionSource` and leaves the zoom source holding an empty slot in
  the layout. A dismissal the router never sees — a gesture, the back button,
  `@Environment(\.dismiss)` — resolves through the outgoing-controller metadata
  instead, and that branch still forced every pop it recognised, native zoom
  included. It now honours the resolved backend, matching the animator handed
  back for the same pop, which has always declined native zoom.

### Known Gaps

- **The reported zoom-source bug is not this package's.** Begin the interactive
  dismissal of an iOS 18+ zoom while its push is still animating, and the zoom
  source ends up hidden: it keeps its slot in the layout and renders nothing.
  Frame-by-frame it lands correctly and stays visible for ~2 seconds after the
  animation has stopped, then disappears with nothing else on screen changing —
  SwiftUI re-applies the hidden state long after the transition is over. It
  reproduces on iOS 26.2 in a plain `NavigationStack` with
  `matchedTransitionSource` and `.navigationTransition(.zoom:)` and no
  KVRouterKit anywhere in the view tree, as readily as it does through the
  router. Widen the window with Simulator's Slow Animations to hit it by hand.
  Nothing in this package can prevent it; re-identifying the source view is what
  clears it.
- Neither fix above is therefore confirmed to change the reported symptom. The
  gesture fix is a real robustness bug found while hunting this one — cancelling
  a recognizer UIKit is driving a transition with is never right — and the
  forcing fix is reasoned purely from the code, since the swipe arrives as
  `popViewController(animated: true)` and forcing is never consulted on that path.

## 3.1.0 - 2026-08-12

### Added

- `KVRouting.routes`: the whole stack as a snapshot. `stackDepth` and `topRoute`
  cannot express a stack between them, so persisting one was impossible through
  the port — `KVPathCodec.encode(_:)` takes exactly this. Adding a requirement to
  a protocol breaks anyone conforming to it themselves, so this is not a patch
  release.
- The example app demonstrates save and restore, and reports how many screens
  survived so the truncation rule is visible rather than only documented.

## 3.0.0 - 2026-08-12

3.0 is a clean break: there is no compatibility shim and no migration guide,
because effectively nobody depended on 2.x yet.

### Breaking Changes

- **`KVAppRoute` is gone.** Apps declare their own routes as plain values
  conforming to `KVRoute`, and the composition root maps them to views with
  `.kvRoutes { }`. `appFeatureViewBuilder` and `deepLinkViewBuilder` are removed
  along with it — the closed three-case enum meant "type-safe routing" was in
  practice either `appFeature("some-string")` or a `pushView { }` closure.
- **Modals are no longer the router's business.** `KVSheetRoute`,
  `KVFullCoverRoute`, `sheet`, `fullCover`, every `present*` / `dismiss*` method
  and `KVRouteMiddleware.willDismiss` are removed. Use SwiftUI's own `.sheet`
  and `.fullScreenCover`; see the Scope section of the README for the
  sheet-then-cover recipe.
- **`handle(url:)` and `restorePath` are removed.** Deep links are parsed by the
  app and pushed like any other route.
- `KVRouteMiddleware` now speaks `any KVRoute` instead of `KVAppRoute`.
- `@Environment(\.router)` is typed `any KVViewRouting` rather than
  `KVAppRouter`, and defaults to a placeholder that reports a missing host.
- The public `path` property is replaced by the read-only `routes` snapshot plus
  `stackDepth` and `topRoute`.
- `popTo(tag:)` no longer matches typed routes. Tags come only from `pushView`;
  a typed route is a value, so `popTo(_:)` addresses it directly.

### Added

- `KVRouterCore`: the route model (`KVRoute`, `AnyKVRoute`, `KVRestorableRoute`)
  and the `KVRouting` command port. Foundation only — no SwiftUI, UIKit,
  Introspect or method swizzling — so a presentation layer can depend on it.
- `KVRouterTesting`: `KVRouterSpy`, a synchronous recording router with a
  simulated stack, for testing ViewModels without a host.
- `KVViewRouting`: `KVRouting` plus the view-layer commands (`pushView { }`,
  transition overloads).
- `KVAppRouter.settle()`: await the FIFO queue instead of polling.
- `KVAppRouter.middlewareTimeout`, so a hung middleware cannot wedge navigation.
- `handlePathChange` identifies removed entries by id rather than assuming a
  trailing truncation, which an animated replace violates by design.
- `KVNavigationTransition.pageTurn(edge:)`: a 3D rotation pivoted on a spine
  rather than the centre, so it reads as turning paper rather than flipping a
  card. Built on a new `anchor(_:)` transition primitive, which moves the point
  transforms pivot around -- applied before the animation starts, since moving an
  anchor shifts the layer's position and animating that shift would slide the view.
- `KVPathCodec`: persists and restores a stack of mixed route types, keyed on
  `KVRestorableRoute.restorationID`. Anything that cannot be carried across
  truncates the stack at that point rather than leaving a hole in it.

### Fixed

- A single `isRouterControlledPop` flag decided whether a pop was
  router-driven. It could not describe two pops in flight, and any path change
  that failed to shrink left it stuck, silently swallowing `willPop` for the
  next system pop. Replaced by per-entry bookkeeping.
- A system pop of several screens spawned one detached `Task` per screen,
  outside the FIFO queue, letting their middleware interleave.
- The middleware chain had no watchdog, so one `await` that never returned
  wedged the operation queue for the rest of the process.
- `replaceTop(with:transition:)` recorded the transition but never played it;
  the argument only took effect when that entry was later popped. There is no
  UIKit replace operation to drive -- confirmed by probing a real
  UINavigationController and by watching a deliberately two-second transition not
  play -- so the overload is rebuilt as a push followed by dropping the screen
  underneath once the animation finishes. It animates; the trade is that the
  stack is one entry deeper for the duration. The transition applies to the
  replace only: the new entry inherits the pop transition of the screen it
  replaced, and the drop is applied as a silent stack edit that no animator will
  claim. Both were needed -- storing the replace transition on the new entry made
  it play twice and made going back play it in reverse.
- A zoom transition animated to and from square corners over a rounded source.
  SwiftUI's `clipShape` and `cornerRadius` never reach `layer.cornerRadius`, so
  measuring the layer reported 0; `kvTransitionSource(id:cornerRadius:)` now takes
  the value and passes it to both the registry and the system's
  `matchedTransitionSource` configuration.
- Swipe-to-dismiss on a zoom transition left the source view hidden, holding an
  empty slot in the layout, while a button dismiss was fine. Zoom metadata was
  pruned when the navigation path changed, which for an interactive dismissal is
  when the gesture *commits* -- before its animation ends. The destination then
  re-rendered without `.navigationTransition(.zoom:)` mid-dismissal and SwiftUI
  never un-hid `matchedTransitionSource`. A button pop finished before the
  re-render, which is why only the gesture showed it. Pruning now waits for UIKit
  to report the transition finished.
- Animation forcing on the native-zoom path is push-only. The push needs it
  (SwiftUI hands UIKit `animated: false` and the zoom would not play); the pop
  does not, since SwiftUI drives that dismissal itself.
- Sheet and full-cover view builders leaked on swipe-to-dismiss. Removed with
  the modal layer rather than patched.
- The transition coordinator was wired in `onAppear`, so swapping routers left
  it driving the previous one.
- `onDisappear` tore down the UIKit bridge, so a `TabView` switch dropped custom
  transitions until the tab came back.
- `@Environment(\.router)` without a host returned a real, unhosted router, so
  navigation silently did nothing.
- `awaitSheetDismissal` leaked its continuation if the router deallocated first.
- An uncancelled 1.25s task was left behind by every system-backed push or pop.

### Performance

- Destination, sheet and cover content views observed the router with
  `@ObservedObject`, so any router change — presenting a sheet included —
  invalidated every live destination and re-ran its `AnyView` builder. They take
  a plain reference now.
- The observation backend is resolved once at init behind a strategy, instead of
  an `if #available` plus an `as? ObservationRegistrar` unbox on every property
  read.
- Internal reads use the stored entries rather than the `path` getter, which
  mapped a fresh array per access.

### Known Gaps

- The reveal transition masks a `UIHostingController` view with a `UIView`, which
  UIKit logs as unsupported. Switching to a `CALayer` mask silences it but breaks
  the animation: `UIViewPropertyAnimator` animates view properties, so a layer
  transform snaps to its final value and the wipe disappears. Fixing both means
  masking a wrapper view this package owns rather than the hosting view.
- The animated `replaceTop` drops the entry below the new top, which SwiftUI sees
  as the element at that index changing. Whether it reuses the pushed screen's
  hosting controller or rebuilds it is unverified; a rebuild would flash and reset
  that screen's local state.

### Compatibility

- Minimum deployment target remains iOS 16.0. The dual-observation layer stays:
  `@Observable` semantics on iOS 17+, `ObservableObject` on iOS 16.
- The fallback is asymmetric — `@Environment` does not observe an
  `ObservableObject` — so send commands rather than rendering from stack state.

[Full release notes](docs/releases/3.0.0.md)

## 2.0.0 - 2026-08-12

### Breaking Changes

- Renamed the package, library product, source target, test target and import
  module from `KVRouter` to `KVRouterKit`.
- Consumers must replace `import KVRouter` with `import KVRouterKit` and select
  the `KVRouterKit` product in their app target.

### Added

- Selectable push/pop transitions with automatic reverse motion: Slide, Fade,
  Scale, Scale and Fade, Shared Axis, Depth, Reveal and 3D Flip.
- A value-based custom transition DSL backed by live UIKit navigation views.
- Native SwiftUI hero zoom on iOS 18+ with a compatible live-view fallback on
  iOS 16 and 17.
- Interactive leading-edge pop for custom transitions, including reversible
  percent-driven animation.
- Per-route transition overrides, transition source registration and graceful
  `.scaleAndFade` fallback when a hero source is unavailable.

### Changed

- Rebuilt custom transitions on `UIViewControllerAnimatedTransitioning` and
  `UIViewPropertyAnimator` to preserve controller identity and local SwiftUI
  state across push/pop operations.
- Scoped UIKit navigation-animation forcing to KVRouterKit-managed single push
  and pop mutations. This restores animation when SwiftUI passes
  `animated: false` on newer runtimes without affecting unrelated navigation
  controllers or bulk path changes.
- `.system` and iOS 18+ `.zoom` remain system-owned; KVRouterKit only restores
  their animated transaction and does not replace Apple's animator.
- Improved transition hierarchy, cleanup, interruption handling, Reduce Motion
  behavior and system-dismiss reverse animations.

### Fixed

- Restored `.system` push/pop animation on iOS 18.4 and iOS 26 runtimes.
- Restored native zoom push and reverse pop animation on iOS 18+.
- Removed black disappearing frames, stale overlay ordering and destination
  state resets caused by the previous snapshot/overlay approach.
- Prevented stale animation intent from leaking after bridge detachment or an
  unmatched navigation mutation.

### Compatibility

- Minimum deployment target remains iOS 16.0.
- The package builds in Swift 6 language mode with Swift tools 6.2.
- Public router types such as `KVAppRouter`, `KVRouterHost`, `KVAppRoute` and
  middleware protocols retain their existing names.

[Full release notes](docs/releases/2.0.0.md)

## 1.0.0

- Initial KVRouter release with type-safe SwiftUI routing, dynamic destinations,
  middleware, deep links, state restoration and targeted pop APIs.
