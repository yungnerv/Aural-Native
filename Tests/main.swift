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

    check(TrackMetadata.Position.parse(" 7 / 12 ")?.number == 7, "ID3 track position")
    check(TrackMetadata.Position.parse("7/12")?.total == 12, "ID3 track total")
    check(TrackMetadata.Position.parse("7/0")?.total == nil, "Unknown total stays missing")
    check(TrackMetadata.Position.parse("0") == nil && TrackMetadata.Position.parse("9/2") == nil &&
          TrackMetadata.Position.parse("4/") == nil, "Malformed positions rejected")
    check(TrackMetadata.Position.parseITunes(Data([0, 0, 0, 7, 0, 12, 0, 0])) ==
          TrackMetadata.Position(number: 7, total: 12), "iTunes binary position")
    check(TrackMetadata.Position.parseITunes(Data([0, 0, 0, 2, 0, 0])) ==
          TrackMetadata.Position(number: 2), "iTunes unknown total")
    check(TrackMetadata.Position.parseITunes(Data([1, 0, 0, 7, 0, 12])) == nil, "Invalid binary position")

    var collaboration = first
    collaboration.metadata = TrackMetadata(albumArtist: "Various Artists", genre: "Hip Hop",
                                          track: .init(number: 2), disc: .init(number: 1))
    var compilationTrack = second
    compilationTrack.artist = "Guest"
    compilationTrack.album = first.album
    compilationTrack.metadata = TrackMetadata(albumArtist: "Various Artists", composer: "Composer",
                                             track: .init(number: 1), disc: .init(number: 1))
    let compilation = LibraryIndex([collaboration, compilationTrack])
    let compilationGroups = compilation.groups(category: .albums, query: "")
    check(compilationGroups.count == 1 && compilationGroups[0].tracks == [compilationTrack, collaboration],
          "Album artist groups collaborations in disc/track order")
    check(compilation.filter("Composer") == [compilationTrack], "Extended tag search")
    let metadataRoundTrip = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(collaboration))
    check(metadataRoundTrip == collaboration, "Extended metadata round trip")

    var queue = PlaybackQueue()
    queue.replace([first.id, second.id, third.id], current: second.id, shuffled: true)
    check(queue.order.first == second.id && Set(queue.order) == Set([first.id, second.id, third.id]), "Shuffle membership")
    queue.setShuffle(false, current: second.id)
    check(queue.order == [first.id, second.id, third.id], "Original queue order")
    queue.remove(second.id)
    check(queue.adjacent(to: first.id, direction: 1) == third.id, "Queue removal")
    check(queue.adjacent(to: third.id, direction: 1) == nil, "Queue end")
    queue.retain { $0 == third.id }
    check(queue.order == [third.id] && queue.original == [third.id], "Queue prunes unavailable tracks")

    check(queue.adjacent(to: first.id, direction: 1) == nil, "Pruned queue position removed")
    queue.replace([first.id, second.id, first.id, third.id], current: second.id, shuffled: false)
    check(queue.order == [first.id, second.id, third.id], "Queue deduplicates IDs")
    check(queue.adjacent(to: second.id, direction: Int.max) == nil, "Queue offset overflow rejected")
    check(queue.adjacent(to: second.id, direction: -1) == first.id, "Queue reverse lookup")
    queue.setShuffle(true, current: second.id)
    check(queue.adjacent(to: second.id, direction: 1) == queue.order[1], "Shuffle rebuilds position index")

    let index = LibraryIndex([first, second, third])
    check(index[first.id] == first && index.filter("ARTIST").count == 3, "Index and search")
    check(index.filter("", favoritesOnly: true) == [first], "Favorites")
    let searchResult = try index.search("ARTIST", category: .albums)
    check(searchResult.tracks == [first, second, third] && searchResult.groups.count == 3, "Value snapshot search")
    let noResults = try index.search("no matches", category: .songs)
    check(noResults.tracks.isEmpty && noResults.groups.isEmpty, "Empty search result")
    check(index.groups(category: .albums, query: "").count == 3, "Distinct untagged singles")
    let artistGroup = index.groups(category: .artists, query: "").first!
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
    let migratedEnvelope = try JSONDecoder().decode(LibraryRepository.Snapshot.self, from: Data(contentsOf: url))
    check(migratedEnvelope.schemaVersion == 2, "Legacy mutation writes schema 2")
    let backupBytes = try Data(contentsOf: backup)
    check(backupBytes == legacy, "Previous index preserved")
    let fresh = LibraryRepository(root: root)
    let migrated = try await fresh.load()
    check(migrated == [first, third], "Versioned reload")

    // Explicit version-one fixture must remain readable and preserve its bytes until mutation.
    let schemaOneRoot = root.appendingPathComponent("schema-one", isDirectory: true)
    try FileManager.default.createDirectory(at: schemaOneRoot, withIntermediateDirectories: true)
    let schemaOneIndex = schemaOneRoot.appendingPathComponent("library.json")
    let schemaOneBytes = try JSONEncoder().encode(LibraryRepository.Snapshot(schemaVersion: 1, tracks: [first]))
    try schemaOneBytes.write(to: schemaOneIndex)
    let schemaOneRepo = LibraryRepository(root: schemaOneRoot)
    let schemaOneTracks = try await schemaOneRepo.load()
    check(schemaOneTracks == [first] && schemaOneTracks[0].metadata == nil, "Schema one compatible")
    check(try Data(contentsOf: schemaOneIndex) == schemaOneBytes, "Opening does not rewrite schema one")
    try await schemaOneRepo.commit([collaboration])
    let metadataReload = try await LibraryRepository(root: schemaOneRoot).load()
    check(metadataReload == [collaboration], "Schema two preserves metadata and track identity")
    let versionOneBackup = try Data(contentsOf: schemaOneRoot.appendingPathComponent("library.previous.json"))
    check(versionOneBackup == schemaOneBytes, "Migration retains exact previous index bytes")
    let futureBackup = Data("{\"schemaVersion\":99,\"tracks\":[]}".utf8)
    try futureBackup.write(to: schemaOneRoot.appendingPathComponent("library.previous.json"))
    do { try await schemaOneRepo.commit([first]); fatalError("Future backup overwritten") } catch {}
    check(try Data(contentsOf: schemaOneRoot.appendingPathComponent("library.previous.json")) == futureBackup,
          "Future backup protected")

    var invalidDigest = first
    invalidDigest.contentHash = "not-a-digest"
    do { try await fresh.commit([invalidDigest]); fatalError("Malformed digest accepted") } catch {}
    var orphanArtworkDigest = second
    orphanArtworkDigest.artworkHash = String(repeating: "a", count: 64)
    do { try await fresh.commit([orphanArtworkDigest]); fatalError("Artwork checksum without artwork accepted") } catch {}
    var unsafe = first
    unsafe.file = "../outside.mp3"
    do { try await fresh.commit([unsafe]); fatalError("Unsafe path accepted") } catch {}
    do { try await fresh.commit([first, first]); fatalError("Duplicate ID accepted") } catch {}
    let unmodified = try await LibraryRepository(root: root).load()
    check(unmodified == [first, third], "Rejected writes preserve index")

    let media = root.appendingPathComponent("test.FLAC")
    try Data("abc".utf8).write(to: media)
    do { _ = try await fresh.discardImports([first]); fatalError("Referenced media removed") } catch {}
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
    do { _ = try await staleDelete.discardImports([first]); fatalError("Direct stale deletion accepted") } catch {}
    check(FileManager.default.fileExists(atPath: liveMedia.path), "Direct stale deletion preserves actual media")
    do { try await stale.commit([third]); fatalError("Stale write accepted") } catch {}
    do { _ = try await stale.discardImports([first]); fatalError("Stale deletion accepted") } catch {}
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
    check(report.tracks == 1 && report.canRestore && report.unverifiedMedia == 2, "Legacy recovery reports unverified media")
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
    do { _ = try await damagedRepo.discardImports([directoryTrack]); fatalError("Unsafe rollback accepted") }
    catch LibraryRepository.Failure.unsafeMedia {}
    check(FileManager.default.fileExists(atPath: folder.path), "Directory preserved")
    let linked = recoveryRoot.appendingPathComponent("link.mp3")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: audio)
    var linkTrack = third
    linkTrack.file = "link.mp3"
    do { _ = try await damagedRepo.discardImports([linkTrack]); fatalError("Unsafe rollback accepted") }
    catch LibraryRepository.Failure.unsafeMedia {}
    check(FileManager.default.fileExists(atPath: audio.path), "Symlink destination preserved")

    // Deletion must leave the previous snapshot restorable. A later successful
    // rotation may reclaim only known retired media, never unrelated files.
    let retentionRoot = root.appendingPathComponent("retention", isDirectory: true)
    let retention = LibraryRepository(root: retentionRoot)
    _ = try await retention.load()
    var hashed = first
    hashed.file = "\(hashed.id.uuidString).flac"
    hashed.artwork = "\(hashed.id.uuidString)-cover.jpg"
    let retainedFile = retentionRoot.appendingPathComponent(hashed.file)
    let retainedArt = retentionRoot.appendingPathComponent(hashed.artwork!)
    let unknown = retentionRoot.appendingPathComponent("unknown.mp3")
    try Data("audio".utf8).write(to: retainedFile)
    try Data("art".utf8).write(to: retainedArt)
    try Data("unknown".utf8).write(to: unknown)
    hashed.contentHash = try FileDigest.sha256(retainedFile)
    hashed.artworkHash = try FileDigest.sha256(retainedArt)
    try Data("replacement".utf8).write(to: retainedFile)
    let rollback = try await retention.discardImports([hashed])
    check(rollback == ["Retained modified media: \(hashed.file)"], "Rollback reports changed audio")
    check(try Data(contentsOf: retainedFile) == Data("replacement".utf8), "Rollback preserves replacement bytes")
    check(!FileManager.default.fileExists(atPath: retainedArt.path), "Rollback removes verified artwork")
    try Data("audio".utf8).write(to: retainedFile)
    try Data("art".utf8).write(to: retainedArt)
    try await retention.commit([hashed])
    try await retention.commit([])
    _ = try await retention.discardImports([hashed])
    check(FileManager.default.fileExists(atPath: retainedFile.path), "Previous snapshot retains deleted audio")
    let retentionIndex = retentionRoot.appendingPathComponent("library.json")
    let healthyBytes = try Data(contentsOf: retentionIndex)
    try Data("damaged".utf8).write(to: retentionIndex)
    try Data("wrong bytes".utf8).write(to: retainedFile)
    let recoverRetention = LibraryRepository(root: retentionRoot)
    let badAudioReport = try await recoverRetention.inspectRecovery()
    check(!badAudioReport.canRestore && badAudioReport.damagedMedia == 1, "Recovery preview detects changed audio")
    do { _ = try await recoverRetention.restorePreviousIndex(); fatalError("Checksum mismatch accepted") } catch {}
    check(try Data(contentsOf: retentionIndex) == Data("damaged".utf8), "Failed checksum recovery preserves index")
    try Data("audio".utf8).write(to: retainedFile)
    try Data("wrong artwork".utf8).write(to: retainedArt)
    let badArtReport = try await recoverRetention.inspectRecovery()
    check(!badArtReport.canRestore && badArtReport.damagedMedia == 1, "Recovery preview detects changed artwork")
    do { _ = try await recoverRetention.restorePreviousIndex(); fatalError("Artwork checksum mismatch accepted") } catch {}
    try Data("art".utf8).write(to: retainedArt)
    let verifiedReport = try await recoverRetention.inspectRecovery()
    check(verifiedReport.canRestore && verifiedReport.unverifiedMedia == 0, "Checksummed recovery verified")
    let recoveredRetention = try await recoverRetention.restorePreviousIndex()
    check(recoveredRetention == [hashed], "Deleted audio remains recoverable")
    try healthyBytes.write(to: retentionIndex, options: .atomic)
    let rotate = LibraryRepository(root: retentionRoot)
    _ = try await rotate.load()
    try await rotate.commit([third])
    check(!FileManager.default.fileExists(atPath: retainedFile.path), "Retired backup audio reclaimed")
    check(!FileManager.default.fileExists(atPath: retainedArt.path), "Retired backup artwork reclaimed")
    check(FileManager.default.fileExists(atPath: unknown.path), "Unknown media never reclaimed")

    // A retired index alone must never authorize deleting unrelated or replaced bytes.
    let guardedRoot = root.appendingPathComponent("guarded-retention", isDirectory: true)
    let guarded = LibraryRepository(root: guardedRoot)
    _ = try await guarded.load()
    var arbitrary = second
    arbitrary.file = "unrelated.mp3"
    let arbitraryURL = guardedRoot.appendingPathComponent(arbitrary.file)
    try Data("unrelated".utf8).write(to: arbitraryURL)
    arbitrary.contentHash = try FileDigest.sha256(arbitraryURL)
    var modified = third
    modified.file = "\(modified.id.uuidString).mp3"
    let modifiedURL = guardedRoot.appendingPathComponent(modified.file)
    try Data("original".utf8).write(to: modifiedURL)
    modified.contentHash = try FileDigest.sha256(modifiedURL)
    var legacyArt = first
    legacyArt.file = "\(legacyArt.id.uuidString).flac"
    legacyArt.artwork = "\(legacyArt.id.uuidString)-cover.jpg"
    let legacyAudioURL = guardedRoot.appendingPathComponent(legacyArt.file)
    let legacyArtURL = guardedRoot.appendingPathComponent(legacyArt.artwork!)
    try Data("legacy audio".utf8).write(to: legacyAudioURL)
    try Data("legacy artwork".utf8).write(to: legacyArtURL)
    try await guarded.commit([arbitrary, modified, legacyArt])
    try await guarded.commit([])
    try Data("replacement".utf8).write(to: modifiedURL)
    // Rotate with a truly unrelated track. Reusing hashed here would reuse
    // legacyArt's identity and both filenames, correctly protecting them
    // from retirement and invalidating the four-diagnostic expectation.
    let unrelatedNext = Track(file: "\(UUID().uuidString).wav", title: "Next",
                              artist: "Artist", album: "Album", duration: 1)
    let retainedDiagnostics = try await guarded.commit([unrelatedNext])
    let expectedDiagnostics: Set<String> = [
        "Retained unverified media: \(arbitrary.file)",
        "Retained modified media: \(modified.file)",
        "Retained unverified media: \(legacyArt.file)",
        "Retained unverified media: \(legacyArt.artwork!)"
    ]
    check(retainedDiagnostics.count == expectedDiagnostics.count &&
          Set(retainedDiagnostics) == expectedDiagnostics,
          "Unverified and replaced media reported: \(retainedDiagnostics)")
    check(try Data(contentsOf: arbitraryURL) == Data("unrelated".utf8), "Non-managed name preserved even with digest")
    check(try Data(contentsOf: modifiedURL) == Data("replacement".utf8), "Changed managed bytes preserved")
    check(FileManager.default.fileExists(atPath: legacyAudioURL.path), "Legacy audio without checksum preserved")
    check(FileManager.default.fileExists(atPath: legacyArtURL.path), "Legacy artwork without checksum preserved")

    // Explicitly exercise the complementary case: retired media reused by a
    // new current snapshot is protected, even if its old record was unhashed.
    let reusedRoot = root.appendingPathComponent("reused-retention", isDirectory: true)
    let reused = LibraryRepository(root: reusedRoot)
    _ = try await reused.load()
    let reusedAudio = reusedRoot.appendingPathComponent(legacyArt.file)
    let reusedArt = reusedRoot.appendingPathComponent(legacyArt.artwork!)
    try Data("reused audio".utf8).write(to: reusedAudio)
    try Data("reused artwork".utf8).write(to: reusedArt)
    try await reused.commit([legacyArt])
    try await reused.commit([])
    var reusedTrack = legacyArt
    reusedTrack.contentHash = try FileDigest.sha256(reusedAudio)
    reusedTrack.artworkHash = try FileDigest.sha256(reusedArt)
    let reusedDiagnostics = try await reused.commit([reusedTrack])
    check(reusedDiagnostics.isEmpty, "Current references must not enter retired cleanup")
    check(try Data(contentsOf: reusedAudio) == Data("reused audio".utf8),
          "Reintroduced audio preserved")
    check(try Data(contentsOf: reusedArt) == Data("reused artwork".utf8),
          "Reintroduced artwork preserved")

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
    check(reloaded == large && indexed.positionByID.count == 10_000, "10k track round trip")
    check(indexed.filter("", favoritesOnly: true).count == 1_000, "10k track favorites")
    check(indexed.groups(category: .artists, query: "").count == 100, "10k artist groups")
    for category in LibraryCategory.allCases {
        let unfiltered = try indexed.search("", category: category)
        check(unfiltered.tracks == large, "Empty search preserves track order")
        check(unfiltered.groups.map(\.id) == indexed.groups(category: category, query: "").map(\.id),
              "Empty search preserves cached group ordering")
    }
    let searchStart = ContinuousClock.now
    let largeResults = try indexed.search("Artist 42", category: .albums)
    check(largeResults.tracks.count == 100, "10k snapshot search")
    print("10k metadata search: \(ContinuousClock.now - searchStart) (host only)")
    print("10k metadata fixture commit/reload/index: \(Date().timeIntervalSince(started)) seconds (host only)")
    print("PASS: storage, migration, independent stale deletion, explicit recovery, path guards, 10k fixture, queue, index, digest")
}
try await runTests()
