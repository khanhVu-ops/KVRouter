//
//  KVAppRoute.swift
//  KVRouterKit
//
//  Created by Khanh Vu.
//

import SwiftUI

// MARK: - ================================
// MARK: Navigation Routes
// MARK: ================================

/// Typed routes for push navigation in a NavigationStack.
///
/// **Usage:**
/// ```swift
/// router.push(.appFeature("home"))
/// router.pushView { CustomView() } // For dynamic views
/// ```
///
/// **Adding new routes:**
/// 1. Add a new case to this enum
/// 2. Update `KVAppRouter+Destinations.buildView(for:)` (or your app’s replacement) for the new case
///
/// - Note: Hashable + Codable for persistence and fast diffs. `Sendable` is
///   declared here rather than alongside the `KVRoute` conformance in
///   `KVAppRouter+KVRouting.swift`, because Swift requires `Sendable` to be
///   stated in the same file as the type.
public enum KVAppRoute: Hashable, Codable, Sendable {

    // MARK: - Dynamic Routes
    /// Generic slot for views built dynamically at runtime.
    /// Used by `router.pushView { }` - stores view builder in router's registry.
    case customView(UUID)

    // MARK: - Host app namespace (resolve via ``KVAppRouter/appFeatureViewBuilder`` / ``KVAppRouter/deepLinkViewBuilder``)
    /// Stable id chosen by the app (e.g. `"profile"`). Map to views in the host target — see app sample `AppScreen` + `AppRouteViewFactory`.
    case appFeature(String)
    /// Opaque path fragment (e.g. from URL) — map in ``KVAppRouter/deepLinkViewBuilder``.
    case deepLink(String)

    /// Whether this route survives persistence / state restoration.
    ///
    /// `.customView` stores its view builder in memory only — a decoded
    /// `.customView` has no builder and would render ``EmptyView``.
    /// Use ``KVAppRouter/restorePath(_:)`` when restoring a persisted path;
    /// it drops non-restorable routes automatically.
    public var isRestorable: Bool {
        if case .customView = self { return false }
        return true
    }
}

// Modals are not the router's concern: use SwiftUI's own `.sheet` and
// `.fullScreenCover`. See the "Modal" section of the example app for the
// sheet-then-cover recipe.
