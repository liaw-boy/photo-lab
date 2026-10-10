#!/usr/bin/env python3
"""Add a white border to photos, modelled on Lightroom mobile's border options.

Usage:
    python3 ig_border.py watch  INPUT_DIR OUTPUT_DIR [options]   # auto-process new exports
    python3 ig_border.py once   INPUT_DIR OUTPUT_DIR [options]   # process existing files and exit
    python3 ig_border.py file   IMAGE OUTPUT_DIR [options]       # process a single file

How it works: the photo is shrunk (never enlarged) to --max-edge on its long side,
a white margin of (thickness/200 * long edge) is added on every side, then extra white
is added on the short side until the canvas matches --ratio.

--style picks the frame look: white (plain), rounded (rounded corners + soft shadow) or
blur (blurred copy of the photo as background).

With --footer, a camera-info line (model, lens, exposure, date, brand logo) is drawn
under the photo. Brand logos are NOT bundled: put your own PNGs in ./logos/ named after the
brand in lowercase (sony.png, canon.png, ...). GPS and serial numbers are never read.
"""
import argparse
import io
import json
import os
import re
import sys
import tempfile
import time
import unicodedata
import warnings
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageFilter, ImageFont, ImageOps

MAX_PIXELS = 150_000_000                       # refuse bigger images (a 100 MP panorama is still fine)
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
warnings.simplefilter("error", Image.DecompressionBombWarning)   # Pillow only warns up to 2x the limit: make it an error
INPUT_FORMATS = ["JPEG", "PNG", "TIFF"]        # trust the content, but only these decoders
_UMASK = os.umask(0)
os.umask(_UMASK)                               # remember the user's umask for the output files

EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
# ratio name -> (w, h); "original" = no border, "even" = equal border only
RATIOS = {"1:1": (1, 1), "2:3": (2, 3), "3:2": (3, 2), "4:5": (4, 5),
          "3:4": (3, 4), "5:4": (5, 4), "9:16": (9, 16), "16:9": (16, 9)}
RATIO_CHOICES = ["original", "even"] + list(RATIOS)
WHITE = (255, 255, 255)
PAD_DIVISOR = 200.0  # thickness 10 -> 5% of the long edge (measured from LR mobile output)
# background x corners: white = white + square, rounded = white + rounded, blur = blurred + rounded,
# blur_square = blurred + square
STYLES = ["white", "rounded", "blur", "blur_square"]
CORNER = 0.012        # corner radius as a fraction of the photo's long edge (rounded / blur)

# ---- footer (camera info) ----
def _read_version():
    """Version string from the VERSION file at the repo root ("0.0.0" if it cannot be read)."""
    try:
        text = (Path(__file__).resolve().parent.parent / "VERSION").read_text(encoding="utf-8").strip()
        return text if re.fullmatch(r"\d+\.\d+\.\d+", text) else "0.0.0"
    except (OSError, ValueError):
        return "0.0.0"


__version__ = _read_version()
LOGO_DIR = Path(__file__).resolve().parent.parent / "logos"
FOOTER_LAYOUTS = ["classic3", "center1", "center2", "split", "logo", "custom"]
FOOTER_FIELDS = ["camera", "lens", "exposure", "date"]
LOGO_POSITIONS = ["left", "right", "center"]     # classic3: left of the name block / just before the right block / centre
DATE_FORMATS = ["ymd_dot", "ymd_dash", "ymd_slash", "dmy_text", "mdy_text",
                "ymd_dash_hm", "ymd_dash_hms", "dmy_hm", "mdy_at_12h"]     # the last four include the time
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
CJK_FONTS = ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
             "/System/Library/Fonts/Hiragino Sans GB.ttc"]
FOOTER_H = 0.075          # footer band height as a fraction of the photo's long edge
MAX_LOGO_BYTES = 5 * 1024 * 1024
MAX_LOGO_PIXELS = 25_000_000
MAX_LOGO_WIDTH = 4096                       # rendered logo width cap, whatever the aspect ratio
EXPOSURE_KEYS = ["focal", "aperture", "shutter", "iso"]
DEFAULT_EXPOSURE_ITEMS = ["aperture", "shutter", "iso"]     # the default look shows just these three (no focal length)
EXPOSURE_ORDERS = ["std", "iso_first"]      # focal aperture shutter iso  /  iso aperture shutter focal
FONTS_DIR = Path(__file__).resolve().parent.parent / "fonts"      # user-supplied .ttf/.otf/.ttc
MAX_FONT_BYTES = 40 * 1024 * 1024
SYS = "/System/Library/Fonts/"
SUP = "/System/Library/Fonts/Supplemental/"
# key -> ((regular candidates), (bold candidates or ())); a .ttc / variable font is searched for the right face
SYSTEM_FONTS = {
    "sf": ((SYS + "SFNS.ttf",), ()),
    "pingfang": ((SYS + "PingFang.ttc",), ()),
    "avenir": ((SYS + "Avenir Next.ttc", SYS + "Avenir.ttc"), ()),
    "futura": ((SUP + "Futura.ttc",), ()),
    "optima": ((SYS + "Optima.ttc",), ()),
    "gillsans": ((SUP + "GillSans.ttc",), ()),
    "palatino": ((SYS + "Palatino.ttc",), ()),
    "georgia": ((SUP + "Georgia.ttf",), (SUP + "Georgia Bold.ttf",)),
    "didot": ((SUP + "Didot.ttc",), ()),
    "menlo": ((SYS + "Menlo.ttc",), ()),
}
FONT_LABELS = {"auto": "Helvetica Neue (預設)", "sf": "SF Pro", "pingfang": "蘋方", "avenir": "Avenir Next",
               "futura": "Futura", "optima": "Optima", "gillsans": "Gill Sans", "palatino": "Palatino",
               "georgia": "Georgia", "didot": "Didot", "menlo": "Menlo (等寬)"}
# text colours (strong, normal, weak) per background
THEME_DARK_TEXT = ((30, 30, 30), (70, 70, 70), (135, 135, 135))
THEME_LIGHT_TEXT = ((255, 255, 255), (238, 238, 238), (200, 200, 200))
FONT_REGULAR = ["/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc",
                "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf"]
FONT_BOLD = ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf"]

BRANDS = {"sony": "Sony", "nikon": "Nikon", "canon": "Canon", "fujifilm": "Fujifilm", "fuji": "Fujifilm",
          "olympus": "Olympus", "om digital": "OM System", "om system": "OM System", "panasonic": "Panasonic",
          "leica": "Leica", "ricoh": "Ricoh", "pentax": "Pentax", "sigma": "Sigma", "hasselblad": "Hasselblad",
          "dji": "DJI", "apple": "Apple", "samsung": "Samsung", "google": "Google", "xiaomi": "Xiaomi",
          "huawei": "Huawei", "gopro": "GoPro", "insta360": "Insta360"}
SONY_MODELS = {"ILCE-7M4": "α7 IV", "ILCE-7M3": "α7 III", "ILCE-7M2": "α7 II", "ILCE-7RM5": "α7R V",
               "ILCE-7RM4": "α7R IV", "ILCE-7RM3": "α7R III", "ILCE-7SM3": "α7S III", "ILCE-7CM2": "α7C II",
               "ILCE-7C": "α7C", "ILCE-9M3": "α9 III", "ILCE-9M2": "α9 II", "ILCE-9": "α9", "ILCE-1": "α1",
               "ILCE-6700": "α6700", "ILCE-6600": "α6600", "ILCE-6400": "α6400", "ILCE-6100": "α6100"}

# ---- user-designed footer style: three blocks (left / centre / right), each at most three lines ----
STYLE_BLOCKS = ("left", "center", "right")
STYLE_ALIGNS = ("left", "center", "right")
STYLE_COLORS = ("strong", "normal", "weak")
STYLE_TOKENS = ("model", "model_auto", "brand_model", "brand", "lens", "focal", "aperture", "shutter", "iso",
                "exposure", "date", "custom", "logo")
MAX_STYLE_LINES = 2                     # per block (same limit as _stack)
MAX_STYLE_ITEMS = 4                     # per line
STYLE_FILE_FORMAT = "ig-border-style"
MAX_STYLE_FILE_BYTES = 200_000

SAMPLE_INFO = {"brand": "Camera", "model": "Model", "lens": "50mm F1.8", "focal": "50mm", "aperture": "f/1.8",
               "shutter": "1/250s", "iso": "ISO100", "date": "2026.01.01"}


# --------------------------------------------------------------------------
# EXIF
# --------------------------------------------------------------------------
def _clean(s, maxlen=48):
    """Printable text only: control characters and invisible / bidi-override format characters are dropped."""
    s = "".join(ch for ch in str(s) if not unicodedata.category(ch).startswith("C"))
    return re.sub(r"\s+", " ", s).strip()[:maxlen]


def _num(v):
    try:
        f = float(v)
        return f if f == f and f not in (float("inf"), float("-inf")) else None
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def read_exif(img):
    """Return a small dict of display strings. Never reads GPS or serial numbers."""
    try:
        ex = img.getexif()
        try:
            sub = ex.get_ifd(0x8769)
        except Exception:
            sub = {}
    except Exception:
        return {}

    def get(tag):
        v = sub.get(tag)
        return ex.get(tag) if v is None else v

    info = {}
    make = _clean(get(0x010F) or "")
    model = _clean(get(0x0110) or "")
    low = make.lower()
    brand = next((name for key, name in BRANDS.items() if key in low), make.title() if make else "")
    if brand:
        info["brand"] = brand
    if model:
        m = model
        for pre in (make, brand, make.split(" ")[0] if make else ""):
            if pre and m.lower().startswith(pre.lower() + " "):
                m = m[len(pre):].strip()
                break
        if brand == "Sony":
            m = SONY_MODELS.get(m.upper(), m)
        info["model"] = m
    lens = _clean(get(0xA434) or "")
    if lens:
        info["lens"] = lens
    focal = _num(get(0x920A))
    if focal and focal > 0:
        info["focal"] = "%gmm" % round(focal, 1)
    fnum = _num(get(0x829D))
    if fnum and fnum > 0:
        info["aperture"] = "f/%s" % ("%.1f" % fnum).rstrip("0").rstrip(".")
    et = _num(get(0x829A))
    if et and et > 0:
        info["shutter"] = ("1/%ds" % round(1 / et)) if et < 0.3 else ("%gs" % round(et, 1))
    iso = get(0x8827)
    if isinstance(iso, (tuple, list)) and iso:
        iso = iso[0]
    iso = _num(iso)
    if iso and iso > 0:
        info["iso"] = "ISO%d" % iso
    m = re.match(r"^(\d{4})[:\-](\d{2})[:\-](\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?", str(get(0x9003) or ""))
    if m:
        g = m.groups()
        info["date"] = "%s.%s.%s" % g[:3]
        info["date_parts"] = g[:3]
        if g[3] is not None:
            info["time_parts"] = (g[3], g[4], g[5] or "00")
    return info


def fmt_date(parts, fmt, tparts=None):
    """Format ('2026','05','25') [+ ('14','22','50')] in one of DATE_FORMATS. Invalid dates give ''."""
    try:
        y, mo, d = parts
        mi, di = int(mo), int(d)
        if not (1 <= mi <= 12 and 1 <= di <= 31):
            raise ValueError
    except (TypeError, ValueError):
        return ""
    hh = mm = ss = None
    try:
        if tparts:
            hh, mm, ss = int(tparts[0]), int(tparts[1]), int(tparts[2])
            if not (0 <= hh <= 23 and 0 <= mm <= 59 and 0 <= ss <= 59):
                raise ValueError
    except (TypeError, ValueError, IndexError):
        hh = mm = ss = None
    has_t = hh is not None
    if fmt == "ymd_dash":
        return "%s-%s-%s" % (y, mo, d)
    if fmt == "ymd_slash":
        return "%s/%s/%s" % (y, mo, d)
    if fmt == "dmy_text":
        return "%d %s %s" % (di, MONTHS[mi - 1], y)
    if fmt == "mdy_text":
        return "%s %d, %s" % (MONTHS[mi - 1], di, y)
    if fmt == "ymd_dash_hm":
        return "%s-%s-%s" % (y, mo, d) + (" %02d:%02d" % (hh, mm) if has_t else "")
    if fmt == "ymd_dash_hms":
        return "%s-%s-%s" % (y, mo, d) + (" %02d:%02d:%02d" % (hh, mm, ss) if has_t else "")
    if fmt == "dmy_hm":
        return "%d %s %s" % (di, MONTHS[mi - 1], y) + (" %02d:%02d" % (hh, mm) if has_t else "")
    if fmt == "mdy_at_12h":
        base = "%s %d, %s" % (MONTHS[mi - 1], di, y)
        return base + (" at %d:%02d:%02d %s" % (hh % 12 or 12, mm, ss, "AM" if hh < 12 else "PM") if has_t else "")
    return "%s.%s.%s" % (y, mo, d)


def exposure_text(info, items=None, order="std"):
    keys = ["iso", "aperture", "shutter", "focal"] if order == "iso_first" else list(EXPOSURE_KEYS)
    allowed = set(EXPOSURE_KEYS if items is None else items)
    return " ".join(info[k] for k in keys if k in allowed and info.get(k))


# --------------------------------------------------------------------------
# footer drawing
# --------------------------------------------------------------------------
def user_fonts():
    """Fonts the user dropped into ./fonts/ -> {key: Path}; key is 'user:<file name>'."""
    out = {}
    try:
        root = FONTS_DIR.resolve()
        for p in sorted(root.iterdir()):
            if (re.fullmatch(r"[\w .()+\-]{1,80}\.(ttf|otf|ttc)", p.name, re.I) and p.is_file()
                    and p.resolve().parent == root and p.stat().st_size <= MAX_FONT_BYTES):
                out["user:" + p.name] = p
    except OSError:
        pass
    return out


def available_fonts():
    """[(key, label)] for every font that can really be loaded on this machine."""
    out = [("auto", FONT_LABELS["auto"])]
    for key, (regular, _bold) in SYSTEM_FONTS.items():
        if any(Path(f).is_file() for f in regular):
            out.append((key, FONT_LABELS[key]))
    out += [(k, v.stem) for k, v in user_fonts().items()]
    return out


def valid_font_key(key):
    return key if isinstance(key, str) and key in dict(available_fonts()) else "auto"


def _pick_face(path, size, bold):
    """Open the regular / bold face of a (possibly multi-face or variable) font file; None if impossible."""
    faces = []
    for idx in range(40):
        try:
            f = ImageFont.truetype(str(path), size, index=idx)
        except (OSError, ValueError):
            break
        try:
            style = (f.getname()[1] or "").lower()
        except Exception:
            style = ""
        faces.append((f, style))
        if not str(path).lower().endswith(".ttc"):
            break
    if not faces:
        return None
    try:                                       # variable font (e.g. SF Pro): one face, weight chosen by named instance
        names = faces[0][0].get_variation_names()
    except (OSError, AttributeError, ValueError):
        names = None
    if names:
        want = [b"Bold", b"Semibold"] if bold else [b"Regular", b"Book"]
        name = next((n for n in want if n in names), None)
        if name is None:
            return None if bold else faces[0][0]
        try:
            faces[0][0].set_variation_by_name(name)
            return faces[0][0]
        except (OSError, ValueError):
            return None

    def ok(style, words, avoid=("italic", "oblique", "condensed", "narrow", "compressed", "rounded")):
        return any(w in style for w in words) and not any(a in style for a in avoid)

    pool = faces
    if bold:
        pick = next((f for f, st in pool if st in ("bold", "semibold")), None) or \
               next((f for f, st in pool if ok(st, ("bold",))), None) or \
               next((f for f, st in pool if ok(st, ("semibold", "demi", "heavy", "black"))), None)
    else:
        pick = next((f for f, st in pool if st in ("regular", "book", "roman", "normal")), None) or \
               next((f for f, st in pool if ok(st, ("regular", "book", "roman"))), None) or \
               next((f for f, st in pool if ok(st, ("medium", "light", "text"))), None)
    if pick is None and not bold:
        pick = pool[0][0]
    if pick is None:
        return None
    try:                                       # variable font (e.g. SF Pro): select the named instance
        names = pick.get_variation_names()
        want = [b"Bold", b"Semibold"] if bold else [b"Regular", b"Book"]
        name = next((n for n in want if n in names), None)
        if name is not None:
            pick.set_variation_by_name(name)
        elif bold:
            return None
    except (OSError, ValueError, AttributeError):
        pass
    return pick


@lru_cache(maxsize=128)
def _font(size, bold=False, key="auto"):
    """Font for (size, bold, family key). Falls back to Helvetica Neue / Arial; never raises."""
    paths = []
    if key.startswith("user:"):
        p = user_fonts().get(key)
        paths = [p] if p else []
    elif key in SYSTEM_FONTS:
        regular, boldfiles = SYSTEM_FONTS[key]
        paths = list(boldfiles if (bold and boldfiles) else regular)
    for path in paths:
        f = _pick_face(path, size, bold)
        if f is not None:
            return f
    for path in (FONT_BOLD if bold else []) + FONT_REGULAR:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size)
    except TypeError:
        return ImageFont.load_default()


@lru_cache(maxsize=16)
def _cjk_font(size):
    for path in CJK_FONTS:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return None


def _text_img(text, size, color, bold=False, key="auto"):
    font = None
    if key != "pingfang" and any(ord(ch) > 0x2FF for ch in text):   # CJK / non-Latin: Latin fonts lack the glyphs
        font = _cjk_font(size)
    font = font or _font(size, bold, key)
    l, t, r, b = font.getbbox(text)
    im = Image.new("RGBA", (max(1, r - l), max(1, b - t)), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((-l, -t), text, font=font, fill=tuple(color) + (255,))
    return im


def _near(c, target, tol):
    return all(abs(c[i] - target[i]) <= tol for i in range(3))


def _prepare_logo(im, height, on_dark):
    """Trim empty margins, scale to `height`, and make the background fit the surface it is drawn on."""
    im = im.convert("RGBA")
    has_alpha = im.getchannel("A").getextrema()[0] < 250
    bg = None
    if has_alpha:
        box = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    else:
        w, h = im.size
        corners = [im.getpixel(xy)[:3] for xy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
        if all(_near(c, corners[0], 12) for c in corners):          # flat background: find the artwork
            bg = corners[0]
            diff = Image.new("L", im.size, 0)
            for ch in range(3):
                d = ImageChops.difference(im.getchannel(ch), Image.new("L", im.size, bg[ch]))
                diff = ImageChops.lighter(diff, d)
            box = diff.point(lambda v: 255 if v > 24 else 0).getbbox()
        else:
            box = None
    if box:
        im = im.crop(box)
    if im.width / im.height > 20 or im.height / im.width > 20:      # degenerate artwork (e.g. 800x1 pixels)
        raise ValueError("unreasonable logo aspect ratio")
    s = min(height / im.height, MAX_LOGO_WIDTH / im.width)
    height = max(1, round(im.height * s))
    im = im.resize((max(1, round(im.width * s)), height), Image.LANCZOS)
    if bg is not None:
        px = im.load()
        if on_dark and min(bg) > 235:             # white artwork background on a dark surface -> colour to alpha
            for y in range(im.height):
                for x in range(im.width):
                    r, g, b, _ = px[x, y]
                    a = 255 - min(r, g, b)
                    px[x, y] = (r, g, b, a)
        elif max(bg) < 25:                        # black background (white-on-black logo) -> luminance to alpha
            for y in range(im.height):
                for x in range(im.width):
                    r, g, b, _ = px[x, y]
                    a = max(r, g, b)
                    k = 255.0 / a if a else 0
                    px[x, y] = (min(255, round(r * k)), min(255, round(g * k)), min(255, round(b * k)), a)
    return im


@lru_cache(maxsize=32)
def _logo_file(path_str, mtime, height, on_dark):
    with Image.open(path_str, formats=["PNG"]) as im:
        if im.width * im.height > MAX_LOGO_PIXELS:
            raise ValueError("logo too large")
        return _prepare_logo(im, height, on_dark)


def load_logo(brand, height, on_dark=False, normalize=False):
    """Load logos/<brand>.png (user supplied). On dark surfaces logos/<brand>_dark.png is preferred.
    The name is restricted to [a-z0-9] and the logos folder.
    normalize=True gives wide wordmarks a smaller height (height / sqrt(aspect)) so that a square badge and a wide
    wordmark carry about the same visual weight."""
    slug = re.sub(r"[^a-z0-9]", "", (brand or "").lower())
    if not slug:
        return None
    names = [slug + "_dark.png", slug + ".png"] if on_dark else [slug + ".png"]
    try:
        root = LOGO_DIR.resolve()
        for name in names:
            p = (root / name).resolve()
            if p.parent != root or not p.is_file() or p.stat().st_size > MAX_LOGO_BYTES:
                continue
            mt = p.stat().st_mtime_ns
            if normalize:
                probe = _logo_file(str(p), mt, 100, on_dark)
                height = max(8, round(height / max(1.0, probe.width / probe.height) ** 0.5))
            return _logo_file(str(p), mt, height, on_dark).copy()
    except Exception:
        return None
    return None


def _row(segs, gap, divider, color=(0, 0, 0)):
    """Join segment images horizontally, optional thin divider between them."""
    segs = [s for s in segs if s is not None]
    if not segs:
        return None
    h = max(s.height for s in segs)
    parts = []
    for i, s in enumerate(segs):
        if i and divider:
            parts.append(("div", 1))
        parts.append(("img", s))
    w = sum((p[1].width if p[0] == "img" else p[1]) for p in parts) + gap * (len(parts) - 1)
    row = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    x = 0
    for kind, p in parts:
        if kind == "img":
            row.alpha_composite(p, (x, (h - p.height) // 2))
            x += p.width + gap
        else:
            ImageDraw.Draw(row).line([(x, h * 0.1), (x, h * 0.9)], fill=tuple(color) + (110,),
                                     width=max(1, h // 14))
            x += p + gap
    return row


MAX_STACK_LINES = 2      # a stack of text rows never has more than two lines


def _stack(rows, gap, align):
    rows = [r for r in rows if r is not None][:MAX_STACK_LINES]
    if not rows:
        return None
    w = max(r.width for r in rows)
    h = sum(r.height for r in rows) + gap * (len(rows) - 1)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    y = 0
    for r in rows:
        x = {"left": 0, "right": w - r.width}.get(align, (w - r.width) // 2)
        out.alpha_composite(r, (x, y))
        y += r.height + gap
    return out


def _mix(c, target, k):
    return tuple(round(c[i] * (1 - k) + target[i] * k) for i in range(3))


def _theme_with_color(theme, color):
    """Custom text colour: strong/normal use it, the secondary ("weak") tone is a softened version."""
    if not color:
        return theme
    lum = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]
    return (color, color, _mix(color, (0, 0, 0), 0.30) if lum > 170 else _mix(color, (255, 255, 255), 0.45))


def render_footer(footer, base_band, theme=THEME_DARK_TEXT):
    """Return a list of RGBA images (1 = centred; 2 = left + right; 3 = left + right + centre logo), or None."""
    info, layout, fields = footer["info"], footer["layout"], footer["fields"]
    divider = bool(footer.get("divider"))
    on_dark = theme is THEME_LIGHT_TEXT
    strong, normal, weak = _theme_with_color(theme, footer.get("color"))
    bold = footer.get("bold", True)
    fkey = footer.get("font", "auto")

    def T(text, size, color, b=False):
        return _text_img(text, size, color, b, fkey)

    fs = max(10, round(base_band * 0.40 * footer.get("text_scale", 1.0)))
    lscale = footer.get("logo_scale", 1.0)
    gap = round(fs * 1.1)
    brand = info.get("brand")
    exp_txt = exposure_text(info, footer.get("exposure_items"), footer.get("exposure_order", "std"))
    date_txt = (fmt_date(info.get("date_parts"), footer.get("date_fmt"), info.get("time_parts"))
                if info.get("date_parts") else info.get("date", ""))
    full_model = (brand + " " + info["model"]).strip() if info.get("model") else (brand or "")
    custom = footer.get("custom_text", "")
    custom_img = T(custom, round(fs * 0.95), weak) if custom else None

    if layout == "logo":
        logo = load_logo(brand, round(fs * 2.6 * lscale), on_dark) if brand else None
        if logo is None and brand:
            logo = T(brand.upper(), round(fs * 1.5 * lscale), strong, bold)
        one = _stack([logo, custom_img], round(fs * 0.5), "center")
        return [one] if one is not None else None

    if layout == "classic3":
        pos = footer.get("logo_pos", "left")
        mirror = bool(footer.get("mirror"))
        lens_main = footer.get("main") == "lens"
        logo = (load_logo(brand, round(fs * 2.0 * lscale), on_dark, normalize=True)
                if "camera" in fields and brand else None)
        model = info.get("model", "") if logo is not None else full_model     # the logo already names the brand
        has_model = "camera" in fields and model
        has_lens = "lens" in fields and info.get("lens")
        model_img = lens_img = None
        if lens_main:                                   # lens bold on top, camera body in the secondary tone
            lens_img = T(info["lens"], fs, strong, bold) if has_lens else None
            model_img = T(model, round(fs * 0.95), weak) if has_model else None
            name_lines = [lens_img, model_img]
        else:                                           # camera bold on top, lens in the secondary tone
            model_img = T(model, fs, strong, bold) if has_model else None
            lens_img = T(info["lens"], round(fs * 0.95), weak) if has_lens else None
            name_lines = [model_img, lens_img]
        exp_img = T(exp_txt, fs, strong, bold) if "exposure" in fields and exp_txt else None
        date_img = T(date_txt, round(fs * 0.95), weak) if "date" in fields and date_txt else None
        text_gap = round(fs * 0.5)
        names_l = _stack(name_lines, text_gap, "left")                          # two lines at most
        second = _row([date_img, custom_img], round(fs * 0.9), False)           # date and your own text share a line
        params_r = _stack([exp_img, second], text_gap, "right")
        params_l = _stack([exp_img, second], text_gap, "left")
        center = None
        if mirror:                                      # parameters on the left, logo | camera block on the right
            left = params_l
            right = _row([logo, names_l], round(gap * 0.7), divider, weak)
        elif pos == "right":                            # logo just before the right-hand block
            left = names_l
            right = _row([logo, params_r], round(gap * 0.7), divider, weak)
            divider = False
        elif pos == "center":
            left, right, center = names_l, params_r, logo
        else:                                           # "left" (default): logo beside the name block
            left = _row([logo, names_l], round(gap * 0.7), False)
            right = params_r
        if divider and not mirror and right is not None:   # thin line just left of the right-hand block
            right = _row([Image.new("RGBA", (1, right.height), (0, 0, 0, 0)), right], round(gap * 0.6), True, weak)
        parts = [left, right] + ([center] if center is not None else [])
        return parts if any(p is not None for p in parts) else None

    if layout == "custom":
        style = footer.get("style") or default_style()
        have_logo = bool(brand) and load_logo(brand, 12, on_dark) is not None
        texts = {"model": info.get("model", ""), "model_auto": info.get("model", "") if have_logo else full_model,
                 "brand_model": full_model, "brand": brand or "", "lens": info.get("lens", ""),
                 "focal": info.get("focal", ""), "aperture": info.get("aperture", ""),
                 "shutter": info.get("shutter", ""), "iso": info.get("iso", ""), "exposure": exp_txt,
                 "date": date_txt, "custom": custom}
        tones = {"strong": strong, "normal": normal, "weak": weak}

        def logo_img(size_pct=100):
            return (load_logo(brand, round(fs * 2.0 * lscale * size_pct / 100), on_dark, normalize=True)
                    if brand else None)

        def style_line(ln):
            size = max(8, round(fs * ln["size"] / 100))
            color = tones.get(ln["color"]) or _hex_color(ln["color"]) or strong
            imgs = []
            for tok in ln["items"]:
                if tok == "logo":
                    imgs.append(logo_img(ln["size"]))
                elif texts.get(tok):
                    imgs.append(T(texts[tok], size, color, ln["bold"] and bold))
            divided = ln.get("sep") == "divider"
            return _row(imgs, gap if divided else round(fs * 0.9), divided, weak)

        def build_block(name):
            blk = style[name]
            stack = _stack([style_line(ln) for ln in blk["lines"]], round(fs * 0.5), blk["align"])
            if blk.get("logo") == "left":                       # the brand logo beside the block's lines
                lg = logo_img()
                if lg is not None:
                    return _row([lg, stack], round(gap * 0.7), bool(blk.get("logo_rule")), weak)
            return stack

        left, centre, right = (build_block(n) for n in ("left", "center", "right"))
        if style.get("divider") and right is not None:           # thin line just left of the right-hand block
            right = _row([Image.new("RGBA", (1, right.height), (0, 0, 0, 0)), right], round(gap * 0.6), True, weak)
        parts = [left, right, centre]
        return parts if any(p is not None for p in parts) else None

    logo = None
    if "camera" in fields and brand:
        logo = load_logo(brand, round(fs * 2.0 * lscale), on_dark, normalize=True)
    cam = None
    if "camera" in fields:
        text = info.get("model", "")
        if not logo and brand:
            text = (brand + " " + text).strip()
        cam = T(text, fs, strong, bold) if text else None
    lens = T(info["lens"], fs, normal) if "lens" in fields and info.get("lens") else None
    exp = T(exp_txt, fs, normal) if "exposure" in fields and exp_txt else None
    date = T(date_txt, fs, normal) if "date" in fields and date_txt else None
    cam_row = _row([logo, cam], round(gap * 0.5), False)
    cdiv = bool(footer.get("center_divider", True))      # the "|" between the items of the centred layouts
    if layout == "center1":
        parts = [_row([cam_row, lens, exp, date, custom_img], gap, cdiv, weak)]
    elif layout == "center2":
        parts = [_stack([_row([cam_row, lens], gap, cdiv, weak), _row([exp, date, custom_img], gap, cdiv, weak)],
                        round(fs * 0.5), "center")]
    else:  # split
        parts = [_stack([cam_row, lens], round(fs * 0.5), "left"),
                 _stack([exp, _row([date, custom_img], round(fs * 0.9), False)], round(fs * 0.5), "right")]
    parts = [p for p in parts if p is not None]
    return parts or None


# --------------------------------------------------------------------------
# canvas
# --------------------------------------------------------------------------
def _style_line(items, bold=False, size=100, color="strong", sep="gap"):
    return {"items": list(items), "bold": bold, "size": size, "color": color, "sep": sep}


def layout_to_style(layout, o=None):
    """Express a built-in layout with the style editor's model, so that the editor can show (and start from) it.
    `o` holds the footer options: fields, mirror, main, logo_pos, divider.  "classic3" converts exactly (it renders
    pixel-identically); the other layouts are close approximations."""
    o = o or {}
    fields = set(o.get("fields", FOOTER_FIELDS))
    divider, mirror = bool(o.get("divider")), bool(o.get("mirror"))
    pos = o.get("logo_pos") if o.get("logo_pos") in LOGO_POSITIONS else "left"
    cam, lens, expo, date = (k in fields for k in FOOTER_FIELDS)

    def line(items, bold=False, size=100, color="strong", sep="gap"):
        return _style_line(items, bold, size, color, sep) if items else None

    def lines(*ls):
        return [l for l in ls if l]

    def block(align, ls, logo="none", rule=False):
        return {"align": align, "lines": ls, "logo": logo, "logo_rule": bool(rule)}

    if o.get("main") == "lens":
        names = lines(line(["lens"] if lens else [], True), line(["model_auto"] if cam else [], False, 95, "weak"))
    else:
        names = lines(line(["model_auto"] if cam else [], True), line(["lens"] if lens else [], False, 95, "weak"))
    params = lines(line(["exposure"] if expo else [], True),
                   line((["date"] if date else []) + ["custom"], False, 95, "weak"))
    empty = block("center", [])
    if layout in ("center1", "center2"):
        csep = "divider" if o.get("center_divider", True) else "gap"
        row1 = line((["logo"] if cam else []) + (["model_auto"] if cam else []) + (["lens"] if lens else []), True,
                    sep=csep)
        row2 = line((["exposure"] if expo else []) + (["date"] if date else []) + ["custom"], False, 100, "normal",
                    csep)
        return {"left": block("left", []), "center": block("center", lines(row1, row2)), "right": block("right", []),
                "divider": False}
    if layout == "logo":
        return {"left": block("left", []), "center": block("center", lines(line(["logo"]),
                line(["custom"], False, 95, "weak"))), "right": block("right", []), "divider": False}
    if mirror and layout == "classic3":                       # parameters left, logo | camera right
        return {"left": block("left", params), "center": empty,
                "right": block("left", names, "left" if cam else "none", divider), "divider": False}
    return {"left": block("left", names, "left" if (pos == "left" and cam) else "none"),
            "center": block("center", lines(line(["logo"])) if (pos == "center" and cam) else []),
            "right": block("right", params, "left" if (pos == "right" and cam) else "none",
                           divider if pos == "right" else False),
            "divider": divider and pos != "right"}


def default_style():
    """The starting point of the style editor = the default 經典三欄 look."""
    return layout_to_style("classic3", {})


def sanitize_style(obj):
    """Return a valid style dict whatever `obj` is (untrusted JSON): whitelisted tokens, clamped numbers,
    at most three lines per block and four items per line. Unknown keys are dropped."""
    base = default_style()
    if not isinstance(obj, dict):
        return base
    out = {"divider": obj.get("divider") is True}
    for name in STYLE_BLOCKS:
        blk = obj.get(name)
        if not isinstance(blk, dict):
            out[name] = base[name]
            continue
        logo_side = blk.get("logo") if blk.get("logo") in ("none", "left") else "none"
        align = blk.get("align") if isinstance(blk.get("align"), str) and blk.get("align") in STYLE_ALIGNS \
            else base[name]["align"]
        lines = []
        raw = blk.get("lines") if isinstance(blk.get("lines"), list) else []
        for ln in raw[:50]:                      # bounded work; invalid lines do not use up the 3-line allowance
            if len(lines) >= MAX_STYLE_LINES:
                break
            if not isinstance(ln, dict):
                continue
            items = [t for t in (ln.get("items") if isinstance(ln.get("items"), list) else [])
                     if isinstance(t, str) and t in STYLE_TOKENS][:MAX_STYLE_ITEMS]
            if not items:
                continue
            col = ln.get("color")
            col = col if isinstance(col, str) and (col in STYLE_COLORS or _hex_color(col)) else "strong"
            lines.append({"items": items, "bold": ln.get("bold") is True,
                          "size": int(_clamp(ln.get("size", 100), 50, 200, 100)), "color": col,
                          "sep": "divider" if ln.get("sep") == "divider" else "gap"})
        out[name] = {"align": align, "lines": lines, "logo": logo_side, "logo_rule": blk.get("logo_rule") is True}
    return out


def load_style_file(path):
    """Read a .igstyle.json file -> (style, settings, name). Raises ValueError for anything unexpected."""
    p = Path(path)
    if p.stat().st_size > MAX_STYLE_FILE_BYTES:
        raise ValueError("style file too large")
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("format") != STYLE_FILE_FORMAT:
        raise ValueError("not a style file")
    settings = data.get("settings")
    return (sanitize_style(data.get("style")), settings if isinstance(settings, dict) else {},
            _clean(data.get("name", ""), 30))


def save_style_file(path, style, settings, name=""):
    """Atomically write a .igstyle.json file."""
    p = Path(path)
    payload = {"format": STYLE_FILE_FORMAT, "version": 1, "name": _clean(name, 30),
               "style": sanitize_style(style), "settings": settings}
    fd, tmp = tempfile.mkstemp(prefix=".ig_style_", suffix=".tmp", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def _clamp(value, lo, hi, default):
    try:
        v = float(value)
    except (TypeError, ValueError, OverflowError):      # OverflowError: an absurdly large integer
        return default
    return min(hi, max(lo, v)) if v == v else default


def _hex_color(value):
    """'#RRGGBB' -> (r, g, b); anything else -> None."""
    if isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value.strip()):
        v = value.strip()
        return tuple(int(v[i:i + 2], 16) for i in (1, 3, 5))
    return None


def make_footer(img, opts, info=None):
    """Footer spec from options (every value is validated / clamped here), or None when disabled."""
    if not getattr(opts, "footer", False):
        return None
    fields = set(getattr(opts, "footer_fields", FOOTER_FIELDS)) & set(FOOTER_FIELDS)
    if info is None:
        info = read_exif(img)
    layout = getattr(opts, "footer_layout", "classic3")
    pos = getattr(opts, "footer_logo_pos", "left")
    dfmt = getattr(opts, "footer_date_format", "ymd_dot")
    return {"info": info, "layout": layout if layout in FOOTER_LAYOUTS else "classic3", "fields": fields,
            "divider": bool(getattr(opts, "footer_divider", False)),
            "center_divider": bool(getattr(opts, "footer_center_divider", True)),
            "text_scale": _clamp(getattr(opts, "footer_text_scale", 1.0), 0.5, 2.0, 1.0),
            "logo_scale": _clamp(getattr(opts, "footer_logo_scale", 1.0), 0.4, 2.5, 1.0),
            "height_scale": _clamp(getattr(opts, "footer_height_scale", 1.0), 0.6, 2.5, 1.0),
            "color": _hex_color(getattr(opts, "footer_color", None)),
            "bold": bool(getattr(opts, "footer_bold", True)),
            "date_fmt": dfmt if dfmt in DATE_FORMATS else "ymd_dot",
            "logo_pos": pos if pos in LOGO_POSITIONS else "left",       # the old "above" (3 lines) became "left"
            "custom_text": _clean(getattr(opts, "footer_custom_text", "") or "", 60),
            "main": "lens" if getattr(opts, "footer_main", "model") == "lens" else "model",
            "mirror": bool(getattr(opts, "footer_mirror", False)),
            "exposure_items": [k for k in EXPOSURE_KEYS
                               if k in set(getattr(opts, "footer_exposure_items", DEFAULT_EXPOSURE_ITEMS) or [])],
            "exposure_order": (getattr(opts, "footer_exposure_order", "std")
                               if getattr(opts, "footer_exposure_order", "std") in EXPOSURE_ORDERS else "std"),
            "font": valid_font_key(getattr(opts, "footer_font", "auto")),
            "style": sanitize_style(getattr(opts, "footer_style", None))}


def _rounded_mask(size, radius):
    """Anti-aliased rounded-rectangle mask (drawn at 2x then reduced)."""
    w, h = size
    m = Image.new("L", (w * 2, h * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * 2 - 1, h * 2 - 1), radius=radius * 2, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def _shadow(canvas, box, radius, long_edge, opacity):
    x, y, w, h = box
    m = max(4, round(long_edge * 0.03))
    sh = Image.new("L", (w + 2 * m, h + 2 * m), 0)
    ImageDraw.Draw(sh).rounded_rectangle((m, m, m + w, m + h), radius=radius, fill=round(255 * opacity))
    sh = sh.filter(ImageFilter.GaussianBlur(m / 2.5))
    x0, y0 = x - m, y - m + round(m * 0.35)
    canvas.paste((0, 0, 0), (x0, y0, x0 + sh.width, y0 + sh.height), sh)


def _blur_background(img, cw, ch):
    """Photo scaled to cover the canvas, heavily blurred (computed at 1/4 size for speed) and slightly darkened."""
    sw, sh = max(8, cw // 4), max(8, ch // 4)
    s = max(sw / img.width, sh / img.height)
    small = img.resize((max(sw, round(img.width * s)), max(sh, round(img.height * s))), Image.BILINEAR)
    l, t = (small.width - sw) // 2, (small.height - sh) // 2
    small = small.crop((l, t, l + sw, t + sh)).filter(ImageFilter.GaussianBlur(max(sw, sh) * 0.045))
    bg = small.resize((cw, ch), Image.BICUBIC)
    return Image.blend(bg, Image.new("RGB", (cw, ch), (0, 0, 0)), 0.28)


_ORIENT_OPS = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180, 4: Image.Transpose.FLIP_TOP_BOTTOM,
               5: Image.Transpose.TRANSPOSE, 6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE,
               8: Image.Transpose.ROTATE_90}


def _to_rgb(img):
    """RGB copy that does not mangle transparency (-> white) or 16-bit data (-> scaled to 8-bit)."""
    if img.mode == "RGB":
        return img
    if img.mode in ("I;16", "I;16L", "I;16B", "I"):
        img = img.point(lambda v: v * (1 / 256)).convert("L")
    if img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        return Image.alpha_composite(Image.new("RGBA", rgba.size, (255, 255, 255, 255)), rgba).convert("RGB")
    return img.convert("RGB")


def _rgb_icc(icc):
    """Keep an embedded ICC profile only when it really is an RGB profile (the output is always RGB)."""
    if not icc:
        return None
    try:
        prof = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        return icc if prof.profile.xcolor_space.strip() == "RGB" else None
    except Exception:
        return None


def open_image(path, max_edge=0):
    """Open a photo safely: whitelisted decoders, pixel limit, and (JPEG) decode at reduced size when possible."""
    img = Image.open(path, formats=INPUT_FORMATS)
    if img.width * img.height > MAX_PIXELS:
        img.close()
        raise ValueError("image too large")
    if max_edge and img.format == "JPEG":
        img.draft("RGB", (max_edge, max_edge))       # result is still >= max_edge on both sides
    return img


def output_name(src):
    """Output file name; non-JPEG sources carry their extension so that a.jpg and a.png do not collide."""
    suffix = src.suffix.lower()
    return src.stem + ("_ig.jpg" if suffix in (".jpg", ".jpeg") else "_%s_ig.jpg" % suffix.lstrip("."))


def cleanup_temp(out_dir, older_than=60):
    """Remove stale temp files left behind by an interrupted run (only our own prefix, regular files)."""
    now = time.time()
    try:
        for p in out_dir.glob(".ig_tmp_*.jpg"):
            try:
                if p.is_file() and not p.is_symlink() and now - p.stat().st_mtime > older_than:
                    p.unlink()
            except OSError:
                pass
    except OSError:
        pass


def build_canvas(img, ratio, thickness, max_edge, footer=None, style="white", corner=None):
    """Return a new RGB image: `img` on a canvas (white / rounded / blurred), optionally with a camera-info footer."""
    if img.mode == "RGB" and max_edge and max(img.size) > max_edge:
        # shrink first: transposing a full-size copy of a big photo is the memory peak
        orient = img.getexif().get(0x0112)
        s = max_edge / max(img.size)
        img = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
        if orient in _ORIENT_OPS:
            img = img.transpose(_ORIENT_OPS[orient])
    else:
        img = _to_rgb(ImageOps.exif_transpose(img))

    w, h = img.size
    if max_edge and max(w, h) > max_edge:  # shrink only
        s = max_edge / max(w, h)
        w, h = max(1, round(w * s)), max(1, round(h * s))
        img = img.resize((w, h), Image.LANCZOS)
    long_edge = max(w, h)

    if style not in STYLES:
        style = "white"
    base_band = round(long_edge * FOOTER_H)
    band_h = round(base_band * footer.get("height_scale", 1.0)) if footer else base_band
    is_blur = style in ("blur", "blur_square")
    theme = THEME_LIGHT_TEXT if is_blur else THEME_DARK_TEXT
    parts = render_footer(footer, base_band, theme) if footer else None
    if ratio == "original" and not parts and style == "white":
        return img
    if ratio == "original":
        ratio = "even"  # footer / styled frames need a border to live in

    pad = round(long_edge * thickness / PAD_DIVISOR)
    fh = band_h if parts else 0
    if parts:                                   # grow the strip when the text block is taller than the default band
        need = max((p.height for p in parts if p is not None), default=0)
        fh = max(fh, need + round(band_h * 0.6) - pad)
    bw, bh = w + 2 * pad, h + 2 * pad + fh
    cw, ch = bw, bh
    if ratio != "even":
        rw, rh = RATIOS[ratio]
        target = rw / rh
        if cw / ch < target:
            cw = round(ch * target)
        else:
            ch = round(cw / target)

    canvas = _blur_background(img, cw, ch) if is_blur else Image.new("RGB", (cw, ch), WHITE)
    ox, oy = (cw - bw) // 2, (ch - bh) // 2
    px, py = ox + pad, oy + pad
    if style == "white":
        canvas.paste(img, (px, py))
    elif style == "blur_square":                       # blurred background, square photo (shadow only)
        _shadow(canvas, (px, py, w, h), 0, long_edge, 0.50)
        canvas.paste(img, (px, py))
    else:
        r = max(2, round(long_edge * (CORNER if corner is None else _clamp(corner, 0.001, 0.08, CORNER))))
        _shadow(canvas, (px, py, w, h), r, long_edge, 0.50 if is_blur else 0.22)
        canvas.paste(img, (px, py), _rounded_mask((w, h), r))

    if parts:
        y_mid = py + h + (pad + fh) / 2          # centre of the strip under the photo
        gap_mid = round(base_band * 0.5)
        if len(parts) == 1:
            p = parts[0]
            if p.width > w:
                p = p.resize((w, max(1, round(p.height * w / p.width))), Image.LANCZOS)
            canvas.paste(p, (px + (w - p.width) // 2, round(y_mid - p.height / 2)), p)
        else:
            left, right = parts[0], parts[1]
            centre = parts[2] if len(parts) > 2 else None
            widths = [im.width for im in (left, right, centre) if im is not None]
            total = sum(widths) + gap_mid * (len(widths) - 1)
            s = min(1.0, w / total) if total else 1.0

            def fit(im):
                if im is None or s >= 1:
                    return im
                return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)

            left, right, centre = fit(left), fit(right), fit(centre)
            if left is not None:
                canvas.paste(left, (px, round(y_mid - left.height / 2)), left)
            if right is not None:
                canvas.paste(right, (px + w - right.width, round(y_mid - right.height / 2)), right)
            if centre is not None:        # middle of the free space between the two blocks
                lend = px + (left.width if left is not None else 0)
                rstart = px + w - (right.width if right is not None else 0)
                cx = (lend + rstart - centre.width) // 2
                cx = min(max(cx, lend), max(lend, rstart - centre.width))
                canvas.paste(centre, (cx, round(y_mid - centre.height / 2)), centre)
    return canvas


def process(src, out_dir, opts, name=None):
    dst = out_dir / (name or output_name(src))
    if dst.exists() and not opts.overwrite:
        print("skip (exists): %s" % dst.name)
        return None
    with open_image(src, opts.max_edge) as img:
        icc = _rgb_icc(img.info.get("icc_profile"))
        footer = make_footer(img, opts)
        canvas = build_canvas(img, opts.ratio, opts.thickness, opts.max_edge, footer, getattr(opts, "style", "white"),
                              corner=getattr(opts, "corner", None))
    # atomic write so nothing ever sees a half-written file
    fd, tmp = tempfile.mkstemp(prefix=".ig_tmp_", suffix=".jpg", dir=str(out_dir))
    os.close(fd)
    try:
        kw = dict(quality=opts.quality, subsampling=0, optimize=True)
        if icc:
            kw["icc_profile"] = icc
        canvas.save(tmp, "JPEG", **kw)  # no EXIF is written to the output
        os.chmod(tmp, 0o666 & ~_UMASK)
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    print("done: %s -> %s (%dx%d)" % (src.name, dst.name, *canvas.size))
    return dst


def wait_until_stable(path, tries=20, interval=0.5, stop=None):
    """LR writes the file progressively; wait until its size stops changing (a file untouched for 3 s is stable)."""
    last = -1
    for _ in range(tries):
        if stop is not None and stop.is_set():
            return False
        try:
            st = path.stat()
        except OSError:
            return False
        size = st.st_size
        if size > 0 and time.time() - st.st_mtime > 3:
            return True
        if size == last and size > 0:
            return True
        last = size
        time.sleep(interval)
    return False


def candidates(in_dir):
    for p in sorted(in_dir.iterdir()):
        if p.is_file() and not p.is_symlink() and p.suffix.lower() in EXTS and not p.name.startswith("."):
            yield p


def safe_process(src, out_dir, opts):
    """Process one file; returns True on success (or skip), False on failure."""
    try:
        if wait_until_stable(src):
            process(src, out_dir, opts)
            return True
        print("skip (unreadable/unstable): %s" % src.name, file=sys.stderr)
    except Exception as exc:  # one bad file must not kill the watcher
        print("error: %s (%s)" % (src.name, type(exc).__name__), file=sys.stderr)
    return False


def validate(ratio, thickness, max_edge, quality, footer_layout="classic3", footer_fields=FOOTER_FIELDS,
             style="white"):
    """Return an error string, or None if the options are acceptable."""
    if ratio not in RATIO_CHOICES:
        return "unknown ratio"
    if not 0 <= thickness <= 50:
        return "thickness must be in [0, 50]"
    if max_edge != 0 and not 256 <= max_edge <= 20000:
        return "max-edge must be 0 (no limit) or in [256, 20000]"
    if not 1 <= quality <= 100:
        return "quality must be in [1, 100]"
    if footer_layout not in FOOTER_LAYOUTS:
        return "unknown footer layout"
    if not set(footer_fields) <= set(FOOTER_FIELDS):
        return "unknown footer field"
    if style not in STYLES:
        return "unknown style"
    return None


def _same_dir(a, b):
    try:
        return a.samefile(b)           # handles case-insensitive volumes and symlinks
    except OSError:
        return a == b


def folders_conflict(in_dir, out_dir):
    """True when the two folders are the same or one contains the other."""
    if _same_dir(in_dir, out_dir):
        return True
    return any(_same_dir(par, in_dir) for par in out_dir.parents) or any(_same_dir(par, out_dir) for par in in_dir.parents)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["watch", "once", "file"])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--ratio", choices=RATIO_CHOICES, default="4:5")
    ap.add_argument("--style", choices=STYLES, default="white")
    ap.add_argument("--thickness", type=float, default=10.0, help="0-50, like the LR slider (default 10)")
    ap.add_argument("--max-edge", type=int, default=2048, help="long-edge cap in px, 0 = keep original size")
    ap.add_argument("--quality", type=int, default=95)
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--footer", action="store_true", help="draw camera info under the photo")
    ap.add_argument("--footer-layout", choices=FOOTER_LAYOUTS, default="classic3")
    ap.add_argument("--footer-divider", action="store_true", help="thin divider line in the classic3 layout")
    ap.add_argument("--footer-fields", default=",".join(FOOTER_FIELDS),
                    help="comma list of: " + ",".join(FOOTER_FIELDS))
    ap.add_argument("--footer-text-scale", type=float, default=1.0, help="0.5-2.0 (default 1)")
    ap.add_argument("--footer-logo-scale", type=float, default=1.0, help="0.4-2.5 (default 1)")
    ap.add_argument("--footer-height-scale", type=float, default=1.0, help="0.6-2.5 (default 1)")
    ap.add_argument("--footer-color", default=None, help="text colour as #RRGGBB (default: automatic)")
    ap.add_argument("--footer-no-bold", action="store_true", help="regular instead of bold for the main text")
    ap.add_argument("--footer-date-format", choices=DATE_FORMATS, default="ymd_dot")
    ap.add_argument("--footer-logo-pos", choices=LOGO_POSITIONS, default="left", help="classic3 only")
    ap.add_argument("--footer-custom-text", default="", help="extra line, e.g. your IG handle (max 60 chars)")
    ap.add_argument("--footer-main", choices=["model", "lens"], default="model", help="classic3: bold line on the left")
    ap.add_argument("--footer-mirror", action="store_true", help="classic3: parameters left, logo + camera right")
    ap.add_argument("--footer-exposure-items", default=",".join(DEFAULT_EXPOSURE_ITEMS),
                    help="comma list of: " + ",".join(EXPOSURE_KEYS))
    ap.add_argument("--footer-exposure-order", choices=EXPOSURE_ORDERS, default="std")
    ap.add_argument("--footer-font", default="auto", help="auto, a system font key, or user:<file in ./fonts/>")
    opts = ap.parse_args()
    opts.footer_fields = [f for f in opts.footer_fields.split(",") if f]
    opts.footer_bold = not opts.footer_no_bold
    opts.footer_exposure_items = [f for f in opts.footer_exposure_items.split(",") if f]
    if not opts.footer_fields:
        ap.error("--footer-fields must not be empty")
    if opts.footer_font != valid_font_key(opts.footer_font):
        ap.error("unknown --footer-font (try one of: %s)" % ", ".join(k for k, _ in available_fonts()))
    if opts.footer_color is not None and _hex_color(opts.footer_color) is None:
        ap.error("--footer-color must look like #RRGGBB")

    err = validate(opts.ratio, opts.thickness, opts.max_edge, opts.quality, opts.footer_layout,
                   opts.footer_fields, opts.style)
    if err:
        ap.error(err)

    src_in = Path(opts.input).expanduser().resolve()
    out_dir = Path(opts.output).expanduser().resolve()
    if not src_in.exists():
        ap.error("input not found: %s" % src_in)
    in_dir = src_in if opts.mode != "file" else src_in.parent
    if folders_conflict(in_dir, out_dir):
        ap.error("output folder must be separate from (and not nested with) the input folder")
    out_dir.mkdir(parents=True, exist_ok=True)

    if opts.mode == "file":
        if src_in.suffix.lower() not in EXTS:
            ap.error("unsupported file type: %s" % src_in.suffix)
        sys.exit(0 if safe_process(src_in, out_dir, opts) else 1)
    if not src_in.is_dir():
        ap.error("input must be a folder in this mode")

    cleanup_temp(out_dir)
    seen = set()
    failed = 0
    print(("watching %s -> %s (Ctrl+C to stop)" if opts.mode == "watch" else "processing %s -> %s")
          % (src_in, out_dir))
    try:
        while True:
            try:
                for p in candidates(src_in):
                    try:
                        key = (p.name, p.stat().st_mtime_ns)
                    except OSError:
                        continue                     # vanished between listing and stat
                    if key not in seen:
                        seen.add(key)
                        if not safe_process(p, out_dir, opts):
                            failed += 1
            except OSError as exc:
                print("cannot read %s (%s)" % (src_in, type(exc).__name__), file=sys.stderr)
            if opts.mode == "once":
                break
            time.sleep(2)
    except KeyboardInterrupt:
        print("\nstopped")
    if opts.mode == "once" and failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
