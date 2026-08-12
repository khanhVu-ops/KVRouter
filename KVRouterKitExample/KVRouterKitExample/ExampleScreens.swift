//
//  ExampleScreens.swift
//  KVRouterKitExample
//
//  Screens used by the demo. Navigation is driven entirely through
//  @Environment(\.router) by *sending commands*. Reading stack state in a body
//  is deliberately not shown: `@Environment` does not observe an
//  ObservableObject, so it works on iOS 17+ and silently never updates on
//  iOS 16.
//

import SwiftUI
import KVRouterCore
import KVRouterKit

// MARK: - Transition gallery destinations

struct TransitionDemoDetail: View {
    @Environment(\.router) private var router
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.22), Color(uiColor: .systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 116, height: 116)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 34))
                    .shadow(color: tint.opacity(0.28), radius: 24, y: 14)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text("Swipe from the leading 24-point edge or use the button to preview pop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Button("Pop with reverse animation", systemImage: "arrow.backward") {
                    router.pop()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)

                Button("Pop with system dismiss", systemImage: "chevron.backward") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(tint)
            }
            .padding(24)
        }
        .navigationTitle(title)
    }
}

struct DemoCardDetail: View {
    @Environment(\.router) private var router
    @Environment(\.dismiss) private var dismiss
    let card: DemoCard

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: card.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Image(systemName: card.symbol)
                .font(.system(size: 150, weight: .thin))
                .foregroundStyle(.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 12) {
                Text("HERO ZOOM")
                    .font(.caption.bold())
                    .tracking(2.4)
                Text(card.title)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text(card.subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.82))

                Button("Return to gallery", systemImage: "arrow.down.right.and.arrow.up.left") {
                    router.pop()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(card.colors.last ?? .blue)
                .padding(.top, 10)

                Button("Return with system dismiss", systemImage: "chevron.backward") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(.black.opacity(0.12))
        }
    }
}

// MARK: - Detail (pushed dynamically or via deep link)

struct DetailView: View {
    @Environment(\.router) private var router
    let number: Int

    var body: some View {
        List {
            Section {
                LabeledContent("Detail number", value: "\(number)")
            }

            Section("Navigate") {
                Button("Push another detail") {
                    router.pushView { DetailView(number: number + 1) }
                }
                Button("Replace top with profile") {
                    // Replace is not animated: see the note on `replaceTop`.
                    router.replaceTop(with: AppRoute.profile)
                }
            }

            Section("Pop") {
                Button("Pop") { router.pop() }
                Button("Pop 2") { router.pop(count: 2) }
                Button("Pop to root") { router.popToRoot() }
            }

            Section("Pop to a specific screen") {
                Button("Pop to tag \"first-detail\"") {
                    router.popTo(tag: "first-detail")
                }
                Button("Pop to nearest DetailView (by type)") {
                    // Pops to the DetailView closest to the top, other than
                    // screens above it — no tag needed.
                    router.popTo(DetailView.self)
                }
                Button("Pop to AppRoute.profile") {
                    router.popTo(AppRoute.profile)
                }
            }
        }
        .navigationTitle("Detail \(number)")
    }
}

// MARK: - Profile / Premium / Login (typed AppRoute cases)

struct ProfileView: View {
    @Environment(\.router) private var router

    var body: some View {
        List {
            Text("This screen is resolved from `AppRoute.profile` via the `.kvRoutes` registry.")
            Button("Pop to root") { router.popToRoot() }
        }
        .navigationTitle("Profile")
    }
}

struct PremiumView: View {
    var body: some View {
        List {
            Text("💎 Premium content — you only get here while logged in (see AuthMiddleware).")
        }
        .navigationTitle("Premium")
    }
}

struct LoginView: View {
    @Environment(\.router) private var router
    @ObservedObject private var session = Session.shared

    var body: some View {
        List {
            Text("AuthMiddleware redirected you here because you were logged out.")
            Button("Log in, then continue to Premium") {
                session.isLoggedIn = true
                router.replaceTop(with: AppRoute.premium)
            }
        }
        .navigationTitle("Login")
    }
}

// MARK: - Modals

// Modals use plain SwiftUI: `@Environment(\.dismiss)` to close, and a binding
// back to the presenter to ask for a follow-up cover. The router is not
// involved — it manages the navigation stack only.

struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    /// Set before dismissing to have the presenter open the cover afterwards.
    @Binding var presentCoverOnDismiss: Bool

    var body: some View {
        NavigationStack {
            List {
                Button("Dismiss") { dismiss() }
                Button("Dismiss, then present full cover") {
                    presentCoverOnDismiss = true
                    dismiss()
                }
                Text("Swipe down works too — the presenter's onDismiss decides what happens next.")
            }
            .navigationTitle("Sheet")
        }
    }
}

struct OnboardingCoverView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("🚀")
                .font(.system(size: 72))
            Text("Full Screen Cover")
                .font(.title.bold())
            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}
