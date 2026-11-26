import Foundation

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

func runTests() async throws {
    let first = Track(file: "test.FLAC", title: "Song", artist: "Artist", album: "Album", duration: 123.5, favorite: true, artwork: "cover.jpg")
    let second = Track(file: "second.mp3", title: "Song", artist: "Artist", album: "Unknown album", duration: 1)
    let third = Track(file: "third.mp3", title: "Song", artist: "Artist", album: "Unknown album", duration: 2)
    let decoded = try JSONDecoder().decode([Track].self, from: JSONEncoder().encode([first, second]))
    check(decoded == [first, second], "Track JSON round-trip")
    check(decoded[0].format == "FLAC" && decoded[1].format == "MP3", "Format labels")
    check(decoded[1].artwork == nil && decoded[1].contentHash == nil, "Optional fields")

    var queue = PlaybackQueue()
    queue.replace([first.id, second.id, third.id], current: second.id, shuffled: true)
    check(queue.order.first == second.id && Set(queue.order) == Set([first.id, second.id, third.id]), "Shuffle membership")
    queue.setShuffle(false, current: second.id)
    check(queue.order == [first.id, second.id, third.id], "Original queue order")
    queue.remove(second.id)
    check(queue.adjacent(to: first.id, direction: 1) == third.id, "Queue removal")
    check(queue.adjacent(to: third.id, direction: 1) == nil, "Queue end")

    let index = LibraryIndex([first, second, third])
    check(index.byID[first.id] == first && index.filter("ARTIST").count == 3, "Index and search")
    check(index.filter("", favoritesOnly: true) == [first], "Favorites")
    check(index.groups(category: "Albums", query: "").count == 3, "Distinct untagged singles")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let backup = root.appendingPathComponent("library.previous.json")
    let legacy = try JSONEncoder().encode([first, second])
    try legacy.write(to: url)
    let repo = LibraryRepository(root: root)
    let loaded = try await repo.load()
    check(loaded == [first, second], "Legacy read")
    try await repo.commit([first, third])
    let backupBytes = try Data(contentsOf: backup)
    check(backupBytes == legacy, "Previous index preserved")
    let fresh = LibraryRepository(root: root)
    let migrated = try await fresh.load()
    check(migrated == [first, third], "Versioned reload")

    var unsafe = first
    unsafe.file = "../outside.mp3"
    do { try await fresh.commit([unsafe]); fatalError("Unsafe path accepted") } catch {}
    do { try await fresh.commit([first, first]); fatalError("Duplicate ID accepted") } catch {}
    let unmodified = try await LibraryRepository(root: root).load()
    check(unmodified == [first, third], "Rejected writes preserve index")

    let media = root.appendingPathComponent("test.FLAC")
    try Data("abc".utf8).write(to: media)
    let digest = try FileDigest.sha256(media)
    check(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 fixture")

    let before = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: backup)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
    do { try await fresh.commit([third]); fatalError("Expected write failure") } catch {}
    let after = try Data(contentsOf: url)
    check(before == after, "Failed commit preserves index")
    check(FileManager.default.fileExists(atPath: media.path), "Failed commit preserves media")

    let broken = Data("not-json".utf8)
    try broken.write(to: url)
    let damaged = LibraryRepository(root: root)
    do { _ = try await damaged.load(); fatalError("Corruption accepted") } catch {}
    do { try await damaged.commit([]); fatalError("Corruption overwritten") } catch {}
    let preserved = try Data(contentsOf: url)
    check(preserved == broken, "Corrupt index untouched")
    print("PASS: model, queue, index, migration, atomic writes, corruption protection, digest")
}
try await runTests()
