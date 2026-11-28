"""Select or create a simulator for Aural's supported device families."""
import json
import re
import subprocess
import sys


TARGETS = {
    "iPhone": ("iPhone 15 Pro Max", "Pro Max"),
    "iPad": ("iPad Pro (12.9-inch) (5th generation)", "iPad Pro 13-inch"),
}


def select(family, inventory, create):
    preferred, fallback = TARGETS[family]
    type_id = next((item["identifier"] for item in inventory["devicetypes"]
                    if item["name"] == preferred), None)
    candidates = []
    runtimes = []
    for runtime in inventory["runtimes"]:
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?",
                             runtime["identifier"])
        if not match or not runtime["isAvailable"]:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (26, 1, 0):
            continue
        runtimes.append((version, runtime["identifier"]))
        for device in inventory["devices"].get(runtime["identifier"], []):
            if not device["isAvailable"]:
                continue
            name = device["name"]
            exact = name == preferred or (type_id is not None and device.get("deviceTypeIdentifier") == type_id)
            if exact or name.startswith(family):
                candidates.append((exact, fallback in name, version, name, device["udid"]))

    if candidates and max(candidates)[0]:
        _, _, version, name, identifier = max(candidates)
        return version, name, identifier
    if type_id:
        for version, runtime in sorted(runtimes, reverse=True):
            identifier = create(preferred, type_id, runtime)
            if identifier:
                return version, preferred, identifier
    if candidates:
        _, _, version, name, identifier = max(candidates)
        return version, name, identifier
    raise SystemExit(f"No compatible {family} simulator on iOS 26.1 or newer")


def create_device(name, type_id, runtime):
    result = subprocess.run(["xcrun", "simctl", "create", name, type_id, runtime],
                            capture_output=True, text=True)
    if result.returncode:
        print(f"Could not create {name} on {runtime}: {result.stderr.strip()}", file=sys.stderr)
        return None
    return result.stdout.strip()


def main():
    family = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
    if family not in TARGETS:
        raise SystemExit("Expected iPhone or iPad")
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True))
    version, model, identifier = select(family, inventory, create_device)
    print(f"Selected {model} on iOS {'.'.join(map(str, version))}", file=sys.stderr)
    print(identifier)


if __name__ == "__main__":
    main()
