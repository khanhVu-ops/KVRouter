import SwiftUI
import UIKit

@MainActor
final class KVTransitionSourceRegistry: ObservableObject {
    struct Source {
        let frame: CGRect
        let viewBox: KVWeakViewBox?
        let cornerRadius: CGFloat

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

    func update(
        id: AnyHashable,
        frame: CGRect,
        view: UIView?,
        cornerRadius: CGFloat? = nil
    ) {
        guard Self.isValid(frame: frame) else {
            sources[id] = nil
            return
        }
        sources[id] = Source(
            frame: frame,
            viewBox: view.map(KVWeakViewBox.init),
            cornerRadius: cornerRadius ?? view?.layer.cornerRadius ?? 0
        )
    }

    func remove(id: AnyHashable) {
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
                            : view.layer.cornerRadius
                    )
                }
            }
            .onDisappear {
                registry?.remove(id: id)
            }

        if #available(iOS 18.0, *), let namespace {
            // The system needs the shape too, for the same reason.
            observedContent.matchedTransitionSource(id: id, in: namespace) {
                $0.clipShape(.rect(cornerRadius: cornerRadius))
            }
        } else {
            observedContent
        }
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
