import SwiftUI
import UIKit

/// Identifies the view a zoom transition grows from — a `Sendable` stand-in for
/// `AnyHashable`, which is not.
///
/// Same trick as `AnyKVRoute`: keep the existential constrained to
/// `Hashable & Sendable` and erase to `AnyHashable` only where the id is handed
/// to the source registry or to SwiftUI's `matchedTransitionSource`. Storing an
/// `AnyHashable` in ``KVNavigationTransition`` instead would forfeit that type's
/// `Sendable` conformance, and with it the ability to keep a transition in a
/// `Sendable` type — which is what a route-level default is.
struct KVTransitionSourceID: Hashable, Sendable {
    private let base: any Hashable & Sendable

    init(_ base: some Hashable & Sendable) {
        self.base = base
    }

    /// The id as the registry and SwiftUI see it.
    var anyHashable: AnyHashable { AnyHashable(base) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.anyHashable == rhs.anyHashable
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(anyHashable)
    }
}

/// The identity SwiftUI sees for a native zoom source.
///
/// `matchedTransitionSource` can retain its private hidden state after a zoom
/// dismissal has finished. Keeping the caller's logical id stable would let
/// that stale state attach to the source again. The generation changes only
/// after UIKit reports the pop complete, so the destination and source still
/// share one identity for the entire transition while the returned source gets
/// a fresh identity before it can be hidden again.
struct KVNativeTransitionSourceID: Hashable {
    let logicalID: AnyHashable
    let generation: UInt64
}

/// Identifies which `kvTransitionSource` wrote a registry entry.
///
/// A logical id is the caller's, not a view's, and callers legitimately move one from view to
/// view: a paged viewer hands its zoom identity to whichever thumbnail is now on screen, so two
/// cells trade ids in a single update. SwiftUI installs the new subtrees and only then runs the
/// old ones' `onDisappear`, so a teardown that removed by id alone deleted the entry its
/// successor had just written. Nothing reported that — ``KVTransitionCoordinator/resolve``
/// treats a missing source as "this view is not on screen" and quietly substitutes a fade.
///
/// A class, so identity is the whole value; `@StateObject` keeps one per view for as long as that
/// view exists, which is exactly the lifetime an entry should have.
@MainActor
final class KVTransitionSourceOwner: ObservableObject {}

/// Registry key for a ``SwiftUI/View/kvTransitionDestination(id:cornerRadius:)``.
///
/// Destinations share the registry with sources — same probe, same weak view, same ownership
/// rules — but not the id space: an app naming its destination `"prompt"` after a source
/// `"prompt"` must not have one overwrite the other.
struct KVTransitionDestinationKey: Hashable {
    let id: AnyHashable
}

@MainActor
final class KVTransitionSourceRegistry: ObservableObject {
    struct Source {
        let frame: CGRect
        let viewBox: KVWeakViewBox?
        let cornerRadius: CGFloat
        /// `nil` for a caller that does not claim ownership; such an entry may be removed by id.
        let owner: ObjectIdentifier?

        @MainActor
        func resolved(in container: UIView) -> KVHeroTransitionGeometry? {
            let resolvedFrame: CGRect
            if let viewBox {
                guard let view = viewBox.view,
                      view.window != nil else {
                    return nil
                }
                resolvedFrame = view.convert(view.bounds, to: container)
            } else if let window = container.window {
                resolvedFrame = container.convert(frame, from: window)
            } else {
                resolvedFrame = frame
            }
            guard KVTransitionSourceRegistry.isValid(frame: resolvedFrame) else {
                return nil
            }
            return KVHeroTransitionGeometry(
                frame: resolvedFrame,
                cornerRadius: cornerRadius
            )
        }
    }

    private var sources: [AnyHashable: Source] = [:]
    /// The one ID each owner currently holds. A source registers under exactly one logical ID at
    /// a time, so when a caller moves an ID the entry the owner used to hold goes with it —
    /// otherwise the old ID keeps pointing at a view that has since started answering to another,
    /// and the zoom grows from the wrong cell.
    private var ownedIDs: [ObjectIdentifier: AnyHashable] = [:]
    private var nativeSourceGenerations: [AnyHashable: UInt64] = [:]

    /// Changes only when a completed native zoom pop rotates a source identity.
    /// Geometry probes deliberately do not publish, or scrolling a grid would
    /// invalidate every matched transition source on every layout pass.
    @Published private(set) var nativeSourceRevision: UInt64 = 0

    /// Sources an anchored zoom is standing in for right now. Their view renders at opacity
    /// 0 so the source never shows twice — once in place, once travelling. Published, but
    /// only at a transition's start and end.
    @Published private(set) var hiddenSourceIDs: Set<AnyHashable> = []

    func setSourceHidden(_ hidden: Bool, id: AnyHashable) {
        if hidden {
            hiddenSourceIDs.insert(id)
        } else {
            hiddenSourceIDs.remove(id)
        }
    }

    func isSourceHidden(_ id: AnyHashable) -> Bool {
        hiddenSourceIDs.contains(id)
    }

    func destination(for id: AnyHashable) -> Source? {
        source(for: AnyHashable(KVTransitionDestinationKey(id: id)))
    }

    func update(
        id: AnyHashable,
        frame: CGRect,
        view: UIView?,
        cornerRadius: CGFloat? = nil,
        owner: KVTransitionSourceOwner? = nil
    ) {
        guard Self.isValid(frame: frame) else {
            // An invalid frame is this owner's own measurement failing, so it clears only what it
            // owns. Clearing by id would let a laid-out cell be erased by a zero-sized one that
            // happens to be measuring the id this cell now holds.
            removeIfOwned(id: id, by: owner)
            return
        }
        if let owner {
            let key = ObjectIdentifier(owner)
            if let previous = ownedIDs[key], previous != id {
                removeIfOwned(id: previous, by: owner)
            }
            ownedIDs[key] = id
        }
        sources[id] = Source(
            frame: frame,
            viewBox: view.map(KVWeakViewBox.init),
            cornerRadius: cornerRadius ?? view?.layer.cornerRadius ?? 0,
            owner: owner.map(ObjectIdentifier.init)
        )
    }

    /// Removes an entry only if `owner` still holds it — see ``KVTransitionSourceOwner``.
    /// A `nil` owner removes unconditionally, which is what a caller with no claim means.
    func remove(id: AnyHashable, owner: KVTransitionSourceOwner? = nil) {
        removeIfOwned(id: id, by: owner)
    }

    private func removeIfOwned(id: AnyHashable, by owner: KVTransitionSourceOwner?) {
        guard let owner else {
            sources[id] = nil
            return
        }
        let key = ObjectIdentifier(owner)
        defer { if ownedIDs[key] == id { ownedIDs[key] = nil } }
        guard let existing = sources[id] else { return }
        // An entry with no recorded owner predates any claim, so whoever is speaking may clear it.
        guard existing.owner == nil || existing.owner == key else { return }
        sources[id] = nil
    }

    func source(for id: AnyHashable) -> Source? {
        guard let source = sources[id] else { return nil }
        if let viewBox = source.viewBox, viewBox.view == nil {
            sources[id] = nil
            return nil
        }
        return source
    }

    func nativeSourceID(for id: AnyHashable) -> AnyHashable {
        AnyHashable(
            KVNativeTransitionSourceID(
                logicalID: id,
                generation: nativeSourceGenerations[id, default: 0]
            )
        )
    }

    /// Gives the returned source a fresh native identity after its zoom pop.
    /// The logical id exposed by `kvTransitionSource(id:)` remains unchanged.
    func resetNativeSource(id: AnyHashable) {
        nativeSourceGenerations[id, default: 0] &+= 1
        nativeSourceRevision &+= 1
    }

    static func isValid(frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

struct KVHeroTransitionGeometry {
    let frame: CGRect
    let cornerRadius: CGFloat

    func resolvedState(for fullFrame: CGRect) -> KVResolvedHeroState {
        guard fullFrame.width > 0, fullFrame.height > 0 else {
            return KVResolvedHeroState()
        }
        let scale = CGSize(
            width: frame.width / fullFrame.width,
            height: frame.height / fullFrame.height
        )
        let translation = CGSize(
            width: frame.midX - fullFrame.midX,
            height: frame.midY - fullFrame.midY
        )
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(
            transform,
            translation.width,
            translation.height,
            0
        )
        transform = CATransform3DScale(
            transform,
            scale.width,
            scale.height,
            1
        )
        return KVResolvedHeroState(
            transform: transform,
            scale: scale,
            translation: translation,
            cornerRadius: cornerRadius
        )
    }
}

struct KVResolvedHeroState {
    var transform = CATransform3DIdentity
    var scale = CGSize(width: 1, height: 1)
    var translation = CGSize.zero
    var cornerRadius: CGFloat = 0
}

final class KVWeakViewBox {
    weak var view: UIView?

    init(_ view: UIView) {
        self.view = view
    }
}

private struct KVTransitionSourceModifier: ViewModifier {
    let id: AnyHashable
    let cornerRadius: CGFloat

    @Environment(\.kvTransitionNamespace) private var namespace
    @Environment(\.kvTransitionSourceRegistry) private var registry
    /// One per view, for as long as the view exists — see ``KVTransitionSourceOwner``. It lives
    /// out here rather than inside the `.id(nativeID)` subtree on purpose: that subtree is
    /// deliberately replaced whenever the id changes, and an owner replaced along with it would
    /// identify nothing.
    @StateObject private var owner = KVTransitionSourceOwner()

    @ViewBuilder
    func body(content: Content) -> some View {
        let observedContent = content
            .background {
                KVViewProbe { view, frame in
                    registry?.update(
                        id: id,
                        frame: frame,
                        view: view,
                        // The caller's value wins. A SwiftUI `clipShape` or
                        // `cornerRadius` never reaches `layer.cornerRadius` —
                        // SwiftUI clips its own way — so reading the layer alone
                        // measured 0 and the hero animation landed on square
                        // corners over a rounded source.
                        cornerRadius: cornerRadius > 0
                            ? cornerRadius
                            : view.layer.cornerRadius,
                        owner: owner
                    )
                }
            }
            .onDisappear {
                registry?.remove(id: id, owner: owner)
            }

        if let registry {
            KVTransitionSourceVisibility(
                content: nativeOrPlain(observedContent, registry: registry),
                id: id,
                registry: registry
            )
        } else {
            observedContent
        }
    }

    @ViewBuilder
    private func nativeOrPlain<V: View>(
        _ observedContent: V,
        registry: KVTransitionSourceRegistry
    ) -> some View {
        if #available(iOS 18.0, *), let namespace {
            KVNativeTransitionSource(
                content: observedContent,
                id: id,
                cornerRadius: cornerRadius,
                namespace: namespace,
                registry: registry
            )
        } else {
            observedContent
        }
    }
}

/// Hides a source while an anchored zoom stands in for it — see
/// ``KVTransitionSourceRegistry/hiddenSourceIDs``.
private struct KVTransitionSourceVisibility<Content: View>: View {
    let content: Content
    let id: AnyHashable
    @ObservedObject var registry: KVTransitionSourceRegistry

    var body: some View {
        content.opacity(registry.isSourceHidden(id) ? 0 : 1)
    }
}

/// Registers where a ``SwiftUI/View/kvTransitionDestination(id:cornerRadius:)`` sits, with the
/// same probe as a source and none of a source's native-zoom wiring.
private struct KVTransitionDestinationModifier: ViewModifier {
    let id: AnyHashable
    let cornerRadius: CGFloat

    @Environment(\.kvTransitionSourceRegistry) private var registry
    @StateObject private var owner = KVTransitionSourceOwner()

    func body(content: Content) -> some View {
        let key = AnyHashable(KVTransitionDestinationKey(id: id))
        content
            .background {
                KVViewProbe { view, frame in
                    registry?.update(
                        id: key,
                        frame: frame,
                        view: view,
                        cornerRadius: cornerRadius,
                        owner: owner
                    )
                }
            }
            .onDisappear {
                registry?.remove(id: key, owner: owner)
            }
    }
}

@available(iOS 18.0, *)
private struct KVNativeTransitionSource<Content: View>: View {
    let content: Content
    let id: AnyHashable
    let cornerRadius: CGFloat
    let namespace: Namespace.ID
    @ObservedObject var registry: KVTransitionSourceRegistry

    var body: some View {
        let nativeID = registry.nativeSourceID(for: id)
        // The system needs the shape too, for the same reason as the custom
        // transition registry. `.id(nativeID)` also replaces the exact SwiftUI
        // subtree on which matchedTransitionSource stored its hidden state.
        content
            .matchedTransitionSource(id: nativeID, in: namespace) {
                $0.clipShape(.rect(cornerRadius: cornerRadius))
            }
            .id(nativeID)
    }
}

public extension View {

    /// Marks this view as the source of a ``KVNavigationTransition/zoom(sourceID:)``.
    ///
    /// - Parameters:
    ///   - id: Matches the `sourceID` passed to the transition.
    ///   - cornerRadius: The source's corner radius. Pass the same value used to
    ///     round the view: SwiftUI's `clipShape` and `cornerRadius` do not set
    ///     `layer.cornerRadius`, so it cannot be measured, and leaving it at 0
    ///     makes the transition animate to and from square corners.
    func kvTransitionSource<ID: Hashable>(
        id: ID,
        cornerRadius: CGFloat = 0
    ) -> some View {
        modifier(
            KVTransitionSourceModifier(
                id: AnyHashable(id),
                cornerRadius: cornerRadius
            )
        )
    }
}

public extension View {

    /// Marks the view an anchored zoom travels through on the **incoming** screen — see
    /// ``KVNavigationTransition/zoom(sourceID:destinationID:)``.
    ///
    /// Typically the screen's own version of the source: a home screen's input bar as the
    /// source, the chat screen's composer as the destination.
    ///
    /// - Parameters:
    ///   - id: Matches the `destinationID` passed to the transition.
    ///   - cornerRadius: The view's corner radius, for the same reason as on
    ///     ``kvTransitionSource(id:cornerRadius:)``.
    func kvTransitionDestination<ID: Hashable>(
        id: ID,
        cornerRadius: CGFloat = 0
    ) -> some View {
        modifier(
            KVTransitionDestinationModifier(
                id: AnyHashable(id),
                cornerRadius: cornerRadius
            )
        )
    }
}

private struct KVViewProbe: UIViewRepresentable {
    let onUpdate: @MainActor (UIView, CGRect) -> Void

    func makeUIView(context: Context) -> KVProbeUIView {
        let view = KVProbeUIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onLayout = onUpdate
        return view
    }

    func updateUIView(_ uiView: KVProbeUIView, context: Context) {
        uiView.onLayout = onUpdate
        uiView.reportLayout()
    }
}

private final class KVProbeUIView: UIView {
    var onLayout: (@MainActor (UIView, CGRect) -> Void)?

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
        let sourceView = superview ?? self
        onLayout?(sourceView, convert(bounds, to: window))
    }
}
