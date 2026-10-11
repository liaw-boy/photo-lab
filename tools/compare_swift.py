"""Compare the Swift renderer (swift/PhotoLab, build it first) with the Python one on a synthetic photo.

Prints size equality and the mean / max per-pixel difference for several border settings."""
import os
import subprocess
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
import ig_border  # noqa: E402
from PIL import Image, ImageChops, ImageStat, ImageDraw
import tempfile  # noqa: E402

d = tempfile.mkdtemp(prefix="photolab_cmp_") + "/"
# synthetic landscape photo, stored rotated (EXIF orientation 6) so it displays as portrait
w, h = 1800, 1200
im = Image.new("RGB", (w, h))
px = im.load()
for y in range(h):
    for x in range(w):
        px[x, y] = (x * 255 // w, y * 255 // h, (x + y) * 255 // (w + h))
dr = ImageDraw.Draw(im); dr.ellipse((300, 200, 900, 800), fill=(240, 60, 40)); dr.rectangle((1000, 100, 1500, 500), fill=(30, 90, 220))
ex = Image.Exif(); ex[0x0112] = 6
im.save(d + "src.jpg", quality=95, exif=ex)
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "swift", "PhotoLab", ".build", "debug", "photolab-render")
cases = [("4:5", 10, "white"), ("1:1", 0, "white"), ("3:2", 20, "rounded"), ("16:9", 10, "blur"), ("even", 8, "blur_square"), ("original", 10, "rounded")]
for ratio, th, style in cases:
    out = d + "sw.jpg"
    r = subprocess.run([BIN, d + "src.jpg", out, "--ratio", ratio, "--thickness", str(th), "--style", style], capture_output=True, text=True)
    if r.returncode: print("ERR", r.stderr); continue
    sw = Image.open(out).convert("RGB")
    with ig_border.open_image(d + "src.jpg") as src:
        py = ig_border.build_canvas(src, ratio, th, 0, None, style)
    if py.size != sw.size:
        print("%-9s th=%-3s %-12s SIZE DIFF py=%s sw=%s" % (ratio, th, style, py.size, sw.size)); continue
    diff = ImageChops.difference(py, sw)
    st = ImageStat.Stat(diff)
    mx = max(b[1] for b in diff.getextrema())
    print("%-9s th=%-3s %-12s size=%s meanΔ=%.2f maxΔ=%d" % (ratio, th, style, sw.size, sum(st.mean)/3, mx))


# ---- footer layouts (needs logos/sony.png for the logo cases; falls back to text when it is missing) ----
import json  # noqa: E402
from argparse import Namespace  # noqa: E402
from PIL.TiffImagePlugin import IFDRational  # noqa: E402

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
photo = Image.new("RGB", (1800, 1200), (90, 120, 150))
ex = Image.Exif()
ex[0x010F], ex[0x0110] = "SONY", "ILCE-7M4"
ex[0x8769] = {0xA434: "FE 24-70mm F2.8 GM II", 0x920A: IFDRational(50, 1), 0x829D: IFDRational(28, 10),
              0x829A: IFDRational(1, 250), 0x8827: 400, 0x9003: "2026:05:25 14:22:50"}
photo.save(d + "foot_src.jpg", quality=95, exif=ex)
base = dict(footer=True, footer_layout="classic3", footer_fields=["camera", "lens", "exposure", "date"],
            footer_exposure_items=["focal", "aperture", "shutter", "iso"])
custom = ig_border.layout_to_style("classic3", {})
custom["center"] = {"align": "center", "lines": [{"items": ["brand", "custom"], "bold": True, "size": 110,
                    "color": "#aa3322", "sep": "divider"}], "logo": "none", "logo_rule": False}
footer_cases = [
    ("classic3", {}, "white"), ("lens main + CJK", {"footer_main": "lens", "footer_custom_text": "Tokyo 東京"}, "white"),
    ("logo right + divider", {"footer_logo_pos": "right", "footer_divider": True}, "white"),
    ("logo centre on blur", {"footer_logo_pos": "center"}, "blur"),
    ("mirror", {"footer_mirror": True, "footer_divider": True}, "white"),
    ("center1", {"footer_layout": "center1"}, "white"),
    ("center2 12h date", {"footer_layout": "center2", "footer_date_format": "mdy_at_12h"}, "rounded"),
    ("split", {"footer_layout": "split"}, "white"),
    ("logo", {"footer_layout": "logo", "footer_custom_text": "hello"}, "white"),
    ("custom style", {"footer_layout": "custom", "footer_style": custom, "footer_custom_text": "ABC"}, "white"),
]
print("-- footer")
for name, extra, style in footer_cases:
    o = {**base, **extra}
    json.dump(o, open(d + "opts.json", "w"))
    out = d + "sw_footer.jpg"
    r = subprocess.run([BIN, d + "foot_src.jpg", out, "--ratio", "4:5", "--thickness", "10", "--style", style,
                        "--footer", d + "opts.json", "--logos", os.path.join(root, "logos"),
                        "--fonts", os.path.join(root, "fonts")], capture_output=True, text=True)
    if r.returncode:
        print("%-22s ERR %s" % (name, r.stderr.strip())); continue
    with ig_border.open_image(d + "foot_src.jpg") as src:
        py = ig_border.build_canvas(src, "4:5", 10, 0, ig_border.make_footer(src, Namespace(**o)), style)
    sw = Image.open(out).convert("RGB")
    if py.size != sw.size:
        print("%-22s SIZE DIFF py=%s sw=%s" % (name, py.size, sw.size)); continue
    print("%-22s size=%s meanΔ=%.2f" % (name, sw.size, sum(ImageStat.Stat(ImageChops.difference(py, sw)).mean) / 3))
