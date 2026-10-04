import Foundation
import XCTest
@testable import CoveStore

/// A temp directory removed when the test finishes.
func makeTempDirectory(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cove-store-tests-\(CoveID.make())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

func makeStore(_ test: XCTestCase) throws -> CoveStore {
    try CoveStore.inMemory(attachmentsDirectory: makeTempDirectory(test).appendingPathComponent("Attachments"))
}

/// A message at a fixed offset from a base time, so ordering is deterministic.
func msg(_ id: String, chat: String, parent: String?, role: Role = .user, _ text: String, t: Double) -> Message {
    Message(id: id, chatID: chat, parentID: parent, role: role, content: [.text(text)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + t))
}
