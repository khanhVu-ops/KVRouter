//
//  KVRouterKitExampleApp.swift
//  KVRouterKitExample
//
//  Created by KhanhVu on 18/7/26.
//

import SwiftUI
import Combine
import KVRouterKit

@main
struct KVRouterKitExampleApp: App {
    @StateObject private var router: KVAppRouter

    init() {
        let router = KVAppRouter(middlewares: [
            AuthMiddleware(),
            KVLoggingMiddleware(),
        ])

        // Map stable feature ids to screens in the app target.
        router.appFeatureViewBuilder = { id in
            switch id {
            case "profile": return AnyView(ProfileView())
            case "premium": return AnyView(PremiumView())
            case "login": return AnyView(LoginView())
            default: return nil
            }
        }

        // Map deep-link payloads (e.g. kvrouter://detail/42) to screens.
        router.deepLinkViewBuilder = { payload in
            guard payload.hasPrefix("detail/"),
                  let number = Int(payload.dropFirst("detail/".count)) else { return nil }
            return AnyView(DetailView(number: number))
        }

        _router = StateObject(wrappedValue: router)
    }

    var body: some Scene {
        WindowGroup {
            KVRouterHost(router: router) {
                ContentView()
            }
        }
    }
}

// MARK: - Session (auth middleware demo)

/// Simple login flag driving ``AuthMiddleware``.
final class Session: ObservableObject {
    static let shared = Session()
    @Published var isLoggedIn = false
}

/// Redirects navigation to "premium" over to the login screen while logged out.
struct AuthMiddleware: KVRouteMiddleware {
    func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? {
        if case .appFeature("premium") = to, !Session.shared.isLoggedIn {
            return .appFeature("login")
        }
        return to
    }
}
