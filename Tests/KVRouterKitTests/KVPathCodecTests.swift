//
//  KVPathCodecTests.swift
//  KVRouterKit
//

import Testing
import Foundation
import SwiftUI
import KVRouterCore
@testable import KVRouterKit

private enum ShopArchiveRoute: KVRestorableRoute {
    case cart
    case productDetail(id: Int)
}

private enum AuthArchiveRoute: KVRestorableRoute {
    case login(returnTo: String)
}

/// Restorable, but deliberately left unregistered in some tests.
private enum StrangerRoute: KVRestorableRoute {
    case somewhere
}

/// Not `KVRestorableRoute` at all — the same situation as a `pushView { }` screen.
private enum EphemeralRoute: KVRoute {
    case transient
}

@Suite("Path codec")
struct KVPathCodecTests {

    private func codec() -> KVPathCodec {
        var codec = KVPathCodec()
        codec.register(ShopArchiveRoute.self)
        codec.register(AuthArchiveRoute.self)
        return codec
    }

    // MARK: - Round trip

    @Test("Round-trips a single route type")
    func roundTripsOneType() throws {
        let codec = codec()
        let original: [any KVRoute] = [
            ShopArchiveRoute.cart,
            ShopArchiveRoute.productDetail(id: 42)
        ]

        let restored = try codec.decode(try codec.encode(original))

        #expect(restored.map { AnyKVRoute($0) } == original.map { AnyKVRoute($0) })
    }

    /// The reason an archive records a type per entry: one stack can hold routes
    /// declared by different feature modules.
    @Test("Round-trips a stack of mixed route types")
    func roundTripsMixedTypes() throws {
        let codec = codec()
        let original: [any KVRoute] = [
            ShopArchiveRoute.productDetail(id: 7),
            AuthArchiveRoute.login(returnTo: "checkout"),
            ShopArchiveRoute.cart
        ]

        let restored = try codec.decode(try codec.encode(original))

        #expect(restored.count == 3)
        #expect(restored[0] as? ShopArchiveRoute == .productDetail(id: 7))
        #expect(restored[1] as? AuthArchiveRoute == .login(returnTo: "checkout"))
        #expect(restored[2] as? ShopArchiveRoute == .cart)
    }

    @Test("An empty stack round-trips")
    func roundTripsEmpty() throws {
        let codec = codec()
        #expect(try codec.decode(try codec.encode([])).isEmpty)
    }

    /// Identically shaped cases of different types must not be confused, which is
    /// what keying on `restorationID` buys.
    @Test("Types are not confused with one another")
    func doesNotConfuseTypes() throws {
        var codec = KVPathCodec()
        codec.register(ShopArchiveRoute.self)
        codec.register(StrangerRoute.self)

        let restored = try codec.decode(
            try codec.encode([StrangerRoute.somewhere, ShopArchiveRoute.cart])
        )

        #expect(restored[0] as? StrangerRoute == .somewhere)
        #expect(restored[0] as? ShopArchiveRoute == nil)
    }

    // MARK: - Truncation

    /// Dropping an entry from the middle would leave the screens below it meaning
    /// something different, so encoding stops at the first non-restorable route.
    @Test("Encoding truncates at a non-restorable route")
    func encodingTruncatesAtNonRestorableRoute() throws {
        let codec = codec()
        let original: [any KVRoute] = [
            ShopArchiveRoute.cart,
            EphemeralRoute.transient,
            ShopArchiveRoute.productDetail(id: 9)
        ]

        let restored = try codec.decode(try codec.encode(original))

        #expect(restored.count == 1)
        #expect(restored[0] as? ShopArchiveRoute == .cart)
    }

    @Test("A leading non-restorable route yields an empty stack")
    func leadingNonRestorableYieldsEmpty() throws {
        let codec = codec()
        let data = try codec.encode([EphemeralRoute.transient, ShopArchiveRoute.cart])
        #expect(try codec.decode(data).isEmpty)
    }

    /// Same rule on the way back in: a type the reading codec does not know cuts
    /// the stack there rather than being skipped over.
    @Test("Decoding truncates at an unregistered type")
    func decodingTruncatesAtUnregisteredType() throws {
        var writer = KVPathCodec()
        writer.register(ShopArchiveRoute.self)
        writer.register(StrangerRoute.self)
        let data = try writer.encode([
            ShopArchiveRoute.cart,
            StrangerRoute.somewhere,
            ShopArchiveRoute.productDetail(id: 3)
        ])

        // The reader has not been told about StrangerRoute.
        var reader = KVPathCodec()
        reader.register(ShopArchiveRoute.self)

        let restored = try reader.decode(data)

        #expect(restored.count == 1)
        #expect(restored[0] as? ShopArchiveRoute == .cart)
    }

    @Test("Decoding truncates when a payload no longer matches its type")
    func decodingTruncatesOnPayloadMismatch() throws {
        var writer = KVPathCodec()
        writer.register(AuthArchiveRoute.self)
        writer.register(ShopArchiveRoute.self)
        let data = try writer.encode([
            ShopArchiveRoute.cart,
            AuthArchiveRoute.login(returnTo: "x")
        ])

        // Simulate a renamed type whose id now resolves to an incompatible shape.
        var reader = KVPathCodec()
        reader.register(ShopArchiveRoute.self)
        let rewired = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(
                of: AuthArchiveRoute.restorationID,
                with: ShopArchiveRoute.restorationID
            )

        let restored = try reader.decode(Data(rewired.utf8))

        #expect(restored.count == 1)
        #expect(restored[0] as? ShopArchiveRoute == .cart)
    }

    // MARK: - Versioning and registration

    @Test("An unrecognised archive version is an error, not a silent empty stack")
    func rejectsUnknownVersion() throws {
        let codec = codec()
        let data = try codec.encode([ShopArchiveRoute.cart])
        let bumped = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":999")

        #expect(throws: KVPathCodecError.unsupportedVersion(999)) {
            try codec.decode(Data(bumped.utf8))
        }
    }

    @Test("Registering by existential metatype behaves the same")
    func registersByMetatype() throws {
        let codec = KVPathCodec([ShopArchiveRoute.self, AuthArchiveRoute.self])
        let restored = try codec.decode(
            try codec.encode([AuthArchiveRoute.login(returnTo: "home")])
        )
        #expect(restored[0] as? AuthArchiveRoute == .login(returnTo: "home"))
    }

    @Test("restorationID defaults to the fully qualified type name")
    func restorationIDDefaults() {
        #expect(ShopArchiveRoute.restorationID.hasSuffix("ShopArchiveRoute"))
        #expect(ShopArchiveRoute.restorationID != AuthArchiveRoute.restorationID)
    }
}

// MARK: - End to end through the router

@MainActor
@Suite("Path restoration through the router")
struct KVPathRestorationTests {

    @Test("A stack survives encode, decode and setPath")
    func restoresIntoTheRouter() async throws {
        var codec = KVPathCodec()
        codec.register(ShopArchiveRoute.self)

        let saved = KVAppRouter()
        saved.push(ShopArchiveRoute.cart)
        saved.push(ShopArchiveRoute.productDetail(id: 5))
        await saved.settle()

        let data = try codec.encode(saved.routes)

        // A fresh router, as after a cold launch.
        let restored = KVAppRouter()
        restored.setPath(try codec.decode(data))
        await restored.settle()

        #expect(restored.stackDepth == 2)
        #expect(restored.topRoute as? ShopArchiveRoute == .productDetail(id: 5))
    }

    /// `pushView { }` screens cannot come back, and the screens above one would
    /// be stranded, so persisting stops there.
    @Test("Dynamic screens truncate the persisted stack")
    func dynamicScreensTruncate() async throws {
        var codec = KVPathCodec()
        codec.register(ShopArchiveRoute.self)

        let saved = KVAppRouter()
        saved.push(ShopArchiveRoute.cart)
        saved.pushView { EmptyView() }
        saved.push(ShopArchiveRoute.productDetail(id: 1))
        await saved.settle()
        #expect(saved.stackDepth == 3)

        let restored = KVAppRouter()
        restored.setPath(try codec.decode(try codec.encode(saved.routes)))
        await restored.settle()

        #expect(restored.stackDepth == 1)
        #expect(restored.topRoute as? ShopArchiveRoute == .cart)
    }
}
