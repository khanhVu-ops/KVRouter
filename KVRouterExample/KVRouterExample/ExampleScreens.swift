//
//  ExampleScreens.swift
//  KVRouterExample
//
//  Screens used by the demo. Navigation is driven entirely through
//  @Environment(\.router) — on iOS 17+ reads like `router.path.count`
//  are tracked with fine-grained Observation.
//

import SwiftUI
import KVRouter

// MARK: - Detail (pushed dynamically or via deep link)

struct DetailView: View {
    @Environment(\.router) private var router
    let number: Int

    var body: some View {
        List {
            Section {
                LabeledContent("Detail number", value: "\(number)")
                // Reading router.path here demonstrates observation:
                // this row updates whenever the stack changes.
                LabeledContent("Stack depth", value: "\(router.path.count)")
            }

            Section("Navigate") {
                Button("Push another detail") {
                    router.pushView { DetailView(number: number + 1) }
                }
                Button("Replace top with profile") {
                    router.replaceTop(with: .appFeature("profile"))
                }
            }

            Section("Pop") {
                Button("Pop") { router.pop() }
                Button("Pop 2") { router.pop(count: 2) }
                Button("Pop to root") { router.popToRoot() }
            }
        }
        .navigationTitle("Detail \(number)")
    }
}

// MARK: - Profile / Premium / Login (typed .appFeature routes)

struct ProfileView: View {
    @Environment(\.router) private var router

    var body: some View {
        List {
            Text("This screen is resolved from `.appFeature(\"profile\")` via `appFeatureViewBuilder`.")
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
                router.replaceTop(with: .appFeature("premium"))
            }
        }
        .navigationTitle("Login")
    }
}

// MARK: - Modals

struct SettingsSheetView: View {
    @Environment(\.router) private var router

    var body: some View {
        NavigationStack {
            List {
                Button("Dismiss") { router.dismissSheet() }
                Button("Dismiss, then present full cover") {
                    // presentFullCover dismisses the current sheet and waits
                    // for the dismissal animation before presenting.
                    router.presentFullCover { OnboardingCoverView() }
                }
                Text("Tip: swipe down — the router cleans up the sheet's builder automatically.")
            }
            .navigationTitle("Sheet")
        }
    }
}

struct OnboardingCoverView: View {
    @Environment(\.router) private var router

    var body: some View {
        VStack(spacing: 24) {
            Text("🚀")
                .font(.system(size: 72))
            Text("Full Screen Cover")
                .font(.title.bold())
            Button("Dismiss") { router.dismissFull() }
                .buttonStyle(.borderedProminent)
        }
    }
}
