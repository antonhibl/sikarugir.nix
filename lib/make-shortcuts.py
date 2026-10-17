"""
Creates (or refreshes) one small macOS .app per programs.sikarugir.shortcuts
entry. Each one opens a Steam game inside a Sikarugir instance.

usage: make-shortcuts.py <instancesDirectory> <spec.json>

spec.json is a list of objects:
  {"name": ..., "instance": ..., "steamAppId": ..., "icon": path-or-null}

How a shortcut works: the instance gets a Windows Internet Shortcut file
(steam://rungameid/<id>) inside its drive_c, and the shortcut app's
executable just runs `open -a <instance>.app <that .url>`. The Sikarugir
launcher opens it with Windows Steam, starting Steam first if it isn't
running, or handing it to the running copy if it is.

Icons are worked out at activation time (they come from the instance's
own Steam install, so they can't be known at build time). In order:
  1. the `icon` option, if set;
  2. the game's .ico that Steam uses for its own desktop shortcuts, if
     it's at least 128px;
  3. the game's library cover art (library_600x900.jpg), cropped square;
  4. the .ico or Steam's small library icon, however small;
  5. no icon (macOS shows a generic app icon).
"""

from __future__ import annotations

import glob
import json
import os
import plistlib
import re
import shlex
import sys
from pathlib import Path

from PIL import Image, ImageDraw

MARKER = "sikarugir-nix-shortcut"
ICON_CANVAS = 1024
# Apple's icon grid: the rounded square is 824px on a 1024px canvas.
ICON_BODY = 824
ICON_RADIUS = 185


def steam_dir(drive_c: Path) -> Path | None:
    for candidate in ("Program Files (x86)/Steam", "Program Files/Steam"):
        p = drive_c / candidate
        if p.is_dir():
            return p
    return None


def windows_to_drive_c(drive_c: Path, win_path: str) -> Path | None:
    m = re.match(r"^[A-Za-z]:\\(.*)$", win_path.strip())
    if not m:
        return None
    return drive_c / m.group(1).replace("\\", "/")


def largest_frame(path: Path) -> Image.Image | None:
    try:
        im = Image.open(path)
        if path.suffix.lower() == ".ico":
            sizes = im.info.get("sizes") or {im.size}
            biggest = max(sizes, key=lambda s: s[0] * s[1])
            im.size = biggest  # selects that frame in Pillow's ICO plugin
        im.load()
        return im.convert("RGBA")
    except Exception as exc:  # noqa: BLE001 - a bad icon must never fail activation
        print(f"    (couldn't read icon {path}: {exc})", file=sys.stderr)
        return None


def steam_shortcut_ico(drive_c: Path, app_id: int) -> Path | None:
    """The .ico Steam itself points its desktop shortcuts at, if one exists."""
    for url in glob.glob(str(drive_c / "users" / "*" / "Desktop" / "*.url")):
        try:
            text = Path(url).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not re.search(rf"steam://rungameid/{app_id}\b", text):
            continue
        m = re.search(r"^ICONFILE=(.+)$", text, re.MULTILINE)
        if m:
            ico = windows_to_drive_c(drive_c, m.group(1))
            if ico and ico.is_file():
                return ico
    return None


def square_crop(im: Image.Image) -> Image.Image:
    side = min(im.size)
    left = (im.width - side) // 2
    # Cover art usually has the title near the top; crop from the upper part.
    top = max(0, min((im.height - side) // 3, im.height - side))
    return im.crop((left, top, left + side, top + side))


def pick_icon(drive_c: Path, app_id: int, override: str | None) -> tuple[Image.Image, bool] | None:
    """Returns (image, is_pixel_art_small) or None."""
    if override:
        im = largest_frame(Path(override))
        if im:
            return im, im.width < 128

    steam = steam_dir(drive_c)
    ico_path = steam_shortcut_ico(drive_c, app_id)
    ico = largest_frame(ico_path) if ico_path else None
    if ico and ico.width >= 128:
        return ico, False

    if steam:
        cover = steam / "appcache" / "librarycache" / str(app_id) / "library_600x900.jpg"
        if cover.is_file():
            im = largest_frame(cover)
            if im:
                return square_crop(im), False

    if ico:
        return ico, True
    if steam:
        for f in glob.glob(str(steam / "appcache" / "librarycache" / str(app_id) / "*.jpg")):
            if re.fullmatch(r"[0-9a-f]{40}\.jpg", os.path.basename(f)):
                im = largest_frame(Path(f))
                if im:
                    return im, True
    return None


def render_icon(im: Image.Image, small: bool) -> Image.Image:
    body = im.resize(
        (ICON_BODY, ICON_BODY),
        Image.Resampling.NEAREST if small else Image.Resampling.LANCZOS,
    )
    mask = Image.new("L", (ICON_BODY, ICON_BODY), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, ICON_BODY - 1, ICON_BODY - 1), radius=ICON_RADIUS, fill=255
    )
    src_alpha = body.getchannel("A")
    coverage = sum(i * n for i, n in enumerate(src_alpha.histogram())) / (255 * ICON_BODY * ICON_BODY)
    if coverage < 0.85:
        # Mostly transparent (a bare glyph or logo): put it on a light plate,
        # or it can disappear against a dark Dock or Finder background.
        plate = Image.new("RGBA", body.size, (242, 242, 245, 255))
        inset = Image.new("RGBA", body.size, (0, 0, 0, 0))
        glyph = body.resize((int(ICON_BODY * 0.8),) * 2, Image.Resampling.LANCZOS)
        off = (ICON_BODY - glyph.width) // 2
        inset.paste(glyph, (off, off), glyph)
        body = Image.alpha_composite(plate, inset)
        src_alpha = body.getchannel("A")
    # Keep the source's own transparency inside the rounded square.
    alpha = Image.composite(src_alpha, Image.new("L", body.size, 0), mask)
    body.putalpha(alpha)
    canvas = Image.new("RGBA", (ICON_CANVAS, ICON_CANVAS), (0, 0, 0, 0))
    off = (ICON_CANVAS - ICON_BODY) // 2
    canvas.paste(body, (off, off), body)
    return canvas


def bundle_id(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-") or "game"
    return f"com.sikarugir.shortcut.{slug}"


def make_shortcut(dest: Path, spec: dict) -> None:
    name, instance, app_id = spec["name"], spec["instance"], int(spec["steamAppId"])
    instance_app = dest / f"{instance}.app"
    drive_c = instance_app / "Contents" / "drive_c"
    app = dest / f"{name}.app"

    if app.exists() and not (app / "Contents" / "Resources" / MARKER).exists():
        print(f"sikarugir-nix: {app} exists but wasn't made by this module; leaving it alone", file=sys.stderr)
        return

    # The Windows Internet Shortcut the launcher is handed.
    url_dir = drive_c / "sikarugir-nix-shortcuts"
    url_file = url_dir / f"{app_id}.url"
    if drive_c.is_dir():
        url_dir.mkdir(exist_ok=True)
        url_file.write_text(f"[InternetShortcut]\r\nURL=steam://rungameid/{app_id}\r\n", encoding="utf-8")
    else:
        print(f"    warning: {instance_app} has no drive_c yet; {name} will work once it does", file=sys.stderr)

    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / MARKER).write_text(f"{instance} {app_id}\n")

    launch = contents / "MacOS" / "launch"
    missing = f"{instance}.app isn't in {dest}. Run home-manager switch, or check programs.sikarugir.instances."
    launch.write_text(
        "#!/bin/sh\n"
        f"# Opens {name} (Steam app {app_id}) in {instance}.app. Made by sikarugir-nix.\n"
        f"APP={shlex.quote(str(instance_app))}\n"
        f"URL={shlex.quote(str(url_file))}\n"
        'if [ ! -d "$APP" ] || [ ! -f "$URL" ]; then\n'
        f"  /usr/bin/osascript -e {shlex.quote(f'display alert {json.dumps(name)} message {json.dumps(missing)}')}\n"
        "  exit 1\n"
        "fi\n"
        'exec /usr/bin/open -a "$APP" "$URL"\n'
    )
    launch.chmod(0o755)

    info = {
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleIdentifier": bundle_id(name),
        "CFBundleExecutable": "launch",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSApplicationCategoryType": "public.app-category.games",
        # It only hands off to the instance and exits, so no Dock icon of its
        # own; it can still be pinned to the Dock.
        "LSUIElement": True,
    }

    icns = resources / "icon.icns"
    picked = pick_icon(drive_c, app_id, spec.get("icon"))
    if picked:
        render_icon(*picked).save(icns, format="ICNS")
        info["CFBundleIconFile"] = "icon"
    elif icns.exists():
        icns.unlink()

    with open(contents / "Info.plist", "wb") as f:
        plistlib.dump(info, f)

    # Nudge Finder/Dock to pick up a changed icon.
    os.utime(app, None)
    print(f"==> {name}.app opens Steam app {app_id} in {instance}.app{'' if picked else ' (no icon found)'}")


def main() -> int:
    dest, spec_path = Path(sys.argv[1]), Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    for spec in json.loads(spec_path.read_text()):
        try:
            make_shortcut(dest, spec)
        except Exception as exc:  # noqa: BLE001 - one bad shortcut mustn't stop the rest
            print(f"sikarugir-nix: couldn't make shortcut {spec.get('name')!r}: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
