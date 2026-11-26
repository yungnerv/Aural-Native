"""Validate and package an unsigned iOS app without shell-generated archive names."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile
import zipfile

BUNDLE_ID = "local.aural.player"


def validate(app, version, build):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid release version")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Invalid build number")
    if not app.is_dir() or app.name != "Aural.app":
        raise ValueError("Expected Aural.app directory")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundleExecutable": "Aural",
    }
    for key, value in expected.items():
        actual = info.get(key)
        print(f"{key}: {actual!r} (expected {value!r})")
        if actual != value:
            raise ValueError(f"Bundle verification failed: {key}")
    executable = app / "Aural"
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("Missing or invalid app executable")
    if not executable.stat().st_size or not executable.stat().st_mode & 0o111:
        raise ValueError("App executable is empty or not executable")


def write_archive(app, destination):
    # Preserve Unix file modes, including executable bits, and symlink entries.
    # Do not follow directory symlinks or include files outside the app bundle.
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=6, allowZip64=True) as archive:
        for root, dirs, files in os.walk(app, followlinks=False):
            base = Path(root)
            for path in sorted([base / name for name in dirs + files]):
                member = "Payload/Aural.app/" + path.relative_to(app).as_posix()
                if path.is_symlink():
                    target = os.readlink(path)
                    if os.path.isabs(target) or not (path.parent / target).resolve().is_relative_to(app.resolve()):
                        raise ValueError(f"Unsafe bundle symlink: {member}")
                    entry = zipfile.ZipInfo(member)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, target)
                else:
                    archive.write(path, member)
            dirs[:] = sorted(name for name in dirs if not (base / name).is_symlink())
    with zipfile.ZipFile(destination) as archive:
        damaged = archive.testzip()
        if damaged is not None:
            raise ValueError(f"Damaged archive entry: {damaged}")
        required = {"Payload/Aural.app/Aural", "Payload/Aural.app/Info.plist"}
        if not required.issubset(archive.namelist()):
            raise ValueError("Archive is missing essential bundle files")


def package(app, output, version, build, commit):
    validate(app, version, build)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid Git commit SHA")
    output.mkdir(parents=True, exist_ok=True)
    name = f"Aural-{version}-build-{build}-unsigned.ipa"
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output) as tmp:
        staging = Path(tmp)
        ipa = staging / name
        write_archive(app, ipa)
        with ipa.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        (staging / "SHA256SUMS.txt").write_text(f"{digest}  {name}\n", encoding="utf-8")
        (staging / "BUILD.txt").write_text(
            f"Version: {version}\nBuild: {build}\nCommit: {commit}\nUnsigned: yes\n",
            encoding="utf-8",
        )
        for filename in (name, "SHA256SUMS.txt", "BUILD.txt"):
            os.replace(staging / filename, output / filename)
    print(f"Verified unsigned IPA: {output / name}")
    return output / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    package(args.app, args.output, args.version, args.build, args.commit)


if __name__ == "__main__":
    main()
