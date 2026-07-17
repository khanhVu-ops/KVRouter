//
//  ContentView.swift
//  KVRouterExample
//
//  Created by KhanhVu on 18/7/26.
//

import SwiftUI
import KVRouter

struct ContentView: View {
    @Environment(\.router) private var router
    @ObservedObject private var session = Session.shared

    var body: some View {
        List {
            Section("Push navigation") {
                Button("Push typed route — .appFeature(\"profile\")") {
                    router.push(.appFeature("profile"))
                }
                Button("Push dynamic view — pushView { }") {
                    router.pushView { DetailView(number: Int.random(in: 1...99)) }
                }
                Button("Push 3 screens at once (FIFO order)") {
                    router.push(.appFeature("profile"))
                    router.pushView { DetailView(number: 1) }
                    router.pushView { DetailView(number: 2) }
                }
            }

            Section("Modal") {
                Button("Present sheet") {
                    router.presentSheet { SettingsSheetView() }
                }
                Button("Present full screen cover") {
                    router.presentFullCover { OnboardingCoverView() }
                }
                Button("Sheet → full cover (safe transition)") {
                    router.presentSheet { SettingsSheetView() }
                    // Queued right behind: the router dismisses the sheet and
                    // waits for the dismissal to finish before covering.
                    router.presentFullCover { OnboardingCoverView() }
                }
            }

            Section("Middleware — auth guard") {
                Toggle("Logged in", isOn: $session.isLoggedIn)
                Button("Push \"premium\" (redirects to login when logged out)") {
                    router.push(.appFeature("premium"))
                }
            }

            Section("Deep link") {
                Button("Open kvrouter://detail/42") {
                    router.handle(url: URL(string: "kvrouter://detail/42")!)
                }
            }
        }
        .navigationTitle("KVRouter Demo")
    }
}

#Preview {
    let router = KVAppRouter()
    return KVRouterHost(router: router) {
        ContentView()
    }
}
