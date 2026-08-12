//
//  ContentView.swift
//  KVRouterKitExample
//
//  Created by KhanhVu on 18/7/26.
//

import SwiftUI
import KVRouterCore
import KVRouterKit

struct ContentView: View {
    @Environment(\.router) private var router
    @ObservedObject private var session = Session.shared

    // Modals are the app's own state now — KVRouterKit manages the navigation
    // stack only, and SwiftUI already models presentation declaratively.
    @State private var showsSettingsSheet = false
    @State private var showsOnboardingCover = false
    @State private var coverFollowsSheet = false

    var body: some View {
        List {
            Section("Transition gallery") {
                Button {
                    router.pushView(transition: .sharedAxis()) {
                        TransitionGalleryView()
                    }
                } label: {
                    Label("Explore push + pop animations", systemImage: "sparkles.rectangle.stack")
                }
            }

            Section("Push navigation") {
                Button("Push typed route — AppRoute.profile") {
                    router.push(AppRoute.profile)
                }
                Button("Push dynamic view — pushView { }") {
                    router.pushView { DetailView(number: Int.random(in: 1...99)) }
                }
                Button("Push 3 screens at once (FIFO order)") {
                    router.push(AppRoute.profile)
                    // Tagged — DetailView's "Pop to tag" button jumps back here.
                    router.pushView(tag: "first-detail") { DetailView(number: 1) }
                    router.pushView { DetailView(number: 2) }
                }
            }

            Section("Modal — plain SwiftUI") {
                Button("Present sheet") {
                    showsSettingsSheet = true
                }
                Button("Present full screen cover") {
                    showsOnboardingCover = true
                }
                Button("Sheet → full cover (safe transition)") {
                    coverFollowsSheet = true
                    showsSettingsSheet = true
                }
            }

            Section("Middleware — auth guard") {
                Toggle("Logged in", isOn: $session.isLoggedIn)
                Button("Push premium (redirects to login when logged out)") {
                    router.push(AppRoute.premium)
                }
            }

            Section("Deep link") {
                Button("Open kvrouter://detail/42") {
                    if let route = AppDeepLink.route(
                        for: URL(string: "kvrouter://detail/42")!
                    ) {
                        router.push(route)
                    }
                }
            }
        }
        .navigationTitle("KVRouterKit Demo")
        // Recipe for sheet → full cover: SwiftUI cannot present a cover while a
        // sheet is up, so chain it from `onDismiss` — that fires once the
        // dismissal actually finishes, with no timing guesswork.
        .sheet(isPresented: $showsSettingsSheet) {
            if coverFollowsSheet {
                coverFollowsSheet = false
                showsOnboardingCover = true
            }
        } content: {
            SettingsSheetView(presentCoverOnDismiss: $coverFollowsSheet)
        }
        .fullScreenCover(isPresented: $showsOnboardingCover) {
            OnboardingCoverView()
        }
    }
}

#Preview {
    let router = KVAppRouter()
    return KVRouterHost(router: router) {
        ContentView()
    }
}
