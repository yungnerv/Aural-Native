"""Choose an available iPhone from the installed iOS simulator runtimes."""
import json
import re
import subprocess
import sys


def main():
    family = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    if family not in ("iPhone", "iPad"):
        raise SystemExit("Expected iPhone or iPad")
    result = subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        text=True,
    )
    devices = json.loads(result)["devices"]
    candidates = []
    for runtime, entries in devices.items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (26, 1, 0):
            continue
        for entry in entries:
            if entry.get("isAvailable") and entry["name"].startswith(family):
                candidates.append((version, entry["name"], entry["udid"]))
    if not candidates:
        raise SystemExit(f"No available {family} simulator on iOS 26.1 or newer")
    print(sorted(candidates, reverse=True)[0][2])


if __name__ == "__main__":
    main()
