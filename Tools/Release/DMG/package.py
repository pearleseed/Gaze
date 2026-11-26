#!/usr/bin/env python3
"""Package an existing signed Gaze app with a Retina Finder background.

Staged root shows exactly two icons -- Gaze.app left, Applications symlink
right -- over the Pro Black supreme drag background (top dotted-pill motif
with blue glow, bold double-chevron arrow + white "Drag Gaze to
Applications" caption, graphite label lifts). LICENSE/README never ship
at the root; if ever added they belong in a docs subfolder so the root
still shows two icons."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
EXPECTED_BUNDLE_IDENTIFIER = "com.pearleseed.Gaze"


def run(*command, capture=False, env=None):
    result = subprocess.run(command, check=True, capture_output=capture, env=env)
    return result.stdout if capture else None


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify_image(image, executable_hash):
    from ds_store import DSStore

    from artwork import ICON_LOCATIONS, ICON_SIZE

    run("/usr/bin/hdiutil", "verify", str(image))
    with tempfile.TemporaryDirectory(prefix="gaze-dmg-mount-") as scratch:
        mount = Path(scratch) / "volume"
        mounted = False
        try:
            run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", str(mount), str(image))
            mounted = True
            app = mount / "Gaze.app"
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
            if digest(app / "Contents/MacOS/Gaze") != executable_hash:
                raise RuntimeError("The packaged executable differs from the input app")
            if os.readlink(mount / "Applications") != "/Applications":
                raise RuntimeError("Applications shortcut has the wrong target")
            visible = {p.name for p in mount.iterdir() if not p.name.startswith(".")}
            if visible != {"Gaze.app", "Applications"}:
                raise RuntimeError(f"Unexpected visible files: {sorted(visible)}")
            if not (mount / ".DS_Store").is_file():
                raise RuntimeError("Pinned Finder layout missing: .DS_Store was not written")
            with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                view = store["."]["icvp"]
                window = store["."]["bwsp"]
                if view["backgroundType"] != 2 or view["iconSize"] != ICON_SIZE:
                    raise RuntimeError("Finder background or icon size was not saved")
                if window["ShowSidebar"] or window["ShowToolbar"]:
                    raise RuntimeError("Unexpected Finder sidebar or toolbar")
                for name, position in ICON_LOCATIONS.items():
                    if tuple(store[name]["Iloc"]) != position:
                        raise RuntimeError(f"Wrong Finder position for {name}")
            background_image = mount / ".background.tiff"
            if not background_image.is_file() or background_image.stat().st_size == 0:
                raise RuntimeError("Pro Black Retina background missing; refusing white fallback")
        finally:
            if mounted:
                run("/usr/bin/hdiutil", "detach", str(mount))


def detect_signing_authority(app, require_developer_id):
    signature = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
        capture_output=True, text=True, check=True,
    ).stderr
    dev_id = next(
        (line.removeprefix("Authority=") for line in signature.splitlines()
         if line.startswith("Authority=Developer ID Application: ")),
        None,
    )
    if require_developer_id:
        if not dev_id:
            raise RuntimeError("Notarized release requires a Developer ID Application-signed app")
        return dev_id
    apple_dev = next(
        (line.removeprefix("Authority=") for line in signature.splitlines()
         if line.startswith("Authority=Apple Development: ")),
        None,
    )
    return dev_id or apple_dev or "-"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), help="Required for release packaging")
    parser.add_argument("--app", type=Path, help="Input app bundle. Defaults to the build for --arch")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/installers")
    parser.add_argument("--local-preview", action="store_true",
                        help="Create a local design candidate; not a cleared distribution build")
    parser.add_argument("--notary-profile",
                        help="Optional keychain profile for Apple notarization; omit for un-notarized release DMG")
    args = parser.parse_args()
    if not args.local_preview and not args.arch:
        parser.error("Select --arch arm64 (Apple Silicon) or --arch x86_64 (Intel)")
    if args.local_preview and args.notary_profile:
        parser.error("--notary-profile cannot be combined with --local-preview")
    default_app = ROOT / "build/release" / args.arch / "Gaze.app" if args.arch else ROOT / "build/Gaze.app"
    app = (args.app or default_app).resolve()
    if not app.is_dir():
        parser.error(f"Missing app bundle: {app}")
    if app.name != "Gaze.app":
        parser.error("The input app must be named Gaze.app")
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if metadata.get("CFBundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER:
        parser.error(f"Unexpected app bundle identifier; expected {EXPECTED_BUNDLE_IDENTIFIER}")
    binary = app / "Contents/MacOS/Gaze"
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    architecture = run("/usr/bin/lipo", "-archs", str(binary), capture=True).decode().strip()
    if args.arch and architecture != args.arch:
        parser.error(f"Expected only {args.arch}, found {architecture}")
    version = metadata["CFBundleShortVersionString"]
    build = metadata["CFBundleVersion"]
    for value in (version, build):
        if not value or any(c not in "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-" for c in value):
            parser.error("Version or build contains characters unsuitable for a filename")

    authority = None
    notarize = bool(args.notary_profile)
    if not args.local_preview:
        run("python3", str(ROOT / "Tools/Release/ModelClearance/validate.py"))
        verify_env = {
            **os.environ,
            "GAZE_ARCHS": args.arch,
            "GAZE_REQUIRE_DEVELOPER_ID": "1" if notarize else "0",
        }
        run("bash", str(ROOT / "Tools/Release/verify.sh"), str(app), env=verify_env)
        authority = detect_signing_authority(app, require_developer_id=notarize)

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    suffix = "-local-preview" if args.local_preview else ""
    image = output_dir / f"Gaze-{version}-{build}-{architecture.replace(' ', '-')}{suffix}.dmg"
    if image.exists():
        parser.error(f"Output already exists; choose a fresh --output-dir: {image}")

    import dmgbuild

    from artwork import ICON_LOCATIONS, ICON_SIZE, WINDOW_SIZE, render

    artwork_dir = output_dir / f"artwork-{architecture.replace(' ', '-')}"
    render(artwork_dir)
    # Retina source carries the Pro Black supreme art (motif + bold arrow +
    # white caption); fail rather than shipping a white/empty fallback.
    background = artwork_dir / "background.png"
    for candidate in (background, artwork_dir / "background@2x.png"):
        if not candidate.is_file() or candidate.stat().st_size == 0:
            raise RuntimeError(f"Pro Black background missing: {candidate}; refusing fallback")
    executable_hash = digest(binary)

    def check_copied_app(mount_point, _options):
        copied = Path(mount_point) / "Gaze.app"
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied))
        if digest(copied / "Contents/MacOS/Gaze") != executable_hash:
            raise RuntimeError("App copy failed; refusing to finish the DMG")

    # Root stages exactly Gaze.app + Applications; docs (LICENSE/README) stay
    # out of the root so Finder keeps the two-icon drag layout. Window size,
    # icon positions, icon size and text size below match the supreme art in
    # artwork.py (imported, not forked) so the layout survives remount; verify_image re-checks them on mount.
    settings = {
        "format": "UDZO", "filesystem": "HFS+", "compression_level": 9,
        "files": [str(app)], "symlinks": {"Applications": "/Applications"},
        "background": str(background),
        "window_rect": ((180, 140), WINDOW_SIZE),
        "icon_locations": ICON_LOCATIONS, "icon_size": ICON_SIZE, "text_size": 13,
        "default_view": "icon-view", "include_list_view_settings": False,
        "show_status_bar": False, "show_tab_view": False, "show_toolbar": False,
        "show_pathbar": False, "show_sidebar": False,
        "show_icon_preview": False, "show_item_info": False,
        "arrange_by": None, "create_hook": check_copied_app,
    }
    icon = app / "Contents/Resources/AppIcon.icns"
    if icon.is_file():
        settings["badge_icon"] = str(icon)
    elif not args.local_preview:
        parser.error("Release DMG requires Contents/Resources/AppIcon.icns for the volume icon")

    with tempfile.TemporaryDirectory(prefix=".gaze-package-", dir=output_dir) as scratch:
        staged = Path(scratch) / image.name
        print("Creating Gaze disk image…", flush=True)
        # A unique volume name per build. Finder finds the background through an alias
        # that names the volume; if an older "Gaze" disk is still mounted, this one
        # mounts as "Gaze 1", the alias resolves to the old disk and the window opens
        # white. It also stops Finder reusing a cached window from a previous build.
        volume = f"Gaze {version} {architecture} ({time.strftime('%m%d-%H%M')})"
        dmgbuild.build_dmg(str(staged), volume, settings=settings)
        verify_image(staged, executable_hash)
        if not args.local_preview and authority:
            sign_cmd = ["/usr/bin/codesign", "--sign", authority]
            if authority.startswith("Developer ID Application: "):
                sign_cmd.append("--timestamp")
            sign_cmd.append(str(staged))
            try:
                run(*sign_cmd)
            except subprocess.CalledProcessError as exc:
                raise RuntimeError(f"DMG signing failed: {exc}") from exc
            run("/usr/bin/codesign", "--verify", "--strict", str(staged))
            if notarize:
                signature = subprocess.run(
                    ["/usr/bin/codesign", "-dv", "--verbose=4", str(staged)],
                    capture_output=True, text=True, check=True,
                ).stderr
                if "Authority=Developer ID Application: " not in signature:
                    raise RuntimeError("DMG signature is not Developer ID Application; no image written")
                if "Timestamp=" not in signature:
                    raise RuntimeError("DMG signature has no secure timestamp; no image written")
                try:
                    result = json.loads(run(
                        "xcrun", "notarytool", "submit", str(staged),
                        "--keychain-profile", args.notary_profile,
                        "--wait", "--output-format", "json", capture=True,
                    ))
                except subprocess.CalledProcessError as exc:
                    raise RuntimeError(f"Notarization submit failed; check --notary-profile: {exc}") from exc
                if result.get("status") != "Accepted":
                    raise RuntimeError(f"Notarization was not accepted: {result.get('id')}")
                try:
                    run("xcrun", "stapler", "staple", str(staged))
                    run("xcrun", "stapler", "validate", str(staged))
                except subprocess.CalledProcessError as exc:
                    raise RuntimeError(f"Notarization staple failed; no image written: {exc}") from exc
                run("/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                    "context:primary-signature", "--verbose=2", str(staged))
        staged.rename(image)

    if args.local_preview:
        label = "LOCAL PREVIEW — not cleared for sharing"
        verification = "Image checksum, mounted app signature and executable hash, Applications link, Finder layout and Retina background passed (local preview)"
    elif notarize:
        label = "NOTARIZED DMG"
        verification = "Image checksum, mounted app signature and executable hash, Applications link, Finder layout, Retina background, DMG signature and notarization passed"
    else:
        label = "UN-NOTARIZED RELEASE DMG"
        verification = "Image checksum, mounted app signature and executable hash, Applications link, Finder layout, Retina background and DMG signature passed (un-notarized)"

    checksum = digest(image)
    (output_dir / (image.name + ".sha256")).write_text(f"{checksum}  {image.name}\n")
    receipt = {
        "createdUTC": datetime.now(timezone.utc).isoformat(), "dmg": str(image),
        "sha256": checksum, "bytes": image.stat().st_size,
        "app": str(app), "executableSHA256": executable_hash,
        "bundleIdentifier": metadata["CFBundleIdentifier"],
        "version": version, "build": build, "architecture": architecture,
        "minimumMacOS": metadata["LSMinimumSystemVersion"],
        "notarized": notarize,
        "signingAuthority": "unsigned" if args.local_preview else ("ad-hoc" if authority == "-" else authority),
        "distributionReady": not args.local_preview,
        "verification": verification,
        "visualInspection": "Background artwork only; live Finder appearance not checked by this script",
    }
    (output_dir / (image.name + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{label}: {image}")


if __name__ == "__main__":
    main()
