import KVRouterKit
import SwiftUI

struct DemoCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
}

private struct TransitionOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let transition: KVNavigationTransition
}

struct TransitionGalleryView: View {
    @Environment(\.router) private var router

    private let cards: [DemoCard] = [
        DemoCard(
            id: "aurora",
            title: "Aurora",
            subtitle: "Native zoom on iOS 18+",
            symbol: "sparkles",
            colors: [.mint, .cyan, .blue]
        ),
        DemoCard(
            id: "ember",
            title: "Ember",
            subtitle: "Custom hero fallback on iOS 16-17",
            symbol: "flame.fill",
            colors: [.yellow, .orange, .red]
        ),
        DemoCard(
            id: "tidal",
            title: "Tidal",
            subtitle: "The source survives reverse pop",
            symbol: "water.waves",
            colors: [.teal, .blue, .indigo]
        ),
        DemoCard(
            id: "canopy",
            title: "Canopy",
            subtitle: "Stable IDs keep matching reliable",
            symbol: "leaf.fill",
            colors: [.green, .mint, .cyan]
        ),
    ]

    private var transitionOptions: [TransitionOption] {
        [
            TransitionOption(
                id: "system",
                title: "System",
                subtitle: "Apple's standard push",
                symbol: "iphone",
                tint: .blue,
                transition: .system
            ),
            TransitionOption(
                id: "slide",
                title: "Slide",
                subtitle: "Directional and familiar",
                symbol: "arrow.right",
                tint: .cyan,
                transition: .slide()
            ),
            TransitionOption(
                id: "fade",
                title: "Fade",
                subtitle: "Quiet crossfade",
                symbol: "circle.lefthalf.filled",
                tint: .gray,
                transition: .fade
            ),
            TransitionOption(
                id: "scale",
                title: "Scale",
                subtitle: "Soft focus change",
                symbol: "arrow.up.left.and.arrow.down.right",
                tint: .mint,
                transition: .scale
            ),
            TransitionOption(
                id: "scale-fade",
                title: "Scale + Fade",
                subtitle: "Compact and polished",
                symbol: "square.stack.3d.up",
                tint: .teal,
                transition: .scaleAndFade
            ),
            TransitionOption(
                id: "shared-axis",
                title: "Shared Axis",
                subtitle: "Content moves as one flow",
                symbol: "rectangle.2.swap",
                tint: .indigo,
                transition: .sharedAxis()
            ),
            TransitionOption(
                id: "depth",
                title: "Depth",
                subtitle: "Layered scale and focus",
                symbol: "square.3.layers.3d",
                tint: .purple,
                transition: .depth
            ),
            TransitionOption(
                id: "reveal",
                title: "Reveal",
                subtitle: "Unfold from a corner",
                symbol: "rectangle.inset.filled.and.person.filled",
                tint: .orange,
                transition: .reveal()
            ),
            TransitionOption(
                id: "flip",
                title: "3D Flip",
                subtitle: "A bold card turn",
                symbol: "rotate.3d",
                tint: .pink,
                transition: .flip3D()
            ),
            TransitionOption(
                id: "custom",
                title: "Custom Orbit",
                subtitle: "Spring, rotation, scale and fade",
                symbol: "wand.and.stars",
                tint: .red,
                transition: customOrbitTransition
            ),
        ]
    }

    private var customOrbitTransition: KVNavigationTransition {
        .custom(
            push: KVTransitionStage(
                incoming: .identity
                    .relativeOffset(y: 0.08)
                    .scale(0.86)
                    .rotation(.degrees(12))
                    .opacity(0),
                outgoing: .identity
                    .scale(0.97)
                    .rotation(.degrees(-3))
                    .opacity(0.9)
            ),
            pop: .mirrored,
            animation: .spring(response: 0.55, dampingFraction: 0.78),
            interactiveBack: true
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                introduction
                heroSection
                builtInSection
                stressSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(galleryBackground.ignoresSafeArea())
        .navigationTitle("Transitions")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Motion with intent")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Pick a transition per push. Swipe from the leading edge to test the matching custom pop animation.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Hero Zoom",
                caption: "System-powered on iOS 18+, live-view fallback on iOS 16-17"
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(cards) { card in
                    Button {
                        router.pushView(transition: .zoom(sourceID: card.id)) {
                            DemoCardDetail(card: card)
                        }
                    } label: {
                        heroCard(card)
                            .kvTransitionSource(id: card.id, cornerRadius: 24)
                            .shadow(
                                color: card.colors.last?.opacity(0.24) ?? .clear,
                                radius: 16,
                                y: 10
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(card.title) hero zoom demo")
                }
            }
        }
    }

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Push + Pop Styles",
                caption: "Each row pushes the same destination with different motion"
            )

            LazyVStack(spacing: 10) {
                ForEach(transitionOptions) { option in
                    Button {
                        router.pushView(transition: option.transition) {
                            TransitionDemoDetail(
                                title: option.title,
                                subtitle: option.subtitle,
                                symbol: option.symbol,
                                tint: option.tint
                            )
                        }
                    } label: {
                        transitionRow(option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview \(option.title) transition")
                }
            }
        }
    }

    private var stressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Fallback Lab",
                caption: "Exercise queue ordering and missing hero sources"
            )

            Button {
                router.pushView(transition: .slide()) {
                    TransitionDemoDetail(
                        title: "Rapid 1 / 3",
                        subtitle: "Slide entered first",
                        symbol: "1.circle.fill",
                        tint: .cyan
                    )
                }
                router.pushView(transition: .depth) {
                    TransitionDemoDetail(
                        title: "Rapid 2 / 3",
                        subtitle: "Depth stayed second in FIFO order",
                        symbol: "2.circle.fill",
                        tint: .indigo
                    )
                }
                router.pushView(transition: .flip3D()) {
                    TransitionDemoDetail(
                        title: "Rapid 3 / 3",
                        subtitle: "3D Flip completed the queue",
                        symbol: "3.circle.fill",
                        tint: .pink
                    )
                }
            } label: {
                labButtonLabel(
                    title: "Push three screens rapidly",
                    subtitle: "Slide -> Depth -> 3D Flip",
                    symbol: "forward.end.fill",
                    tint: .indigo
                )
            }
            .buttonStyle(.plain)

            Button {
                router.pushView(transition: .zoom(sourceID: "missing-source")) {
                    TransitionDemoDetail(
                        title: "Missing Hero Source",
                        subtitle: "KVRouterKit fell back to Scale + Fade",
                        symbol: "questionmark.square.dashed",
                        tint: .orange
                    )
                }
            } label: {
                labButtonLabel(
                    title: "Request a missing hero source",
                    subtitle: "Falls back without blocking navigation",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    tint: .orange
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroCard(_ card: DemoCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: card.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: card.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.headline)
                Text(card.subtitle)
                    .font(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(height: 178)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func transitionRow(_ option: TransitionOption) -> some View {
        HStack(spacing: 14) {
            Image(systemName: option.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(option.tint)
                .frame(width: 44, height: 44)
                .background(option.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(option.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(option.tint.opacity(0.14), lineWidth: 1)
        }
    }

    private func labButtonLabel(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(14)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
    }

    private var galleryBackground: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            RadialGradient(
                colors: [.cyan.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 360
            )
            RadialGradient(
                colors: [.orange.opacity(0.08), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 420
            )
        }
    }
}

#Preview {
    let router = KVAppRouter()
    return KVRouterHost(router: router) {
        TransitionGalleryView()
    }
}
