//
//  KVRouterKitExampleApp.swift
//  KVRouterKitExample
//
//  Created by KhanhVu on 18/7/26.
//

import SwiftUI
import Combine
import KVRouterCore
import KVRouterKit

@main
struct KVRouterKitExampleApp: App {
    @StateObject private var router: KVAppRouter

    init() {
        let router = KVAppRouter(middlewares: [
            AuthMiddleware(),
            KVLoggingMiddleware(),
        ])

        _router = StateObject(wrappedValue: router)
    }

    var body: some Scene {
        WindowGroup {
            KVRouterHost(router: router) {
                ContentView()
            }
            // Composition root: the only place that knows both routes and views.
            .kvRoutes { routes in
                routes.register(AppRoute.self) { route in
                    switch route {
                    case .profile:              ProfileView()
                    case .premium:              PremiumView()
                    case .login:                LoginView()
                    case .detail(let number):   DetailView(number: number)
                    }
                }
            }
            // Deep links are the app's to parse — the router has no opinion
            // about URL shapes.
            .onOpenURL { url in
                if let route = AppDeepLink.route(for: url) {
                    router.push(route)
                }
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

/// Redirects navigation to premium over to the login screen while logged out.
struct AuthMiddleware: KVRouteMiddleware {
    func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
        if (to as? AppRoute) == .premium, !Session.shared.isLoggedIn {
            return AppRoute.login
        }
        return to
    }
}

// MARK: - Routes

/// The app's routes: a plain value type with no view in sight. Which view each
/// case renders as is declared once, in the `.kvRoutes` registry above.
enum AppRoute: KVRoute {
    case profile
    case premium
    case login
    case detail(number: Int)
}

/// URL → route. A pure function, so it is testable without a router.
enum AppDeepLink {
    /// Handles `kvrouter://detail/42`.
    static func route(for url: URL) -> (any KVRoute)? {
        guard url.host == "detail" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let number = components.first.flatMap(Int.init) else { return nil }
        return AppRoute.detail(number: number)
    }
}
