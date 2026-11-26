import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let original = Track(file: "test.FLAC", title: "Song", artist: "Artist", album: "Album", duration: 123.5, favorite: true, artwork: "cover.png")
let data = try JSONEncoder().encode([original])
let decoded = try JSONDecoder().decode([Track].self, from: data)
check(decoded == [original], "Library JSON round-trip must preserve all fields and IDs")
check(decoded[0].format == "FLAC", "File extension should normalize to uppercase")
let withoutArtwork = Track(file: "test.mp3", title: "Song", artist: "Artist", album: "Album", duration: 1)
let decodedWithoutArtwork = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(withoutArtwork))
check(decodedWithoutArtwork.artwork == nil && !decodedWithoutArtwork.favorite, "Optional artwork and default favorite must survive storage")
check(decodedWithoutArtwork.format == "MP3", "MP3 format detection")
print("PASS: track model, identity, library serialization, defaults, format labels")
