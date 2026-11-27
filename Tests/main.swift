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
    queue.retain([third.id])
    check(queue.order == [third.id] && queue.original == [third.id], "Queue prunes unavailable tracks")

    let index = LibraryIndex([first, second, third])
    check(index.byID[first.id] == first && index.filter("ARTIST").count == 3, "Index and search")
    check(index.filter("", favoritesOnly: true) == [first], "Favorites")
    check(index.groups(category: "Albums", query: "").count == 3, "Distinct untagged singles")
    let artistGroup = index.groups(category: "Artists", query: "").first!
    let updatedIndex = LibraryIndex([first, third])
    check(updatedIndex.group(for: artistGroup.id)?.tracks == [first, third], "Navigation group resolves live contents")
    let remote = RemoteCommandGate()
    check(remote.accept(.play) == nil, "No remote command without a track")
    remote.update(trackID: first.id, available: [.play, .seek])
    let firstTicket = remote.accept(.play)!
    check(firstTicket.trackID == first.id && remote.accept(.next) == nil, "Remote command capability check")
    remote.update(trackID: first.id, revision: 1, available: [.play])
    check(!remote.isCurrent(firstTicket, command: .play), "Same-track stale remote command rejected")
    let secondTicket = remote.accept(.play)!
    remote.update(trackID: second.id, available: [.play])
    check(!remote.isCurrent(secondTicket, command: .play), "Stale remote command rejected")
    check(remote.accept(.seek) == nil, "Unavailable seek rejected")

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
    do { try await fresh.removeMedia(first); fatalError("Referenced media removed") } catch {}
    check(FileManager.default.fileExists(atPath: media.path), "Referenced media protected")
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
    let orphanRoot = root.appendingPathComponent("orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanRoot, withIntermediateDirectories: true)
    try Data("original audio".utf8).write(to: orphanRoot.appendingPathComponent("song.mp3"))
    let orphanRepo = LibraryRepository(root: orphanRoot)
    do { _ = try await orphanRepo.load(); fatalError("Missing index treated as empty despite existing media") } catch {}
    do { try await orphanRepo.commit([]); fatalError("Missing index overwritten") } catch {}
    check(FileManager.default.fileExists(atPath: orphanRoot.appendingPathComponent("song.mp3").path), "Orphan preserved")
    // A fresh library gets an index before any media is imported.
    let emptyRoot = root.appendingPathComponent("new-library", isDirectory: true)
    let emptyRepo = LibraryRepository(root: emptyRoot)
    let initial = try await emptyRepo.load()
    check(initial.isEmpty, "New library empty")
    let emptyIndex = emptyRoot.appendingPathComponent("library.json")
    check(FileManager.default.fileExists(atPath: emptyIndex.path), "Index initialized before import")
    let interruptedMedia = emptyRoot.appendingPathComponent("interrupted.mp3")
    try Data("partial import".utf8).write(to: interruptedMedia)
    let reopened = try await LibraryRepository(root: emptyRoot).load()
    check(reopened.isEmpty, "Interrupted first import does not block reopen")
    check(FileManager.default.fileExists(atPath: interruptedMedia.path), "Unreferenced media preserved")

    // Two repository instances opening the same index must not overwrite each other.
    let stale = LibraryRepository(root: emptyRoot)
    let staleDelete = LibraryRepository(root: emptyRoot)
    _ = try await stale.load()
    _ = try await staleDelete.load()
    let liveMedia = emptyRoot.appendingPathComponent(first.file)
    try Data("protected music".utf8).write(to: liveMedia)
    try Data("artwork".utf8).write(to: emptyRoot.appendingPathComponent(first.artwork!))
    try await emptyRepo.commit([first])
    let newerBytes = try Data(contentsOf: emptyIndex)
    // Exercise direct deletion before any failed commit can invalidate the actor.
    do { try await staleDelete.removeMedia(first); fatalError("Direct stale deletion accepted") } catch {}
    check(FileManager.default.fileExists(atPath: liveMedia.path), "Direct stale deletion preserves actual media")
    do { try await stale.commit([third]); fatalError("Stale write accepted") } catch {}
    do { try await stale.removeMedia(first); fatalError("Stale deletion accepted") } catch {}
    let afterStale = try Data(contentsOf: emptyIndex)
    check(afterStale == newerBytes, "Stale operations preserve latest index")
    let final = try await LibraryRepository(root: emptyRoot).load()
    check(final == [first], "Latest library survives stale operations")
    // Recovery must never overwrite a healthy/newer schema, delete unknown files,
    // or accept a previous index referencing files that no longer exist.
    let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
    let recoveryRepo = LibraryRepository(root: recoveryRoot)
    _ = try await recoveryRepo.load()
    let audio = recoveryRoot.appendingPathComponent(first.file)
    let art = recoveryRoot.appendingPathComponent(first.artwork!)
    try Data("music".utf8).write(to: audio)
    try Data("art".utf8).write(to: art)
    try await recoveryRepo.commit([first])
    var changed = first
    changed.favorite = false
    try await recoveryRepo.commit([changed])
    let recoveryIndex = recoveryRoot.appendingPathComponent("library.json")
    let originalBytes = try Data(contentsOf: recoveryIndex)
    let healthy = LibraryRepository(root: recoveryRoot)
    do { _ = try await healthy.inspectRecovery(); fatalError("Healthy index eligible for restore") } catch {}
    try Data("{\"schemaVersion\":99,\"tracks\":[]}".utf8).write(to: recoveryIndex)
    let newer = LibraryRepository(root: recoveryRoot)
    do { _ = try await newer.inspectRecovery(); fatalError("Newer schema eligible for restore") } catch {}
    try Data("corruption".utf8).write(to: recoveryIndex)
    let damagedRepo = LibraryRepository(root: recoveryRoot)
    do { _ = try await damagedRepo.load(); fatalError("Corruption accepted") } catch {}
    let report = try await damagedRepo.inspectRecovery()
    check(report.tracks == 1 && report.canRestore, "Recovery inspected")
    try FileManager.default.removeItem(at: audio)
    do { _ = try await damagedRepo.restorePreviousIndex(); fatalError("Missing media recovery accepted") } catch {}
    check(try Data(contentsOf: recoveryIndex) == Data("corruption".utf8), "Failed restore preserves corrupt bytes")
    try Data("music".utf8).write(to: audio)
    let restored = try await damagedRepo.restorePreviousIndex()
    check(restored == [first], "Explicit previous index restore")
    let archives = try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path)
        .filter { $0.hasPrefix("library.damaged-") }
    check(archives.count == 1, "Corrupt index archived")
    check(try Data(contentsOf: recoveryRoot.appendingPathComponent(archives[0])) == Data("corruption".utf8), "Original damaged bytes retained")
    check(try Data(contentsOf: recoveryIndex) != originalBytes, "Previous metadata restored")
    var conflicting = third
    conflicting.file = first.file.lowercased()
    do { try await damagedRepo.commit([first, conflicting]); fatalError("Case-folded collision accepted") } catch {}
    let folder = recoveryRoot.appendingPathComponent("folder.mp3", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var directoryTrack = third
    directoryTrack.file = "folder.mp3"
    do { try await damagedRepo.removeMedia(directoryTrack); fatalError("Directory deletion accepted") } catch {}
    check(FileManager.default.fileExists(atPath: folder.path), "Directory preserved")
    let linked = recoveryRoot.appendingPathComponent("link.mp3")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: audio)
    var linkTrack = third
    linkTrack.file = "link.mp3"
    do { try await damagedRepo.removeMedia(linkTrack); fatalError("Symlink deletion accepted") } catch {}
    check(FileManager.default.fileExists(atPath: audio.path), "Symlink destination preserved")

    // Deletion must leave the previous snapshot restorable. A later successful
    // rotation may reclaim only known retired media, never unrelated files.
    let retentionRoot = root.appendingPathComponent("retention", isDirectory: true)
    let retention = LibraryRepository(root: retentionRoot)
    _ = try await retention.load()
    let retainedFile = retentionRoot.appendingPathComponent(first.file)
    let retainedArt = retentionRoot.appendingPathComponent(first.artwork!)
    let unknown = retentionRoot.appendingPathComponent("unknown.mp3")
    try Data("audio".utf8).write(to: retainedFile)
    try Data("art".utf8).write(to: retainedArt)
    try Data("unknown".utf8).write(to: unknown)
    var hashed = first
    hashed.contentHash = try FileDigest.sha256(retainedFile)
    try await retention.commit([hashed])
    try await retention.commit([])
    try await retention.removeMedia(hashed)
    check(FileManager.default.fileExists(atPath: retainedFile.path), "Previous snapshot retains deleted audio")
    let retentionIndex = retentionRoot.appendingPathComponent("library.json")
    let healthyBytes = try Data(contentsOf: retentionIndex)
    try Data("damaged".utf8).write(to: retentionIndex)
    try Data("wrong bytes".utf8).write(to: retainedFile)
    let recoverRetention = LibraryRepository(root: retentionRoot)
    do { _ = try await recoverRetention.restorePreviousIndex(); fatalError("Checksum mismatch accepted") } catch {}
    check(try Data(contentsOf: retentionIndex) == Data("damaged".utf8), "Failed checksum recovery preserves index")
    try Data("audio".utf8).write(to: retainedFile)
    let recoveredRetention = try await recoverRetention.restorePreviousIndex()
    check(recoveredRetention == [hashed], "Deleted audio remains recoverable")
    try healthyBytes.write(to: retentionIndex, options: .atomic)
    let rotate = LibraryRepository(root: retentionRoot)
    _ = try await rotate.load()
    try await rotate.commit([third])
    check(!FileManager.default.fileExists(atPath: retainedFile.path), "Retired backup audio reclaimed")
    check(!FileManager.default.fileExists(atPath: retainedArt.path), "Retired backup artwork reclaimed")
    check(FileManager.default.fileExists(atPath: unknown.path), "Unknown media never reclaimed")

    // Stress the real serializer and derived index on a 10,000-track fixture.
    let large = (0..<10_000).map { i in
        Track(file: "track-\(i).flac", title: "Track \(i)", artist: "Artist \(i % 100)", album: "Album \(i % 500)", duration: 180, favorite: i % 10 == 0)
    }
    let stress = LibraryRepository(root: root.appendingPathComponent("stress"))
    _ = try await stress.load()
    let started = Date()
    try await stress.commit(large)
    let reloaded = try await stress.load()
    let indexed = await stress.makeIndex(reloaded)
    check(reloaded == large && indexed.byID.count == 10_000, "10k track round trip")
    check(indexed.filter("", favoritesOnly: true).count == 1_000, "10k track favorites")
    check(indexed.groups(category: "Artists", query: "").count == 100, "10k artist groups")
    print("10k metadata fixture commit/reload/index: \(Date().timeIntervalSince(started)) seconds (host only)")
    print("PASS: storage, migration, independent stale deletion, explicit recovery, path guards, 10k fixture, queue, index, digest")
}
try await runTests()
