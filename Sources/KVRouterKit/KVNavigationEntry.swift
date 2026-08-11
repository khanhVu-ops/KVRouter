import Foundation

struct KVNavigationEntry: Hashable, Identifiable {
    let id: UUID
    let route: KVAppRoute

    init(id: UUID = UUID(), route: KVAppRoute) {
        self.id = id
        self.route = route
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
