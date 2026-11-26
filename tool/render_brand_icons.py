"""Export StickRemote's vector master. Requires librsvg, PyGObject, Cairo and ImageMagick."""
import io
import json
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import cairo
import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets/branding/stickremote.svg"
ANDROID = ROOT / "android/app/src/main/res"
IOS = ROOT / "ios/Runner/Assets.xcassets"
SVG = "{http://www.w3.org/2000/svg}"
ET.register_namespace("", SVG[1:-1])


def render(handle, destination, width, height, *, opaque=False):
    # Oversample to preserve small round buttons when exporting launcher densities.
    scale = 2 if width >= 1024 else 4
    viewport = Rsvg.Rectangle()
    viewport.width, viewport.height = width * scale, height * scale
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width * scale, height * scale)
    handle.render_document(cairo.Context(surface), viewport)
    data = io.BytesIO()
    surface.write_to_png(data)
    options = ["-alpha", "off", "-define", "png:color-type=2"] if opaque else []
    subprocess.run(
        ["convert", "png:-", "-filter", "Lanczos", "-resize", f"{width}x{height}!",
         *options, "-strip", str(destination)], input=data.getvalue(), check=True,
    )


def android_vectors(svg):
    body, controls = (svg.find(f"{SVG}path[@id='{name}']") for name in ("handset", "buttons"))
    for mono in (False, True):
        # Match the adaptive launcher's padded foreground and monochrome cutouts.
        if mono:
            paths = [("#FFFFFF", body.attrib["d"] + " " + controls.attrib["d"])]
        else:
            paths = [(node.attrib["fill"], node.attrib["d"]) for node in (body, controls)]
        lines = ['<vector xmlns:android="http://schemas.android.com/apk/res/android"',
                 '    android:width="108dp" android:height="108dp"',
                 '    android:viewportWidth="1024" android:viewportHeight="1024">',
                 '    <group android:pivotX="512" android:pivotY="512" android:scaleX="0.75" android:scaleY="0.75">']
        for color, path in paths:
            lines.extend([f'        <path android:fillColor="{color}" android:fillType="evenOdd"',
                          f'            android:pathData="{path}" />'])
        lines.extend(["    </group>", "</vector>"])
        name = "monochrome" if mono else "foreground"
        (ANDROID / f"drawable/stickremote_{name}.xml").write_text("\n".join(lines) + "\n")


def main():
    svg = ET.parse(MASTER).getroot()
    android_vectors(svg)
    full_icon = Rsvg.Handle.new_from_data(MASTER.read_bytes())
    for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        render(full_icon, ANDROID / f"mipmap-{density}/ic_launcher.png", size, size, opaque=True)
    app_icons = IOS / "AppIcon.appiconset"
    for entry in json.loads((app_icons / "Contents.json").read_text())["images"]:
        size = round(float(entry["size"].split("x")[0]) * int(entry["scale"][0]))
        render(full_icon, app_icons / entry["filename"], size, size, opaque=True)
    render(full_icon, ROOT / "screenshots/stickremote-icon-2048.png", 2048, 2048, opaque=True)
    svg.remove(svg.find(f"{SVG}rect[@id='background']"))
    mark = Rsvg.Handle.new_from_data(ET.tostring(svg))
    splash = IOS / "LaunchImage.imageset"
    for entry in json.loads((splash / "Contents.json").read_text())["images"]:
        size = 144 * int(entry["scale"][0])
        render(mark, splash / entry["filename"], size, size)
    svg.set("viewBox", "305 119 415 787")
    svg.set("width", "415")
    svg.set("height", "787")
    render(Rsvg.Handle.new_from_data(ET.tostring(svg)), ROOT / "assets/stickremote-mark.png", 415, 787)


if __name__ == "__main__":
    main()
