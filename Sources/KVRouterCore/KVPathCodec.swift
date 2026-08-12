//
//  KVPathCodec.swift
//  KVRouterCore
//

import Foundation

/// Persists and restores a navigation stack of mixed route types.
///
/// Routes are heterogeneous values, so an archive has to record which concrete
/// type each entry was. Register the types you persist, then round-trip through
/// ``encode(_:)`` and ``decode(_:)``:
///
/// ```swift
/// var codec = KVPathCodec()
/// codec.register(ShopRoute.self)
/// codec.register(AuthRoute.self)
///
/// // Saving
/// let data = try codec.encode(router.routes)
///
/// // Restoring
/// router.setPath(try codec.decode(data))
/// ```
///
/// ## Truncation
///
/// A stack is a path, not a set: dropping an entry from the middle changes what
/// the screens below mean. So anything that cannot be carried across — a route
/// that is not ``KVRestorableRoute`` (`pushView { }` screens, whose view is a
/// closure in memory), an unregistered type, a payload that no longer decodes —
/// **truncates the stack at that point** rather than being skipped.
///
/// `[Home, Product, Checkout]` with an undecodable `Product` restores as
/// `[Home]`, never `[Home, Checkout]`.
public struct KVPathCodec {

    /// Archive format version, so a future change can be detected rather than
    /// mis-parsed.
    static let currentVersion = 1

    private var decoders: [String: (Data) throws -> any KVRoute] = [:]

    public init() {}

    /// Registers the types you want to persist.
    public init(_ types: [any KVRestorableRoute.Type]) {
        for type in types { addDecoder(for: type) }
    }

    /// Registers a route type for decoding.
    ///
    /// Registering the same ``KVRestorableRoute/restorationID`` twice replaces
    /// the earlier entry.
    public mutating func register<R: KVRestorableRoute>(_ type: R.Type) {
        addDecoder(for: type)
    }

    /// Records a decoder, taking the type either concretely or as an existential
    /// metatype.
    ///
    /// Named apart from ``register(_:)`` on purpose. An existential overload of
    /// `register` alongside the generic one recurses: inside a generic context
    /// `register(R.self)` can resolve back to the existential overload, and the
    /// result is a stack overflow rather than a compile error. A distinct name
    /// with a single generic inner function makes that unrepresentable.
    private mutating func addDecoder(for type: any KVRestorableRoute.Type) {
        func add<R: KVRestorableRoute>(_ concrete: R.Type) {
            decoders[R.restorationID] = { data in
                try JSONDecoder().decode(R.self, from: data)
            }
        }
        add(type)
    }

    /// Encodes as much of `routes` as can be restored, stopping at the first
    /// entry that cannot. See the note on truncation.
    public func encode(_ routes: [any KVRoute]) throws -> Data {
        var entries: [KVArchivedRoute] = []
        for route in routes {
            guard let restorable = route as? any KVRestorableRoute else { break }
            entries.append(try Self.archive(restorable))
        }
        let archive = KVPathArchive(
            version: Self.currentVersion,
            entries: entries
        )
        return try JSONEncoder().encode(archive)
    }

    /// Decodes as much of the archive as can be rebuilt, stopping at the first
    /// entry that cannot. See the note on truncation.
    public func decode(_ data: Data) throws -> [any KVRoute] {
        let archive = try JSONDecoder().decode(KVPathArchive.self, from: data)
        guard archive.version == Self.currentVersion else {
            throw KVPathCodecError.unsupportedVersion(archive.version)
        }

        var routes: [any KVRoute] = []
        for entry in archive.entries {
            guard let makeRoute = decoders[entry.type],
                  let route = try? makeRoute(entry.payload) else { break }
            routes.append(route)
        }
        return routes
    }

    private static func archive(
        _ route: some KVRestorableRoute
    ) throws -> KVArchivedRoute {
        KVArchivedRoute(
            type: type(of: route).restorationID,
            payload: try JSONEncoder().encode(route)
        )
    }
}

/// Failure modes a caller can act on. A route that simply cannot be rebuilt is
/// not an error — it truncates the stack.
public enum KVPathCodecError: Error, Equatable {
    /// The archive was written by a different, unrecognised format version.
    case unsupportedVersion(Int)
}

// MARK: - ================================
// MARK: Archive Format
// MARK: ================================

private struct KVPathArchive: Codable {
    let version: Int
    let entries: [KVArchivedRoute]
}

/// The payload is nested `Data` rather than inline JSON.
///
/// Inlining would mean handing a sub-decoder to a closure recovered from
/// `userInfo` — a cast through `Any` of a dictionary of function types. Nested
/// data costs a base64 layer in an archive nobody reads by hand, and keeps the
/// encode and decode paths obviously symmetric.
private struct KVArchivedRoute: Codable {
    let type: String
    let payload: Data
}
