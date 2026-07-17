//
//  KVAppRoute.swift
//  KVRouter
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
/// - Note: Hashable + Codable for persistence and fast diffs.
public enum KVAppRoute: Hashable, Codable {

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

// MARK: - ================================
// MARK: Sheet Routes (Modal)
// MARK: ================================

/// Routes for `.sheet` modal presentation.
///
/// **Usage:**
/// ```swift
/// router.present(.customSheet(id))
/// router.presentSheet { CustomSheetView() }
/// ```
public enum KVSheetRoute: Hashable, Identifiable, Codable {

    // MARK: - Dynamic Sheets
    /// Generic slot for sheets built dynamically at runtime.
    case customSheet(UUID)

    // MARK: - App Sheets (Add your sheets here)
    // Example sheets for future implementation:
    // case settings
    // case languagePicker
    // case share(content: ShareContent)

    // MARK: - Identifiable
    public var id: String {
        switch self {
        case .customSheet(let uuid):
            return "sheet_\(uuid.uuidString)"
        }
    }
}

// MARK: - ================================
// MARK: Full Screen Cover Routes
// MARK: ================================

/// Routes for `.fullScreenCover` presentation.
///
/// **Usage:**
/// ```swift
/// router.presentFull(.customFullCover(id))
/// router.presentFullCover { CustomFullScreenView() }
/// ```
public enum KVFullCoverRoute: Hashable, Identifiable, Codable {

    // MARK: - Dynamic Full Covers
    /// Generic slot for full covers built dynamically at runtime.
    case customFullCover(UUID)

    // MARK: - App Full Covers (Add your full covers here)
    // Example full covers for future implementation:
    // case onboarding
    // case premium
    // case authentication

    // MARK: - Identifiable
    public var id: String {
        switch self {
        case .customFullCover(let uuid):
            return "fullCover_\(uuid.uuidString)"
        }
    }
}
