import Foundation
import XCTest
@testable import KabanBoardCore

final class MascotKitTests: XCTestCase {
    private let emojiInOrder = [
        "🦊", "🐗", "🦉", "🦔", "🐺", "🦌", "🦝", "🐰",
        "🐱", "🐶", "🦙",
        "🐧", "🐼", "🐨", "🦭",
        "🦁", "🦒", "🦓", "🦛",
        "🐳", "🐬", "🦈", "🐙", "🐠", "🦦",
        "🐢", "🦖",
        "🦋", "🦚", "🦄",
    ]
    private let textureKeysInOrder = [
        "dots", "stripes", "crosshatch", "waves", "zigzag", "grid", "chevrons", "solid-thin",
    ]

    func testMascotAndTextureOrderIsTheSpec() {
        XCTAssertEqual(MascotKit.mascots, emojiInOrder)
        XCTAssertEqual(MascotKit.mascots.count, 30)
        XCTAssertEqual(EdgeTexture.allCases.map(\.key), textureKeysInOrder)
        XCTAssertEqual(EdgeTexture.allCases.map(\.rawValue), Array(0..<8))
    }

    func testVectorsMatchFnvIndexEmojiAndTexture() throws {
        let file = try vectors()
        XCTAssertEqual(file.vectors.count, 10)
        for vector in file.vectors {
            let hash = MascotKit.fnv1a64(vector.seed)
            XCTAssertEqual(String(format: "0x%016llx", hash), vector.fnv1a64, vector.seed)
            let pick = MascotKit.pick(seed: vector.seed)
            XCTAssertEqual(pick.mascotIndex, vector.mascotIndex, vector.seed)
            XCTAssertEqual(pick.texture.rawValue, vector.textureIndex, vector.seed)
            XCTAssertEqual(pick.emoji, vector.emoji, vector.seed)
            XCTAssertEqual(pick.texture.key, vector.texture, vector.seed)
            XCTAssertEqual(MascotKit.mascots[vector.mascotIndex], vector.emoji, vector.seed)
        }
    }

    func testCollisionDemoBumpsOnlyTheLaterProject() throws {
        let demo = try vectors().collisionDemo
        let resolved = MascotKit.resolveBoard(demo.addedOrder.map { (id: $0, seed: $0) })
        XCTAssertEqual(resolved.count, demo.resolved.count)
        for (id, expected) in demo.resolved {
            let pick = try XCTUnwrap(resolved[id], id)
            XCTAssertEqual(pick.mascotIndex, expected.mascot, id)
            XCTAssertEqual(pick.texture.rawValue, expected.texture, id)
            let base = MascotKit.pick(seed: id)
            XCTAssertEqual(base.texture.rawValue, expected.baseTexture, id)
            XCTAssertEqual(pick.mascotIndex, base.mascotIndex, id)
            XCTAssertEqual(pick.texture.rawValue == base.texture.rawValue, !expected.bumped, id)
        }
        let bumped = try XCTUnwrap(resolved["p-crm-4"])
        XCTAssertEqual(bumped.mascotIndex, 19)
        XCTAssertEqual(bumped.texture, .solidThin)
        XCTAssertEqual(bumped.texture.rawValue, 7)
    }

    func testPickerDemoFindsStripesForTheBoarAndRoundTrips() throws {
        let demo = try vectors().pickerDemo
        let texture = try XCTUnwrap(EdgeTexture(rawValue: demo.want.texture))
        let seed = MascotKit.seed(for: demo.projectId, mascotIndex: demo.want.mascot, texture: texture)
        XCTAssertEqual(seed, "p-kaban#89")
        XCTAssertEqual(seed, demo.seed)
        let pick = MascotKit.pick(seed: try XCTUnwrap(seed))
        XCTAssertEqual(pick.mascotIndex, demo.check.mascot)
        XCTAssertEqual(pick.texture.rawValue, demo.check.texture)
        XCTAssertEqual(pick.emoji, demo.check.emoji)
        XCTAssertEqual(pick.texture.key, demo.check.textureKey)
        XCTAssertEqual(pick.texture, .stripes)
        XCTAssertEqual(pick.mascotIndex, 1)
    }

    private func vectors() throws -> MascotVectorFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test-vectors", withExtension: "json"))
        return try JSONDecoder().decode(MascotVectorFile.self, from: Data(contentsOf: url))
    }
}

private struct MascotVectorFile: Decodable {
    struct Vector: Decodable {
        var seed: String
        var fnv1a64: String
        var mascotIndex: Int
        var textureIndex: Int
        var emoji: String
        var texture: String
    }

    struct Collision: Decodable {
        struct Resolved: Decodable {
            var mascot: Int
            var texture: Int
            var bumped: Bool
            var baseTexture: Int
        }

        var addedOrder: [String]
        var resolved: [String: Resolved]
    }

    struct Picker: Decodable {
        struct Want: Decodable {
            var mascot: Int
            var texture: Int
        }

        struct Check: Decodable {
            var mascot: Int
            var texture: Int
            var emoji: String
            var textureKey: String
        }

        var projectId: String
        var want: Want
        var seed: String
        var check: Check
    }

    var vectors: [Vector]
    var collisionDemo: Collision
    var pickerDemo: Picker
}
