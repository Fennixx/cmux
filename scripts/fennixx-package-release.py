#!/usr/bin/env python3
"""Package an already built Fennixx app; sign the DMG using the macOS Keychain.

Does not publish, modify an installed app, export private keys, or weaken Gatekeeper.
The output directory must be new so signed release assets cannot be overwritten.
"""
import argparse
import datetime
import hashlib
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET

REPO = "https://github.com/Fennixx/cmux"
FEED = REPO + "/releases/latest/download/appcast.xml"
KEY_ACCOUNT = "com.fennixx.cmux.releases-2026"
PUBLIC_KEY = "ArwLK36PA1CbGMywuKoc+UidFdRSrtzmfWQwab+nv/8="
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def validate_info(info, tag):
    expected = {
        "CFBundleIdentifier": "com.fennixx.cmux",
        "CFBundleName": "Fennixx CMUX",
        "SUFeedURL": FEED,
        "SUPublicEDKey": PUBLIC_KEY,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected {key}; refusing to ship the wrong app/update channel")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or tag != "v" + version:
        raise ValueError("Tag must match the app marketing version")
    if not str(info.get("CFBundleVersion", "")).isdigit():
        raise ValueError("App build number must be numeric")
    if not info.get("LSMinimumSystemVersion"):
        raise ValueError("Minimum macOS version is missing")


def make_appcast(info, tag, asset_name, size, signature):
    validate_info(info, tag)
    if size <= 0 or not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise ValueError("Invalid archive size or Ed25519 signature")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Fennixx CMUX updates"
    ET.SubElement(channel, "link").text = REPO
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Fennixx CMUX " + info["CFBundleShortVersionString"]
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    ET.SubElement(item, "description").text = "Mac-to-Mac Tailscale pairing and persistent Claude Code / Codex sessions. This release starts a new signing key; older Fennixx installations require a one-time manual install. Apple Silicon only. Not Apple-notarized."
    for key, value in {
        "version": info["CFBundleVersion"],
        "shortVersionString": info["CFBundleShortVersionString"],
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
        "hardwareRequirements": "arm64",
    }.items():
        ET.SubElement(item, "{" + SPARKLE + "}" + key).text = str(value)
    ET.SubElement(item, "enclosure", {
        "url": REPO + "/releases/download/" + tag + "/" + asset_name,
        "length": str(size),
        "type": "application/octet-stream",
        "{" + SPARKLE + "}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    validate_info(info, args.tag)
    run = subprocess.run
    public = run([str(args.sparkle_bin / "generate_keys"), "--account", KEY_ACCOUNT, "-p"], check=True, capture_output=True, text=True).stdout.strip()
    if public != PUBLIC_KEY:
        raise ValueError("Signing key does not match the app's public key")
    run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for binary in [app / "Contents/MacOS" / info["CFBundleExecutable"], app / "Contents/Resources/machine/bin/cmux-machine", app / "Contents/Resources/machine/bin/tmux"]:
        run(["lipo", "-verify_arch", "arm64", str(binary)], check=True)
    out = args.out.resolve()
    out.mkdir(parents=False, exist_ok=False)
    dmg = out / "cmux-macos.dmg"
    with tempfile.TemporaryDirectory(prefix="fennixx-dmg-") as staging:
        stage = Path(staging)
        run(["ditto", str(app), str(stage / "Fennixx CMUX.app")], check=True)
        (stage / "Applications").symlink_to("/Applications")
        run(["hdiutil", "create", "-volname", "Fennixx CMUX", "-srcfolder", str(stage), "-format", "UDZO", str(dmg)], check=True)
    signature = run([str(args.sparkle_bin / "sign_update"), "--account", KEY_ACCOUNT, "-p", str(dmg)], check=True, capture_output=True, text=True).stdout.strip()
    run([str(args.sparkle_bin / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(dmg), signature], check=True)
    (out / "appcast.xml").write_bytes(make_appcast(info, args.tag, dmg.name, dmg.stat().st_size, signature))
    with dmg.open("rb") as file:
        checksum = hashlib.file_digest(file, "sha256").hexdigest()
    (out / "SHA256SUMS.txt").write_text(f"{checksum}  {dmg.name}\n")
    print(f"Verified update archive and appcast: {out}")


if __name__ == "__main__":
    main()
