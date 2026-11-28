"""Check the named XCTest evidence before uploading a successful simulator run."""
import json
import sys
from pathlib import Path

REQUIRED = {
    "Album detail", "Albums", "Artist detail", "Artists", "Favorites",
    "Landscape library", "Native Library and Mini Player", "Native Now Playing",
    "Search results", "Settings",
}


def missing_captures(directory):
    found = set()
    for group in json.loads((directory / "manifest.json").read_text()):
        for attachment in group["attachments"]:
            file = directory / attachment["exportedFileName"]
            if file.suffix == ".png" and file.is_file() and not attachment["isAssociatedWithFailure"]:
                name = attachment["suggestedHumanReadableName"].rsplit("_", 2)[0]
                found.add(name)
    return REQUIRED - found


if __name__ == "__main__":
    missing = missing_captures(Path(sys.argv[1]))
    if missing:
        raise SystemExit("Missing simulator screenshots: " + ", ".join(sorted(missing)))
