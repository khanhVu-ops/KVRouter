import Foundation
import KVRouterCore

struct KVNavigationEntry: Hashable, Identifiable {
    let id: UUID
    let route: AnyKVRoute

    init(id: UUID = UUID(), route: AnyKVRoute) {
        self.id = id
        self.route = route
    }

    init(id: UUID = UUID(), route: any KVRoute) {
        self.init(id: id, route: AnyKVRoute(route))
    }

    // Identity is the entry id, not the route: two screens showing the same
    // route are distinct stack positions and must not collapse into one.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
