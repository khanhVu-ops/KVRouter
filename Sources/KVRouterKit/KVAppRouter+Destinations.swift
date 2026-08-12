//
//  KVAppRouter+Destinations.swift
//  KVRouterKit
//
//  Default `buildView` for ``KVRouterHost``.
//  Map your app screens via `appFeatureViewBuilder` / `deepLinkViewBuilder`.
//

import SwiftUI

public extension KVAppRouter {

    @ViewBuilder
    func buildView(for route: KVAppRoute) -> some View {
        switch route {
        case .customView(let id):
            buildCustomView(for: id)
        case .appFeature(let id):
            if let builder = appFeatureViewBuilder, let view = builder(id) {
                view
            } else {
                EmptyView()
            }
        case .deepLink(let path):
            if let builder = deepLinkViewBuilder, let view = builder(path) {
                view
            } else {
                EmptyView()
            }
        }
    }

}

extension KVAppRouter {
    @ViewBuilder
    func buildView(for entry: KVNavigationEntry) -> some View {
        buildView(for: entry.route)
    }
}
