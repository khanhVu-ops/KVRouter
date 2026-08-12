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
enum AppRoute: KVRestorableRoute {
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

// MARK: - Saved stack (state restoration demo)

/// Persists the navigation stack across launches with ``KVPathCodec``.
///
/// The interesting part of the API is not the round trip, it is the truncation
/// rule: anything that cannot come back — a `pushView { }` screen, an
/// unregistered type — cuts the stack at that point rather than leaving a hole
/// in it. This exposes the count on both sides so the difference is visible.
@MainActor
final class SavedStack: ObservableObject {
    static let shared = SavedStack()

    private let codec = KVPathCodec([AppRoute.self])
    private let defaultsKey = "demo.savedStack"

    struct Outcome {
        let persisted: Int
        let live: Int

        var wasTruncated: Bool { persisted < live }
    }

    /// How many screens the last save actually persisted.
    @Published private(set) var savedCount: Int?

    /// The last save, so any screen can show what survived.
    @Published private(set) var lastOutcome: Outcome?

    init() {
        savedCount = try? restorableRoutes().count
    }

    func save(_ routes: [any KVRoute]) {
        guard let data = try? codec.encode(routes),
              let survivors = try? codec.decode(data) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        savedCount = survivors.count
        lastOutcome = Outcome(persisted: survivors.count, live: routes.count)
    }

    func restorableRoutes() throws -> [any KVRoute] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return []
        }
        return try codec.decode(data)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        savedCount = nil
        lastOutcome = nil
    }
}
