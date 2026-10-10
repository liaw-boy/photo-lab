#!/usr/bin/env python3
"""Desktop GUI for ig_border: photo strip, live preview, batch processing."""
import copy
import json
import math
import os
import re
import queue
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
from argparse import Namespace
from pathlib import Path
from tkinter import colorchooser, filedialog, messagebox

import customtkinter as ctk
try:
    from customtkinter.windows.widgets.appearance_mode import AppearanceModeTracker
except ImportError:      # live light/dark switching of the tiles is a nicety, not a requirement
    class AppearanceModeTracker:
        add = remove = staticmethod(lambda *a, **k: None)
from PIL import Image, ImageDraw, ImageOps, ImageTk

import ig_border

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAVE_DND = True
except Exception:  # drag & drop is optional
    HAVE_DND = False

CONFIG = Path.home() / ".ig_border_gui.json"
RATIOS = [("原始", "original"), ("平均", "even"), ("1:1", "1:1"), ("2:3", "2:3"), ("3:2", "3:2"),
          ("4:5", "4:5"), ("3:4", "3:4"), ("5:4", "5:4"), ("9:16", "9:16"), ("16:9", "16:9")]
LAYOUT_LABELS = {"經典三欄": "classic3", "置中單行": "center1", "置中兩行": "center2", "左右分開": "split",
                 "只放 logo": "logo", "自訂樣式": "custom"}
STYLE_LABELS = {"白底": "white", "圓角": "rounded", "模糊": "blur"}
FIELD_LABELS = [("相機", "camera"), ("鏡頭", "lens"), ("拍攝參數", "exposure"), ("日期", "date")]
DATE_LABELS = {"2026.05.25": "ymd_dot", "2026-05-25": "ymd_dash", "2026/05/25": "ymd_slash",
               "25 May 2026": "dmy_text", "May 25, 2026": "mdy_text",
               "2026-05-25 14:22": "ymd_dash_hm", "2026-05-25 14:22:50": "ymd_dash_hms",
               "25 May 2026 14:22": "dmy_hm", "May 25, 2026 at 2:22:50 PM": "mdy_at_12h"}
EXPO_LABELS = [("焦距", "focal"), ("光圈", "aperture"), ("快門", "shutter"), ("ISO", "iso")]
EXPO_ORDER_LABELS = {"標準：焦距 光圈 快門 ISO": "std", "ISO 優先：ISO 光圈 快門 焦距": "iso_first"}
DEFAULT_FONT_LABEL = ig_border.FONT_LABELS["auto"]
MAX_PRESETS = 50
MAX_RECENT = 5
MAX_SOURCES = 30       # remembered source folders
STYLES_DIR = Path(__file__).resolve().parent.parent / "styles"
ICON_FILE = Path(__file__).resolve().parent.parent / "assets" / "icon_1024.png"
STYLE_EXT = ".igstyle.json"
TOKEN_LABELS = {"": "（空）", "logo": "品牌 logo", "model": "機型", "model_auto": "機型（自動）", "brand_model": "品牌＋機型",
                "brand": "品牌",
                "lens": "鏡頭", "focal": "焦距", "aperture": "光圈", "shutter": "快門", "iso": "ISO",
                "exposure": "曝光參數", "date": "日期時間", "custom": "自訂文字"}
TOKEN_BY_LABEL = {v: k for k, v in TOKEN_LABELS.items()}
LINE_SIZE_LABELS = {"小": 85, "稍小": 95, "中": 100, "大": 125, "特大": 150}
TONE_LABELS = {"主要（深）": "strong", "一般": "normal", "次要（灰）": "weak", "自訂色…": "custom"}
ALIGN_LABELS = {"靠左": "left", "置中": "center", "靠右": "right"}
BLOCK_TITLES = {"left": "左側區塊", "center": "中間區塊", "right": "右側區塊"}
LAYOUT_NAME = {v: k for k, v in LAYOUT_LABELS.items()}
LOGO_POS_LABELS = {"機型左側": "left", "右欄左側": "right", "兩欄中間": "center"}
COLOR_LABELS = ["自動", "黑色", "深灰", "白色", "自訂…"]
COLOR_VALUES = {"黑色": "#111111", "深灰": "#444444", "白色": "#FFFFFF"}
DEFAULT_CUSTOM_COLOR = "#C0392B"
BUILTIN_PRESETS = {
    "IG 4:5 白框": {"ratio": "4:5", "thickness": 10, "style": "white", "footer": False},
    "IG 1:1 白框": {"ratio": "1:1", "thickness": 10, "style": "white", "footer": False},
    "IG 4:5 + 相機資訊": {"ratio": "4:5", "thickness": 10, "style": "white", "footer": True, "layout": "classic3"},
    "模糊背景 4:5 + 相機資訊": {"ratio": "4:5", "thickness": 12, "style": "blur", "footer": True, "layout": "classic3"},
    "參考樣式 A：鏡頭粗體 + logo + 分隔線": {
        "ratio": "even", "thickness": 6, "style": "white", "footer": True, "layout": "classic3", "main": "lens",
        "logo_pos": "right", "divider": True, "date_format": "ymd_dash_hm", "mirror": False, "bold": True,
        "exposure_items": ["aperture", "shutter", "iso"], "exposure_order": "std", "font": "auto"},
    "參考樣式 B：左右對調 + SF Pro": {
        "ratio": "even", "thickness": 6, "style": "white", "footer": True, "layout": "classic3", "main": "model",
        "logo_pos": "left", "divider": True, "date_format": "mdy_at_12h", "mirror": True, "bold": True,
        "exposure_items": ["aperture", "shutter", "iso"], "exposure_order": "iso_first", "font": "sf"},
}
PRESET_PLACEHOLDER = "選擇預設…"
# A built-in preset is a complete look: anything it does not mention goes back to these values, so applying it gives
# the same result whatever the previous state was. (Your own text, colour pick, output size, custom style stay.)
PRESET_BASE = {"ratio": "4:5", "thickness": 10, "style": "white", "footer": False, "layout": "classic3",
               "fields": ["camera", "lens", "exposure", "date"], "divider": False, "center_divider": True,
               "text_scale": 100,
               "logo_scale": 100, "height_scale": 100, "bold": True, "color_choice": "自動",
               "date_format": "ymd_dot", "logo_pos": "left", "main": "model", "mirror": False,
               "exposure_items": ["aperture", "shutter", "iso"], "exposure_order": "std", "font": "auto"}
# One-click footer looks. Only the footer is touched (not ratio / border / font / colour / sizes), and every look
# starts from FOOTER_BASE so applying it gives the same result whatever the previous state was.
FOOTER_BASE = {"footer": True, "layout": "classic3", "fields": ["camera", "lens", "exposure", "date"],
               "divider": False, "center_divider": True, "bold": True, "logo_pos": "left", "main": "model", "mirror": False,
               "exposure_items": ["aperture", "shutter", "iso"], "exposure_order": "std"}
FOOTER_LOOKS = {
    "經典": {},
    "簡約置中": {"layout": "center1", "fields": ["camera", "exposure"]},
    "鏡頭主角": {"main": "lens", "logo_pos": "right", "divider": True},
    "只放 logo": {"layout": "logo"},
    "完整資訊": {"layout": "center2", "exposure_items": ["focal", "aperture", "shutter", "iso"]},
}
# What each layout actually uses, so the rest can be greyed out instead of explained in small print.
CLASSIC_ONLY = ("divider", "main", "mirror", "logo_pos")
FIELDS_LAYOUTS = ("classic3", "center1", "center2", "split")
SIZE_LABELS = {"2048": 2048, "1350": 1350, "原尺寸": 0}
DEFAULT_SIZE = "2048"
PREVIEW_SRC_EDGE = 1800  # preview works on a reduced copy; padding is proportional so it looks identical
MAX_SCALE = 4.0          # maximum zoom: 400% of the rendered canvas pixels
ZOOM_MIN = 0.2           # minimum zoom, relative to "fit to window" (fit = 1.0)
MAX_PHOTOS = 300         # the strip lists at most this many photos
THUMB = (104, 78)

# Two colour sets (light, dark): "darkroom" = warm black with a safelight-amber accent (default), "carbon" = neutral
# charcoal with a blue accent. The accent is a deep amber so that white text on it stays readable. The choice is stored
# in the settings file and read once at start-up.
PALETTES = {
    "darkroom": {"label": "暗房", "ACCENT": ("#C9660A", "#CC6A0A"), "ACCENT_HOVER": ("#B35A08", "#E07A14"),
                 "CARD": ("#ffffff", "#1B1511"), "BTN": ("#eceef2", "#2A211B"), "BTN_HOVER": ("#dfe2e8", "#382C24"),
                 "MUTED": ("#6b7280", "#9A8B7C"), "WINDOW_BG": ("#f2f3f6", "#0E0A08"),
                 "PV_BG": ("#e3e6ec", "#070504"), "THUMB_BG": (27, 21, 17)},
    "carbon": {"label": "炭灰", "ACCENT": ("#3478f6", "#3d80f2"), "ACCENT_HOVER": ("#2a66d9", "#5c95f5"),
               "CARD": ("#ffffff", "#24262a"), "BTN": ("#eceef2", "#2f3238"), "BTN_HOVER": ("#dfe2e8", "#3a3d44"),
               "MUTED": ("#6b7280", "#8d93a0"), "WINDOW_BG": ("#f2f3f6", "#1b1c1f"),
               "PV_BG": ("#e3e6ec", "#141518"), "THUMB_BG": (30, 32, 36)},
}
DEFAULT_THEME = "darkroom"


def _stored_theme():
    """The palette name from the settings file (it is read before the window exists); anything odd -> default."""
    try:
        if CONFIG.stat().st_size <= 1_000_000:
            name = json.loads(CONFIG.read_text()).get("theme")
            if isinstance(name, str) and name in PALETTES:
                return name
    except (OSError, ValueError, AttributeError):
        pass
    return DEFAULT_THEME


THEME = _stored_theme()
ACCENT, ACCENT_HOVER = PALETTES[THEME]["ACCENT"], PALETTES[THEME]["ACCENT_HOVER"]
CARD, BTN, BTN_HOVER = PALETTES[THEME]["CARD"], PALETTES[THEME]["BTN"], PALETTES[THEME]["BTN_HOVER"]
MUTED, WINDOW_BG, PV_BG = PALETTES[THEME]["MUTED"], PALETTES[THEME]["WINDOW_BG"], PALETTES[THEME]["PV_BG"]
THUMB_BG = PALETTES[THEME]["THUMB_BG"]       # every thumbnail sits on a canvas of exactly THUMB size in this colour
GREEN = "#2fb350"
AMBER = ("#c27c0e", "#e0a030")
RED = "#e5484d"
RED_HOVER = "#cf3a3f"
# Status shown on a thumbnail while exporting. It is drawn INTO the thumbnail as a small translucent pill
# (a widget laid over an image cannot have transparent rounded corners).
STATE_TEXT = {"待處理": "", "已有輸出": "", "處理中": "處理中", "完成": "完成", "略過": "略過", "失敗": "失敗"}
PILL_COLORS = {"完成": (96, 210, 128), "失敗": (255, 112, 112), "略過": (244, 180, 78), "處理中": (118, 172, 255),
               "已有輸出": (205, 210, 220)}

ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")

_Base = ctk.CTk
if HAVE_DND:
    class _Base(ctk.CTk, TkinterDnD.DnDWrapper):  # noqa: F811
        pass


def decode_touchpad(delta):
    """Tk 9 packs a trackpad scroll as (dx << 16) | (dy & 0xffff), each a signed 16-bit value."""
    try:
        d = int(delta) & 0xFFFFFFFF
    except (TypeError, ValueError):
        return 0, 0
    dx, dy = (d >> 16) & 0xFFFF, d & 0xFFFF
    return (dx - 0x10000 if dx >= 0x8000 else dx), (dy - 0x10000 if dy >= 0x8000 else dy)


def _scrollbar_set(self, start, end):
    """customtkinter's CTkScrollbar.set() redraws immediately and ends with update_idletasks(), which re-enters
    the layout that just called it: with a few dozen thumbnails in the strip every change cost seconds (150 tiles:
    ~50 s). Draw once when idle instead; a change that arrives during the draw only marks it dirty."""
    self._start_value = float(start)
    self._end_value = float(end)
    if self._draw_busy:
        self._draw_dirty = True
    elif not self._draw_sched:
        self._draw_sched = True
        self.after_idle(self._run_draw)


def _scrollbar_run_draw(self):
    self._draw_sched = False
    try:
        if not self.winfo_exists():
            return
        self._draw_busy = True
        for _ in range(3):
            self._draw_dirty = False
            self._draw()
            if not self._draw_dirty:
                break
    except tk.TclError:
        pass
    finally:
        self._draw_busy = False


ctk.CTkScrollbar._draw_busy = False
ctk.CTkScrollbar._draw_dirty = False
ctk.CTkScrollbar._draw_sched = False
ctk.CTkScrollbar._run_draw = _scrollbar_run_draw
ctk.CTkScrollbar.set = _scrollbar_set


class SmoothScrollFrame(ctk.CTkScrollableFrame):
    """CTkScrollableFrame whose wheel handling copes with Tk 9 on macOS (120-step mouse wheels,
    tiny or fractional trackpad deltas) instead of silently failing. Works for both orientations."""

    _acc = 0.0

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        try:   # Tk 9 on macOS sends trackpad scrolling as <TouchpadScroll>, not <MouseWheel>
            self.bind_all("<TouchpadScroll>", self._touchpad_all, add="+")
        except tk.TclError:
            pass

    def _touchpad_all(self, event):
        try:
            if not self._check_if_valid_scroll(event.widget):
                return
            dx, dy = decode_touchpad(event.delta)
            horizontal = self._orientation == "horizontal"
            amount = (dx if abs(dx) > abs(dy) else dy) if horizontal else dy
            view = self._parent_canvas.xview if horizontal else self._parent_canvas.yview
            scroll = self._parent_canvas.xview_scroll if horizontal else self._parent_canvas.yview_scroll
            if amount == 0 or view() == (0.0, 1.0):
                return
            self._acc += -amount / 8.0              # 1 px per trackpad step (native speed); one scroll unit is 8 px
            n = int(self._acc)
            self._acc -= n
            if n:
                scroll(n, "units")
        except (tk.TclError, TypeError, ValueError, AttributeError):
            pass

    def _check_if_valid_scroll(self, widget):
        """customtkinter refuses to scroll while the pointer is over a slider (it expects the slider to use the
        wheel). Our sliders ignore the wheel, so the page must keep scrolling when the pointer is on one."""
        try:
            if widget == self._parent_canvas:
                return True
            if isinstance(widget, (ctk.CTkScrollbar, ctk.CTkTextbox)):
                return False
            if isinstance(widget, ctk.CTkScrollableFrame):
                return widget._parent_canvas == self._parent_canvas
            return widget.master is not None and self._check_if_valid_scroll(widget.master)
        except AttributeError:
            return False

    def _mouse_wheel_all(self, event):
        try:
            if not self._check_if_valid_scroll(event.widget):
                return
            d = float(event.delta)
            horizontal = self._orientation == "horizontal"
            view = self._parent_canvas.xview if horizontal else self._parent_canvas.yview
            scroll = self._parent_canvas.xview_scroll if horizontal else self._parent_canvas.yview_scroll
            if d == 0 or view() == (0.0, 1.0):
                return
            k = 3.0 if horizontal else 1.0
            units = (-d / 120 * 4 if abs(d) >= 120 else -d * 1.5) * k
            self._acc += units
            n = int(self._acc)
            self._acc -= n
            if n:
                scroll(n, "units")
        except (tk.TclError, TypeError, ValueError, AttributeError):
            pass


SCROLLBAR = dict(scrollbar_button_color=("#b4b9c4", "#5a5f69"), scrollbar_button_hover_color=("#979dab", "#737985"))


def _pill_font(size):
    f = ig_border._cjk_font(size)
    return f or ig_border._font(size, True, "auto")


def status_pill(base, state):
    """`base` (PIL, thumbnail size) with a rounded translucent pill for `state` in its lower-left corner.
    Drawn at 4x and reduced, so the edges are smooth. Returns `base` unchanged when there is nothing to show."""
    text = STATE_TEXT.get(state, "")
    color = PILL_COLORS.get(state)
    if not text or color is None:
        return base
    SS, H, PADX, ICON, GAP = 4, 20, 8, 10, 5
    font = _pill_font(11 * SS)
    l, t, r, b = font.getbbox(text)
    tw = r - l
    W = PADX * 2 + ICON + GAP + round(tw / SS)
    pill = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(pill)
    d.rounded_rectangle((0, 0, W * SS - 1, H * SS - 1), radius=H * SS // 2, fill=(16, 18, 22, 190))
    lw = round(1.9 * SS)
    ix, iy, isz = PADX * SS, (H - ICON) * SS // 2, ICON * SS
    col = color + (255,)
    if state == "完成":
        d.line([(ix + .10 * isz, iy + .55 * isz), (ix + .40 * isz, iy + .85 * isz), (ix + .92 * isz, iy + .18 * isz)],
               fill=col, width=lw, joint="curve")
    elif state == "失敗":
        d.line([(ix + .15 * isz, iy + .15 * isz), (ix + .85 * isz, iy + .85 * isz)], fill=col, width=lw)
        d.line([(ix + .85 * isz, iy + .15 * isz), (ix + .15 * isz, iy + .85 * isz)], fill=col, width=lw)
    elif state == "略過":
        d.line([(ix + .12 * isz, iy + .5 * isz), (ix + .88 * isz, iy + .5 * isz)], fill=col, width=lw)
    elif state == "處理中":
        for k in range(3):
            cx = ix + (.16 + .34 * k) * isz
            d.ellipse((cx - .11 * isz, iy + .5 * isz - .11 * isz, cx + .11 * isz, iy + .5 * isz + .11 * isz), fill=col)
    else:                                                    # 已有輸出: a small ring
        d.ellipse((ix + .12 * isz, iy + .12 * isz, ix + .88 * isz, iy + .88 * isz), outline=col, width=lw)
    d.text(((PADX + ICON + GAP) * SS - l, (H * SS - (b - t)) // 2 - t), text, font=font, fill=col)
    pill = pill.resize((W, H), Image.LANCZOS)
    out = base.convert("RGBA")
    out.alpha_composite(pill, (7, max(0, base.height - H - 7)))
    return out.convert("RGB")


def ratio_icon(val, color, px=56):
    """Small pictogram of a ratio: outer frame (the canvas) with a filled photo inside."""
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = px - 8

    def centered(w, h):
        return ((px - w) // 2, (px - h) // 2, (px + w) // 2, (px + h) // 2)

    if val == "original":
        w, h = box, round(box * 2 / 3)
        d.rounded_rectangle(centered(w, h), radius=3, fill=color)
        return img
    if val == "even":
        ow, oh = box, round(box * 0.74)
    else:
        rw, rh = ig_border.RATIOS[val]
        s = box / max(rw, rh)
        ow, oh = round(rw * s), round(rh * s)
    d.rounded_rectangle(centered(ow, oh), radius=4, outline=color, width=3)
    iw, ih = round(ow * 0.62), round(oh * 0.62)
    if val == "even":
        iw, ih = ow - 16, oh - 16
    elif val in ("3:2", "16:9", "5:4"):
        iw, ih = round(ow * 0.7), round(oh * 0.52)
    d.rounded_rectangle(centered(max(iw, 6), max(ih, 6)), radius=2, fill=color)
    return img


def place_over_app(win, app, w, h):
    """Centre a secondary window over the main window, kept fully on the screen (a bare Toplevel opens top-left)."""
    w = min(w, win.winfo_screenwidth())
    h = min(h, win.winfo_screenheight() - 80)
    x = app.winfo_rootx() + (app.winfo_width() - w) // 2
    y = app.winfo_rooty() + (app.winfo_height() - h) // 2
    x = max(0, min(x, win.winfo_screenwidth() - w))
    y = max(30, min(y, win.winfo_screenheight() - h - 50))
    win.geometry("%dx%d+%d+%d" % (w, h, x, y))


class StyleEditor(ctk.CTkToplevel):
    """Design the footer: three blocks (left / centre / right), each at most two lines, each line up to three
    items (model, lens, ISO, date, logo ...) with its own weight, size, tone and separators. It always starts from
    the style that is currently selected in the main window (a built-in layout is converted to these parameters)
    and follows the main window while it is open. Editing switches the main window to 自訂樣式."""

    ITEMS = 3

    def __init__(self, app):
        super().__init__(app)
        self.withdraw()  # stay hidden while the widgets are built, then show the finished window at once
        self.app = app
        self.title("樣式編輯器")
        self.configure(fg_color=WINDOW_BG)
        self.geometry("1180x880")
        self.minsize(1120, 860)
        self.transient(app)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.loading = False
        self.job = None
        self.blocks = {}
        self.divider_var = tk.BooleanVar(value=False)
        self.pv_photo = None
        self.pv_key = None
        self.tick_job = None
        self.build()
        self.load(app.effective_style())
        app.footer_on.set(True)
        self.render_preview()
        self.update_idletasks()
        self.place_over(app)
        self.deiconify()
        self.lift()
        app.schedule_preview()
        self.tick()

    # ---- live preview of the footer (what the user is designing) ----
    def place_over(self, app, w=1180, h=880):
        place_over_app(self, app, w, h)

    def render_preview(self):
        """Draw the footer strip with the current photo / frame style / all footer settings."""
        app = self.app
        src = app.preview_src
        if src is None:
            return
        info = ig_border.SAMPLE_INFO if app.preview_info is None else app.preview_info
        try:
            footer = ig_border.make_footer(src, Namespace(**app.footer_opts()), info=info)
            canvas = ig_border.build_canvas(src, "even", round(app.thick_var.get()), 0, footer,
                                            STYLE_LABELS.get(app.style_var.get(), "white"))
        except Exception:
            return
        w, h = canvas.size
        strip = canvas.crop((0, int(h * 0.62), w, h))                 # the footer and the bottom of the photo
        box_w = max(400, self.winfo_width() - 56)
        scale = min(box_w / strip.width, 190 / strip.height)
        strip = strip.resize((max(1, round(strip.width * scale)), max(1, round(strip.height * scale))), Image.LANCZOS)
        framed = Image.new("RGB", (strip.width + 2, strip.height + 2), (150, 150, 150))
        framed.paste(strip, (1, 1))
        if (self.pv_photo is not None and self.pv_photo.width() == framed.width
                and self.pv_photo.height() == framed.height):
            self.pv_photo.paste(framed)
        else:
            self.pv_photo = ImageTk.PhotoImage(framed)
            self.pv_label.configure(image=self.pv_photo)
        self.pv_key = app.params_key()

    def tick(self):
        """Follow changes made in the main window (font, frame style, another photo ...)."""
        try:
            if self.app.params_key() != self.pv_key and self.job is None:
                self.render_preview()
        except Exception:
            pass
        self.tick_job = self.after(400, self.tick)

    # ---- layout ----
    def build(self):
        self.columnconfigure(0, weight=1)
        ctk.CTkLabel(self, text="資訊列樣式編輯器", font=ctk.CTkFont(size=18, weight="bold")
                     ).grid(row=0, column=0, sticky="w", padx=20, pady=(16, 0))
        self.origin_lbl = ctk.CTkLabel(self, text="", text_color=ACCENT, font=ctk.CTkFont(size=12), anchor="w")
        self.origin_lbl.grid(row=1, column=0, sticky="w", padx=20, pady=(2, 0))
        ctk.CTkLabel(self, text="左、中、右三區塊，每塊最多兩行、每行三個項目。「機型（自動）」＝有 logo 只顯示機型，沒有就加品牌名。",
                     text_color=MUTED, font=ctk.CTkFont(size=12), wraplength=1040, justify="left", anchor="w"
                     ).grid(row=2, column=0, sticky="w", padx=20, pady=(2, 6))
        start = ctk.CTkFrame(self, fg_color="transparent")        # templates: start from a look instead of a blank grid
        start.grid(row=2, column=0, sticky="e", padx=20)
        ctk.CTkLabel(start, text="從樣式開始：", text_color=MUTED, font=ctk.CTkFont(size=12)).grid(row=0, column=0)
        for i, name in enumerate(FOOTER_LOOKS):
            ctk.CTkButton(start, text=name, width=70, height=26, corner_radius=8, fg_color=BTN, hover_color=BTN_HOVER,
                          text_color=("gray10", "gray95"), font=ctk.CTkFont(size=12),
                          command=lambda n=name: self.start_from(n)).grid(row=0, column=i + 1, padx=2)
        pvf = ctk.CTkFrame(self, corner_radius=14, fg_color=PV_BG)
        pvf.grid(row=3, column=0, sticky="ew", padx=20, pady=(0, 10))
        pvf.columnconfigure(0, weight=1)
        ctk.CTkLabel(pvf, text="預覽（資訊列效果）", text_color=MUTED, font=ctk.CTkFont(size=11)
                     ).grid(row=0, column=0, sticky="w", padx=14, pady=(8, 0))
        bg = pvf._apply_appearance_mode(pvf.cget("fg_color"))
        self.pv_label = tk.Label(pvf, bd=0, highlightthickness=0, bg=bg)
        self.pv_label.grid(row=1, column=0, padx=12, pady=(4, 12))
        cols = ctk.CTkFrame(self, fg_color="transparent")
        cols.grid(row=4, column=0, sticky="nsew", padx=14)
        self.rowconfigure(4, weight=1)
        menu = dict(height=28, corner_radius=8, fg_color=BTN, button_color=BTN_HOVER, button_hover_color=BTN_HOVER,
                    text_color=("gray10", "gray95"), dropdown_text_color=("gray10", "gray95"),
                    font=ctk.CTkFont(size=12))
        check = dict(checkbox_width=16, checkbox_height=16, fg_color=ACCENT, hover_color=ACCENT_HOVER,
                     font=ctk.CTkFont(size=12))
        for c, name in enumerate(ig_border.STYLE_BLOCKS):
            cols.columnconfigure(c, weight=1, uniform="blk")
            card = ctk.CTkFrame(cols, corner_radius=14, fg_color=CARD)
            card.grid(row=0, column=c, sticky="nsew", padx=6, pady=4)
            head = ctk.CTkFrame(card, fg_color="transparent")
            head.grid(row=0, column=0, sticky="ew", padx=12, pady=(10, 2))
            head.columnconfigure(0, weight=1)
            ctk.CTkLabel(head, text=BLOCK_TITLES[name], font=ctk.CTkFont(size=13, weight="bold")
                         ).grid(row=0, column=0, sticky="w")
            align = tk.StringVar(value="靠左")
            ctk.CTkOptionMenu(head, values=list(ALIGN_LABELS), variable=align, width=78, **menu).grid(row=0, column=1)
            align.trace_add("write", lambda *a: self.changed())
            opts = ctk.CTkFrame(card, fg_color="transparent")
            opts.grid(row=1, column=0, sticky="ew", padx=12, pady=(0, 6))
            logo_v, rule_v = tk.BooleanVar(value=False), tk.BooleanVar(value=False)
            ctk.CTkCheckBox(opts, text="logo 在文字左側", variable=logo_v, width=120, command=self.changed, **check
                            ).grid(row=0, column=0, sticky="w")
            ctk.CTkCheckBox(opts, text="logo 後加分隔線", variable=rule_v, width=110, command=self.changed, **check
                            ).grid(row=0, column=1, sticky="w", padx=(6, 0))
            if name == "right":
                ctk.CTkCheckBox(opts, text="整個區塊前加一條分隔線", variable=self.divider_var, width=200,
                                command=self.changed, **check).grid(row=1, column=0, columnspan=2, sticky="w",
                                                                    pady=(6, 0))
            lines = []
            for i in range(ig_border.MAX_STYLE_LINES):
                box = ctk.CTkFrame(card, corner_radius=10, fg_color=BTN)
                box.grid(row=2 + i, column=0, sticky="ew", padx=10, pady=(0, 8))
                box.columnconfigure(0, weight=1)
                ctk.CTkLabel(box, text="第 %d 行" % (i + 1), text_color=MUTED, font=ctk.CTkFont(size=11)
                             ).grid(row=0, column=0, sticky="w", padx=10, pady=(6, 0))
                box.grid_remove() if i > 0 else None
                items = []
                irow = ctk.CTkFrame(box, fg_color="transparent")
                irow.grid(row=1, column=0, sticky="ew", padx=6, pady=(2, 4))
                for k in range(self.ITEMS):
                    v = tk.StringVar(value=TOKEN_LABELS[""])
                    ctk.CTkOptionMenu(irow, values=list(TOKEN_LABELS.values()), variable=v, width=92, **menu
                                      ).grid(row=0, column=k, padx=2)
                    v.trace_add("write", lambda *a: self.changed())
                    items.append(v)
                orow = ctk.CTkFrame(box, fg_color="transparent")
                orow.grid(row=2, column=0, sticky="ew", padx=6, pady=(0, 8))
                bold = tk.BooleanVar(value=False)
                ctk.CTkCheckBox(orow, text="粗體", variable=bold, width=58, command=self.changed, **check
                                ).grid(row=0, column=0, padx=(4, 4))
                size = tk.StringVar(value="中")
                cap = dict(text_color=MUTED, font=ctk.CTkFont(size=11))
                ctk.CTkLabel(orow, text="字級", **cap).grid(row=0, column=1, padx=(4, 0))
                ctk.CTkOptionMenu(orow, values=list(LINE_SIZE_LABELS), variable=size, width=62, **menu
                                  ).grid(row=0, column=2, padx=2)
                tone = tk.StringVar(value="主要（深）")
                sep = tk.BooleanVar(value=False)
                line = {"items": items, "bold": bold, "size": size, "tone": tone, "sep": sep, "hex": None,
                        "box": box, "orow": orow}
                ctk.CTkLabel(orow, text="顏色", **cap).grid(row=0, column=3, padx=(6, 0))
                ctk.CTkOptionMenu(orow, values=list(TONE_LABELS), variable=tone, width=92,
                                  command=lambda v, ln=line: self.on_tone(ln, v), **menu).grid(row=0, column=4, padx=2)
                ctk.CTkCheckBox(orow, text="項目之間加線", variable=sep, width=100, command=self.changed, **check
                                ).grid(row=1, column=0, columnspan=5, sticky="w", padx=(4, 0), pady=(6, 0))
                size.trace_add("write", lambda *a: self.changed())
                lines.append(line)
            self.blocks[name] = {"align": align, "logo": logo_v, "rule": rule_v, "lines": lines}
        self.refresh_lines()
        bar = ctk.CTkFrame(self, fg_color="transparent")
        bar.grid(row=5, column=0, sticky="ew", padx=20, pady=(8, 16))
        bar.columnconfigure(1, weight=1)
        small = dict(height=34, corner_radius=10, fg_color=BTN, hover_color=BTN_HOVER, text_color=("gray10", "gray95"))
        ctk.CTkButton(bar, text="重設為預設", width=96, command=self.reset, **small).grid(row=0, column=2, padx=4)
        ctk.CTkButton(bar, text="載入樣式檔…", width=110, command=self.load_file, **small).grid(row=0, column=3, padx=4)
        ctk.CTkButton(bar, text="儲存樣式檔…", width=110, command=self.save_file, **small).grid(row=0, column=4, padx=4)
        ctk.CTkButton(bar, text="完成", width=80, height=34, corner_radius=10, fg_color=ACCENT,
                      hover_color=ACCENT_HOVER, command=self.close).grid(row=0, column=5, padx=(8, 0))

    # ---- model <-> widgets ----
    def build_style(self):
        out = {"divider": bool(self.divider_var.get())}
        for name, blk in self.blocks.items():
            lines = []
            for ln in blk["lines"]:
                items = [TOKEN_BY_LABEL.get(v.get()) or (v.get() if v.get() in ig_border.STYLE_TOKENS else "")
                         for v in ln["items"]]
                items = [t for t in items if t]
                if not items:
                    continue
                tone = TONE_LABELS.get(ln["tone"].get(), "strong")
                lines.append({"items": items, "bold": bool(ln["bold"].get()),
                              "size": LINE_SIZE_LABELS.get(ln["size"].get(), 100),
                              "color": (ln["hex"] or "strong") if tone == "custom" else tone,
                              "sep": "divider" if ln["sep"].get() else "gap"})
            out[name] = {"align": ALIGN_LABELS.get(blk["align"].get(), "left"), "lines": lines,
                         "logo": "left" if blk["logo"].get() else "none", "logo_rule": bool(blk["rule"].get())}
        return out

    def current_style(self):
        return ig_border.sanitize_style(self.build_style())

    def load(self, style):
        style = ig_border.sanitize_style(style)
        self.loading = True
        try:
            self.divider_var.set(bool(style.get("divider")))
            for name, blk in self.blocks.items():
                src = style[name]
                blk["align"].set(next((k for k, v in ALIGN_LABELS.items() if v == src["align"]), "靠左"))
                blk["logo"].set(src.get("logo") == "left")
                blk["rule"].set(bool(src.get("logo_rule")))
                for i, ln in enumerate(blk["lines"]):
                    data = src["lines"][i] if i < len(src["lines"]) else None
                    for k, v in enumerate(ln["items"]):
                        tok = data["items"][k] if data and k < len(data["items"]) else ""
                        v.set(TOKEN_LABELS.get(tok, TOKEN_LABELS[""]))
                    ln["bold"].set(bool(data and data["bold"]))
                    ln["sep"].set(bool(data and data.get("sep") == "divider"))
                    want = data["size"] if data else 100
                    ln["size"].set(min(LINE_SIZE_LABELS, key=lambda lab: abs(LINE_SIZE_LABELS[lab] - want)))
                    col = data["color"] if data else "strong"
                    if col in ig_border.STYLE_COLORS:
                        ln["tone"].set(next(k for k, v in TONE_LABELS.items() if v == col))
                        ln["hex"] = None
                    else:
                        ln["tone"].set("自訂色…")
                        ln["hex"] = col
        finally:
            self.loading = False
        self.refresh_lines()
        self.set_origin()

    def refresh_lines(self):
        """A line's settings only matter once it has items; line 2 only shows up after line 1 is used."""
        for blk in self.blocks.values():
            prev_used = True
            for i, ln in enumerate(blk["lines"]):
                used = any(v.get() != TOKEN_LABELS[""] for v in ln["items"])
                if i == 0 or prev_used or used:
                    ln["box"].grid()
                else:
                    ln["box"].grid_remove()
                if used:
                    ln["orow"].grid()
                else:
                    ln["orow"].grid_remove()
                prev_used = used

    def start_from(self, name):
        look = FOOTER_LOOKS.get(name)
        if look is None:
            return
        o = {**FOOTER_BASE, **look}
        style = ig_border.layout_to_style(o["layout"], {k: o[k] for k in ("fields", "divider", "main", "mirror",
                                                                          "logo_pos")})
        self.app.editor_busy = True
        try:
            self.app.apply_settings({k: o[k] for k in ("exposure_items", "exposure_order", "bold")})
        finally:
            self.app.editor_busy = False
        self.load(style)
        self.push()

    def set_origin(self):
        layout = LAYOUT_LABELS.get(self.app.layout_var.get(), "classic3")
        if layout == "custom":
            text = "目前顯示：自訂樣式（你自己設計的樣式）"
        else:
            approx = "　※這個版面轉成可編輯參數時，外觀會略有不同" if layout != "classic3" else ""
            text = "目前顯示：「%s」的參數。你一修改，主視窗就會切換成「自訂樣式」。%s" % (LAYOUT_NAME.get(layout, layout), approx)
        self.origin_lbl.configure(text=text)

    def changed(self, *_):
        if self.loading:
            return
        self.refresh_lines()
        if self.job:
            self.after_cancel(self.job)
        self.job = self.after(40, self.push)

    def push(self):
        self.job = None
        app = self.app
        app.editor_busy = True                      # the main window must not re-load the editor for our own change
        try:
            app.style_slots = self.current_style()
            app.layout_var.set("自訂樣式")
            app.update_footer_controls()
            app.footer_on.set(True)
            app.schedule_preview(interactive=True)
        finally:
            app.editor_busy = False
        self.set_origin()
        self.render_preview()

    def on_tone(self, line, label):
        if TONE_LABELS.get(label) == "custom":
            picked = colorchooser.askcolor(color=line["hex"] or "#444444", title="選擇文字顏色", parent=self)
            if picked and picked[1] and re.fullmatch(r"#[0-9a-fA-F]{6}", picked[1]):
                line["hex"] = picked[1]
            elif not line["hex"]:
                line["tone"].set("主要（深）")
        self.changed()

    # ---- buttons ----
    def reset(self):
        self.app.style_slots = ig_border.default_style()
        self.app.layout_var.set("自訂樣式")
        self.app.update_footer_controls()
        self.load(self.app.style_slots)
        self.app.schedule_preview()
        self.render_preview()

    def save_file(self):
        try:
            STYLES_DIR.mkdir(exist_ok=True)
        except OSError:
            pass
        path = filedialog.asksaveasfilename(parent=self, title="儲存樣式檔", initialdir=str(STYLES_DIR),
                                            initialfile="我的樣式" + STYLE_EXT, filetypes=[("樣式檔", "*" + STYLE_EXT)])
        if not path:
            return
        p = Path(path)
        base = p.name[:-len(STYLE_EXT)] if p.name.endswith(STYLE_EXT) else p.stem
        p = p.with_name((self.app.clean_text(base, 30) or "我的樣式") + STYLE_EXT)
        settings = {k: v for k, v in self.app.collect_settings().items() if k != "style_slots"}
        try:                                         # what is shown now is what gets saved (even for a built-in layout)
            ig_border.save_style_file(p, self.current_style(), settings, p.name[:-len(STYLE_EXT)])
        except OSError:
            messagebox.showerror("無法儲存", "寫入樣式檔失敗，請確認資料夾可以寫入。", parent=self)
            return
        self.app.set_status("已儲存樣式檔：%s" % p.name, GREEN)

    def load_file(self):
        path = filedialog.askopenfilename(parent=self, title="載入樣式檔",
                                          initialdir=str(STYLES_DIR if STYLES_DIR.is_dir() else Path.home()),
                                          filetypes=[("樣式檔", "*.json")])
        if not path:
            return
        try:
            style, settings, name = ig_border.load_style_file(path)
        except (OSError, ValueError, UnicodeDecodeError):
            messagebox.showerror("無法載入", "這不是有效的樣式檔，或檔案已損壞。", parent=self)
            return
        self.app.editor_busy = True
        try:
            self.app.apply_settings(settings)
            self.app.style_slots = style
            self.app.layout_var.set("自訂樣式")
            self.app.update_footer_controls()
            self.app.footer_on.set(True)
            self.load(style)
            self.app.schedule_preview()
        finally:
            self.app.editor_busy = False
        self.app.set_status("已載入樣式檔：%s" % (name or Path(path).name), GREEN)
        self.render_preview()

    def close(self):
        for j in (self.job, self.tick_job):
            if j:
                self.after_cancel(j)
        self.app.style_editor = None
        self.destroy()


def resolve_color(color):
    """A CTk colour (single value or (light, dark) pair) as the plain colour for the current appearance."""
    if isinstance(color, str):
        return color
    return color[1] if ctk.get_appearance_mode() == "Dark" else color[0]


def round_rect_points(x1, y1, x2, y2, r):
    return [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
            x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]


class PhotoTile(tk.Canvas):
    """One thumbnail of the strip: the picture, a tick box and the file name drawn on a single canvas.
    (The same tile built from CTkFrame / CTkLabel / CTkCheckBox is ~12 native windows; with a few dozen of them
    every layout pass took seconds on macOS - 75 tiles ~7 s, 150 tiles ~48 s. This is one window.)"""

    PAD = 6
    W = THUMB[0] + 2 * PAD
    H = PAD + THUMB[1] + 6 + 20 + PAD
    BOX = 16

    def __init__(self, master, name, var, photo, on_select, on_menu, on_check):
        super().__init__(master, width=self.W, height=self.H, highlightthickness=0, bd=0,
                         bg=resolve_color(CARD))
        self.name, self.var, self.photo = name, var, photo
        self.selected = False
        self.on_select, self.on_check = on_select, on_check
        self.box_xy = (self.PAD + 2, self.H - self.PAD - 18)
        self.font = ctk.CTkFont(size=11)
        self.pill_font = ctk.CTkFont(size=11, weight="bold")
        self.state = ""
        self.draw()
        self.bind("<Button-1>", self.click)
        for seq in ("<Button-2>", "<Button-3>", "<Control-Button-1>"):
            self.bind(seq, on_menu)
        self.trace_id = var.trace_add("write", lambda *a: self.draw_check())
        try:
            AppearanceModeTracker.add(self.on_mode, self)
        except Exception:
            pass

    def destroy(self):
        try:
            self.var.trace_remove("write", self.trace_id)
        except (tk.TclError, ValueError, AttributeError):
            pass
        try:
            AppearanceModeTracker.remove(self.on_mode)
        except Exception:
            pass
        super().destroy()

    def on_mode(self, *_):
        try:
            self.configure(bg=resolve_color(CARD))
            self.draw()
        except tk.TclError:
            pass

    def draw(self):
        self.delete("all")
        self.create_polygon(round_rect_points(1, 1, self.W - 1, self.H - 1, 10), smooth=True, tags="bg",
                            fill=resolve_color(BTN), outline=resolve_color(ACCENT if self.selected else BTN), width=2)
        self.create_image(self.W // 2, self.PAD + THUMB[1] // 2, image=self.photo, tags="photo")
        x, y = self.box_xy
        self.create_text(x + self.BOX + 6, y + self.BOX // 2, text=self.name, anchor="w", font=self.font,
                         fill=resolve_color(MUTED), tags="name")
        self.draw_check()
        if self.state:
            self.set_state(self.state)

    def draw_check(self):
        self.delete("check")
        x, y = self.box_xy
        on = bool(self.var.get())
        self.create_polygon(round_rect_points(x, y, x + self.BOX, y + self.BOX, 4), smooth=True, tags="check",
                            fill=resolve_color(ACCENT if on else BTN),
                            outline=resolve_color(ACCENT if on else MUTED), width=1)
        if on:
            self.create_line(x + 4, y + 8.5, x + 7, y + 11.5, x + 12, y + 5, fill="white", width=2, tags="check",
                             capstyle="round", joinstyle="round")

    def set_selected(self, value):
        if value != self.selected:
            self.selected = value
            self.itemconfigure("bg", outline=resolve_color(ACCENT if value else BTN))

    def set_photo(self, photo):
        self.photo = photo
        self.itemconfigure("photo", image=photo)

    def set_state(self, state):
        """Status pill drawn with canvas items, not baked into the bitmap: canvas text is rendered at the screen's
        native resolution (a bitmap is scaled up on Retina displays, which made the label blurry)."""
        self.state = state
        self.delete("pill")
        text = STATE_TEXT.get(state, "")
        rgb = PILL_COLORS.get(state)
        if not text or rgb is None:
            return
        col = "#%02x%02x%02x" % rgb
        f = self.pill_font
        tw = f.measure(text)
        H, PADX, ICON, GAP = 20, 8, 10, 5
        W = PADX * 2 + ICON + GAP + tw
        x0, y1 = self.PAD + 7, self.PAD + THUMB[1] - 7
        y0 = y1 - H
        self.create_polygon(round_rect_points(x0, y0, x0 + W, y1, H // 2), smooth=True, fill="#14161a",
                            outline="", tags="pill")
        ix, iy, sz = x0 + PADX, y0 + (H - ICON) / 2, ICON
        kw = dict(fill=col, width=2, tags="pill", capstyle="round", joinstyle="round")
        if state == "完成":
            self.create_line(ix + 1, iy + 5.5, ix + 4, iy + 8.5, ix + 9.2, iy + 1.8, **kw)
        elif state == "失敗":
            self.create_line(ix + 1.5, iy + 1.5, ix + 8.5, iy + 8.5, **kw)
            self.create_line(ix + 8.5, iy + 1.5, ix + 1.5, iy + 8.5, **kw)
        elif state == "略過":
            self.create_line(ix + 1.2, iy + 5, ix + 8.8, iy + 5, **kw)
        elif state == "處理中":
            for k in range(3):
                cx = ix + 1.6 + 3.4 * k
                self.create_oval(cx - 1.2, iy + 3.8, cx + 1.2, iy + 6.2, fill=col, outline="", tags="pill")
        self.create_text(x0 + PADX + ICON + GAP, (y0 + y1) / 2, text=text, anchor="w", font=f, fill=col, tags="pill")

    def click(self, event):
        x, y = self.box_xy
        if x - 4 <= event.x <= x + self.BOX + 4 and y - 4 <= event.y <= y + self.BOX + 4:
            self.var.set(not self.var.get())
            self.on_check()
        else:
            self.on_select()


class SourceRow(tk.Canvas):
    """One row of the source manager drawn on a single canvas (tick box, name, path, count). Built from
    CTk widgets a row is ~25 native windows and 30 rows took 9 s to open; this is one window per row."""

    H = 64

    def __init__(self, master, key, title, path_text, var, bold=False):
        super().__init__(master, height=self.H, highlightthickness=0, bd=0, bg=resolve_color(CARD))
        self.key, self.title, self.path_text, self.var = key, title, path_text, var
        self.bold = bold
        self.count_text, self.count_missing = "", False
        self.width = 0
        self.entry = None
        self.f_name = ctk.CTkFont(size=13, weight="bold" if bold else "normal")
        self.f_small = ctk.CTkFont(size=11)
        self.f_btn = ctk.CTkFont(size=12)
        self.bind("<Configure>", self.on_configure)
        self.bind("<Button-1>", self.click)
        self.trace_id = var.trace_add("write", lambda *a: self.draw())
        try:
            AppearanceModeTracker.add(self.on_mode, self)
        except Exception:
            pass

    def destroy(self):
        try:
            self.var.trace_remove("write", self.trace_id)
        except (tk.TclError, ValueError, AttributeError):
            pass
        try:
            AppearanceModeTracker.remove(self.on_mode)
        except Exception:
            pass
        super().destroy()

    def on_mode(self, *_):
        try:
            self.configure(bg=resolve_color(CARD))
            self.draw()
        except tk.TclError:
            pass

    def on_configure(self, event):
        if event.width != self.width:
            self.width = event.width
            self.draw()

    def set_count(self, text, missing):
        if (text, missing) != (self.count_text, self.count_missing):
            self.count_text, self.count_missing = text, missing
            self.draw()                      # the count's width decides how much room the name and path get

    def draw(self):
        if self.width < 50:
            return
        w, h = self.width, self.H
        self.delete("all")
        self.create_polygon(round_rect_points(1, 1, w - 1, h - 1, 10), smooth=True, fill=resolve_color(BTN), outline="")
        on = bool(self.var.get())
        bx, by = 14, h // 2 - 9
        self.create_polygon(round_rect_points(bx, by, bx + 18, by + 18, 5), smooth=True,
                            fill=resolve_color(ACCENT if on else BTN), outline=resolve_color(ACCENT if on else MUTED))
        if on:
            self.create_line(bx + 4, by + 9.5, bx + 8, by + 13.5, bx + 14, by + 5.5, fill="white", width=2,
                             capstyle="round", joinstyle="round")
        x = w - 10
        cw = self.f_btn.measure(self.count_text) if self.count_text else 0
        self.create_text(x - 8, h // 2, text=self.count_text, anchor="e", font=self.f_btn, tags="count",
                         fill=resolve_color(RED if self.count_missing else MUTED))
        room = max(60, x - 8 - cw - 12 - 44)          # name and path never run into the count
        self.create_text(44, h // 2 - 11, text=self.fit(self.title, self.f_name, room), anchor="w", font=self.f_name,
                         fill=resolve_color(("gray10", "gray95")), tags="title")
        self.create_text(44, h // 2 + 12, text=self.fit(self.path_text, self.f_small, room), anchor="w",
                         font=self.f_small, fill=resolve_color(MUTED), tags="path")

    @staticmethod
    def fit(text, font, room):
        """`text` shortened with an ellipsis so that it is at most `room` pixels wide."""
        if font.measure(text) <= room:
            return text
        while text and font.measure(text + "…") > room:
            text = text[:-1]
        return text + "…"

    def click(self, event):
        self.var.set(not self.var.get())            # anywhere on the row ticks / unticks it


class SourceManager(ctk.CTkToplevel):
    """Manage the list of sources: rename, reorder, re-point a folder that moved, remove several at once, drop the
    ones that are gone. A source is only a remembered place - nothing is copied, moved or deleted here."""

    def __init__(self, app):
        super().__init__(app)
        self.withdraw()                      # stay hidden while the rows are built, then show the finished window
        self.app = app
        self.title("來源管理")
        self.configure(fg_color=WINDOW_BG)
        self.minsize(780, 520)
        self.transient(app)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.bind("<Escape>", lambda e: self.close())
        self.picked = {}                     # key -> BooleanVar (ticked for removal)
        self.rows = {}
        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)
        ctk.CTkLabel(self, text="來源管理", font=ctk.CTkFont(size=20, weight="bold")
                     ).grid(row=0, column=0, sticky="w", padx=20, pady=(16, 0))
        ctk.CTkLabel(self, text="來源只是「記住照片放在哪裡」，不會複製、移動或刪除任何檔案。"
                                "外接硬碟沒接上時，來源會留在清單裡並標示「找不到」，接上後就恢復。用下方按鈕新增或移除來源。",
                     text_color=MUTED, anchor="w", justify="left", wraplength=740
                     ).grid(row=1, column=0, sticky="w", padx=20, pady=(2, 8))
        self.body = SmoothScrollFrame(self, corner_radius=14, fg_color=CARD, **SCROLLBAR)
        self.body.grid(row=2, column=0, sticky="nsew", padx=20)
        self.body.columnconfigure(0, weight=1)
        bar = ctk.CTkFrame(self, fg_color="transparent")
        bar.grid(row=3, column=0, sticky="ew", padx=20, pady=(10, 16))
        bar.columnconfigure(2, weight=1)
        btn = dict(height=34, corner_radius=10, fg_color=BTN, hover_color=BTN_HOVER, text_color=("gray10", "gray95"))
        ctk.CTkButton(bar, text="＋ 加入資料夾…", width=116, command=self.add_folder, **btn).grid(row=0, column=0)
        ctk.CTkButton(bar, text="＋ 匯入照片…", width=104, command=self.import_photos, **btn
                      ).grid(row=0, column=1, padx=(6, 0))
        ctk.CTkButton(bar, text="－ 移除勾選的", width=104, command=self.remove_picked, **btn
                      ).grid(row=0, column=3, padx=(0, 6))
        self.clean_btn = ctk.CTkButton(bar, text="清除失效項目", width=116, command=self.clear_missing, **btn)
        self.clean_btn.grid(row=0, column=4, padx=(0, 6))
        ctk.CTkButton(bar, text="完成", width=80, height=34, corner_radius=10, fg_color=ACCENT,
                      hover_color=ACCENT_HOVER, command=self.close).grid(row=0, column=5)
        self.build_rows()
        self.update_idletasks()
        place_over_app(self, app, 820, 560)
        self.deiconify()
        self.lift()

    def add_folder(self):
        self.app.pick_folder()               # adds the folder, refreshes the main window and this list

    def import_photos(self):
        self.app.import_dialog()

    def close(self):
        self.app.source_manager = None
        self.destroy()

    @staticmethod
    def shown_path(key):
        home = str(Path.home())
        shown = ("~" + key[len(home):]) if key == home or key.startswith(home + os.sep) else key
        return shown if len(shown) <= 40 else "…" + shown[-39:]

    def build_rows(self):
        app = self.app
        for w in self.body.winfo_children():
            w.destroy()
        keys = [x["path"] for x in app.sources] + (["imported"] if app.imported else [])
        self.picked = {k: v for k, v in self.picked.items() if k in keys}
        self.rows = {}
        for i, src in enumerate(app.sources):
            self.add_row(i, src)
        if app.imported:
            self.add_imported_row(len(app.sources))
        if not keys:
            ctk.CTkLabel(self.body, text="還沒有來源。用下方的「加入資料夾」或「匯入照片」新增。", text_color=MUTED
                         ).grid(row=0, column=0, padx=24, pady=40)
        self.update_counts()

    def add_row(self, i, src):
        key = src["path"]
        var = self.picked.setdefault(key, tk.BooleanVar(value=False))
        row = SourceRow(self.body, key, src["name"] or Path(key).name or key, self.shown_path(key), var)
        row.grid(row=i, column=0, sticky="ew", padx=8, pady=4)
        self.rows[key] = row

    def add_imported_row(self, i):
        var = self.picked.setdefault("imported", tk.BooleanVar(value=False))
        row = SourceRow(self.body, "imported", "已匯入的照片", "一張一張匯入的照片，檔案留在原位置", var, bold=True)
        row.grid(row=i, column=0, sticky="ew", padx=8, pady=4)
        self.rows["imported"] = row

    def update_counts(self):
        gone = sum(1 for x in self.app.sources if self.app.source_missing(x["path"]))
        self.clean_btn.configure(text="清除失效項目" + (" (%d)" % gone if gone else ""),
                                 state="normal" if gone else "disabled")
        for key, row in self.rows.items():
            text, missing = self.app.source_count_text(key)
            try:
                row.set_count(text, missing)
            except tk.TclError:
                pass

    def remove_picked(self):
        keys = [k for k, v in self.picked.items() if v.get()]
        if not keys:
            messagebox.showinfo("沒有勾選", "請先勾選要移除的來源。", parent=self)
            return
        if messagebox.askyesno("移除來源", "從清單移除 %d 個來源？\n只是不再記住它們，檔案不會被刪除。" % len(keys), parent=self):
            self.app.remove_sources(keys)

    def clear_missing(self):
        keys = [x["path"] for x in self.app.sources if self.app.source_missing(x["path"])]
        if keys:
            self.app.remove_sources(keys)


class App(_Base):
    def __init__(self):
        super().__init__()
        if HAVE_DND:
            try:
                self.TkdndVersion = TkinterDnD._require(self)
            except Exception:
                globals()["HAVE_DND"] = False
        self.title("Photo_Lab")
        self.configure(fg_color=WINDOW_BG)
        self.set_app_icon()
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        w, h = min(1480, max(1000, sw - 80)), min(1040, max(740, sh - 120))
        self.geometry("%dx%d+%d+%d" % (w, h, max(0, (sw - w) // 2), max(0, (sh - h) // 3)))
        self.minsize(1060, 700)

        self.msg_q = queue.Queue()
        self.thumb_q = queue.Queue()
        self.batch_stop = threading.Event()
        self.batch_fail_reason = None
        self.save_job = None
        self.batch = None

        # preview state
        self.preview_src = None
        self.preview_job = None
        self.preview_img = None
        self.preview_path = None     # file behind the preview (None = placeholder)
        self.fast_canvas = None      # instant low-res render
        self.hq_canvas = None        # real, full-resolution render (background thread)
        self.hq_job = None
        self.hq_running = False
        self.hq_pending = False
        self.view_job = None
        self.view = None
        self.drag = None
        self.zoom = 1.0              # 1.0 = fit to window
        self.cxn = self.cyn = 0.5    # view centre, normalised (0-1) so it survives canvas swaps
        self.preview_small = None    # ~640 px copy used while a slider is being dragged
        self.last_fast = 0.0
        self.settle_job = None
        self.view_settle_job = None
        self.view_ext = (1.0, 1.0)   # visible fraction of the canvas (x, y)
        self.sb_shown = False

        # photo strip state
        self.photos = []             # Paths currently listed
        self.photo_sig = None
        self.capped = False
        self.tiles = {}              # Path -> dict(widgets)
        self.checked = {}            # Path -> BooleanVar
        self.states = {}             # Path -> state text
        self.thumbs = {}             # Path -> (mtime, PhotoImage)
        self.thumb_base = {}         # Path -> (mtime, PIL thumbnail without badge)
        self.badge_shown = {}        # Path -> state last drawn on the thumbnail
        self.selected = None

        cfg = self.load_cfg()
        self.thumb_pending = set()
        self.preview_mtime = None
        self.sources = self.load_sources(cfg)                        # remembered folders (nothing is copied or moved)
        active = cfg.get("active_source")
        self.active_source = active if isinstance(active, str) and (
            active in ("all", "imported") or any(x["path"] == active for x in self.sources)) else "all"
        self.src_info = {}                                           # key -> {"missing", "total", "done"} (background scan)
        self.scan_id = 0
        self.first_scan_seen = False
        self.poll_tick = 0
        self.source_manager = None
        self.out_var = tk.StringVar(value=self.clean_path(cfg.get("output")))
        self.ratio = self.choice(cfg.get("ratio"), [r for _, r in RATIOS], "4:5")
        self.size_var = tk.StringVar(value=self.choice(cfg.get("size"), SIZE_LABELS, DEFAULT_SIZE))
        self.thick_var = tk.DoubleVar(value=self.num(cfg.get("thickness"), 0, 50, 10.0))
        self.footer_on = tk.BooleanVar(value=cfg.get("footer") is True)
        self.layout_var = tk.StringVar(value=self.choice(cfg.get("footer_layout"), LAYOUT_LABELS, "經典三欄"))
        self.style_var = tk.StringVar(value=self.choice(cfg.get("style"), STYLE_LABELS, "白底"))
        self.divider_var = tk.BooleanVar(value=cfg.get("footer_divider") is True)
        self.cdivider_var = tk.BooleanVar(value=cfg.get("footer_center_divider") is not False)   # centred layouts: "|"
        self.overwrite_var = tk.BooleanVar(value=cfg.get("overwrite") is True)
        self.text_scale = tk.DoubleVar(value=self.num(cfg.get("text_scale"), 50, 200, 100))
        self.logo_scale = tk.DoubleVar(value=self.num(cfg.get("logo_scale"), 40, 250, 100))
        self.height_scale = tk.DoubleVar(value=self.num(cfg.get("height_scale"), 60, 250, 100))
        self.bold_var = tk.BooleanVar(value=cfg.get("bold") is not False)
        self.color_var = tk.StringVar(value=self.choice(cfg.get("color_choice"), COLOR_LABELS, "自動"))
        cc = cfg.get("custom_color")
        self.custom_color = cc if isinstance(cc, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", cc) else DEFAULT_CUSTOM_COLOR
        self.datefmt_var = tk.StringVar(value=self.label_of(DATE_LABELS, cfg.get("date_format"), "2026.05.25"))
        self.logopos_var = tk.StringVar(value=self.label_of(LOGO_POS_LABELS, cfg.get("logo_pos"), "機型左側"))
        self.custom_text_var = tk.StringVar(value=self.clean_text(cfg.get("custom_text", "")))
        self.main_var = tk.BooleanVar(value=cfg.get("lens_main") is True)
        self.mirror_var = tk.BooleanVar(value=cfg.get("mirror") is True)
        self.adv_open = cfg.get("advanced_open") is True
        items = cfg.get("exposure_items")
        items = [k for k in items if isinstance(k, str)] if isinstance(items, list) else list(ig_border.DEFAULT_EXPOSURE_ITEMS)
        if sorted(items) == sorted(k for _, k in EXPO_LABELS):   # the old default (all four) was never a deliberate choice
            items = list(ig_border.DEFAULT_EXPOSURE_ITEMS)
        self.exp_vars = {k: tk.BooleanVar(value=k in items) for _, k in EXPO_LABELS}
        self.exporder_var = tk.StringVar(value=self.label_of(EXPO_ORDER_LABELS, cfg.get("exposure_order"),
                                                              next(iter(EXPO_ORDER_LABELS))))
        self.font_labels = {label: key for key, label in ig_border.available_fonts()}
        fk = cfg.get("font")
        self.font_var = tk.StringVar(value=self.label_of(self.font_labels, fk if isinstance(fk, str) else None,
                                                         DEFAULT_FONT_LABEL))
        self.imported = self.load_imported(cfg.get("imported"))     # photos added one by one (like Lightroom's "Add")
        self.name_map = {}                                            # Path -> output file name (unique per batch)
        self.style_slots = ig_border.sanitize_style(cfg.get("style_slots"))
        self.style_editor = None
        self.editor_busy = False
        self.recent_out = self.clean_recents(cfg.get("recent_outputs"))
        presets = cfg.get("presets")
        self.presets = {}
        if isinstance(presets, dict):
            for k, v in list(presets.items())[:MAX_PRESETS]:
                name = self.clean_text(k, 30)
                if name and name not in BUILTIN_PRESETS and isinstance(v, dict):
                    self.presets[name] = v
        self.preset_var = tk.StringVar(value=PRESET_PLACEHOLDER)
        self.compare = False
        saved = cfg.get("footer_fields")
        saved = [k for k in saved if isinstance(k, str)] if isinstance(saved, list) else list(ig_border.FOOTER_FIELDS)
        self.field_vars = {k: tk.BooleanVar(value=k in saved) for _, k in FIELD_LABELS}
        self.preview_info = None   # None = placeholder photo (show sample text), {} = photo without EXIF

        self.icons = {}
        for _, val in RATIOS:
            self.icons[val] = (
                ctk.CTkImage(light_image=ratio_icon(val, (55, 60, 70, 255)),
                             dark_image=ratio_icon(val, (225, 228, 235, 255)), size=(28, 28)),
                ctk.CTkImage(ratio_icon(val, (255, 255, 255, 255)), size=(28, 28)))
        self.placeholder_thumb = ImageTk.PhotoImage(Image.new("RGB", THUMB, THUMB_BG))

        self.columnconfigure(1, weight=1)
        self.rowconfigure(0, weight=1)
        self.build_controls()
        self.build_right()
        self.free_slider_wheels(self.left_panel)
        self.restore_geometry(cfg)
        self.bind_keys()
        self.custom_text_var.trace_add("write", lambda *a: self.schedule_preview(interactive=True))

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        threading.Thread(target=self.thumb_worker, daemon=True).start()
        self.after(200, self.drain_msgs)
        self.on_sources_changed(save=False)
        if self.preview_src is None:   # nothing to preview yet: neutral placeholder shows the layout
            self.preview_src = Image.new("RGB", (900, 600), (120, 130, 145))
        self.schedule_preview()
        self.after(2000, self.poll)
        self.after(400, self.check_saved_paths)

    def effective_style(self):
        """The style that is on screen right now, in the editor's model (a built-in layout is converted)."""
        layout = LAYOUT_LABELS.get(self.layout_var.get(), "classic3")
        if layout == "custom":
            return ig_border.sanitize_style(self.style_slots)
        fo = self.footer_opts()
        return ig_border.layout_to_style(layout, {
            "fields": fo["footer_fields"], "mirror": fo["footer_mirror"], "main": fo["footer_main"],
            "logo_pos": fo["footer_logo_pos"], "divider": fo["footer_divider"],
            "center_divider": fo["footer_center_divider"]})

    def sync_editor(self):
        """The main window changed (layout, preset, tick boxes ...): show that style's parameters in the editor."""
        ed = self.style_editor
        if ed is None or getattr(self, "editor_busy", False):
            return
        try:
            if not ed.winfo_exists():
                return
            style = self.effective_style()
            if style != ed.current_style():
                ed.load(style)
            else:
                ed.set_origin()
        except tk.TclError:
            pass

    def open_style_editor(self):
        if self.style_editor is not None and self.style_editor.winfo_exists():
            self.style_editor.lift()
            self.style_editor.focus_force()
            return
        self.style_editor = StyleEditor(self)

    def free_slider_wheels(self, root):
        """Sliders in the side panel must not swallow the wheel / trackpad: scrolling over them scrolls the page
        (and never changes their value by accident)."""
        for w in root.winfo_children():
            if isinstance(w, ctk.CTkSlider):
                for seq in ("<MouseWheel>", "<Button-4>", "<Button-5>"):
                    try:
                        w._canvas.unbind(seq)
                    except (tk.TclError, AttributeError):
                        pass
            self.free_slider_wheels(w)

    # ---------------- small helpers ----------------
    @staticmethod
    def num(value, lo, hi, default):
        try:
            v = float(value)
        except (TypeError, ValueError):
            return default
        return min(hi, max(lo, v)) if v == v else default

    @staticmethod
    def label_of(mapping, value, default):
        """Reverse lookup: internal value -> display label."""
        return next((k for k, v in mapping.items() if v == value), default)

    @staticmethod
    def clean_text(value, maxlen=60):
        return re.sub(r"[\x00-\x1f\x7f]", "", str(value or "")).strip()[:maxlen]

    @staticmethod
    def choice(value, allowed, default):
        """`value` if it is a string present in `allowed`, else `default` (safe against any JSON type)."""
        return value if isinstance(value, str) and value in allowed else default

    @staticmethod
    def load_imported(value):
        """Imported photos remembered from the last run; files that no longer exist are dropped."""
        out = []
        for x in (value if isinstance(value, list) else [])[:MAX_PHOTOS]:
            if isinstance(x, str):
                try:
                    p = Path(x).expanduser()
                    if p.is_file() and p.suffix.lower() in ig_border.EXTS:
                        p = p.resolve()
                        if p not in out:
                            out.append(p)
                except (OSError, RuntimeError):
                    pass
        return out

    @staticmethod
    def clean_recents(value):
        out = []
        for x in (value if isinstance(value, list) else []):
            t = App.clean_path(x)
            if t and t not in out:
                out.append(t)
        return out[:MAX_RECENT]

    @staticmethod
    def clean_path(value):
        return re.sub(r"[\x00-\x1f\x7f]", "", value).strip()[:1000] if isinstance(value, str) else ""

    # ---------------- layout ----------------
    def card(self, parent, title, row):
        outer = ctk.CTkFrame(parent, corner_radius=14, fg_color=CARD)
        outer.grid(row=row, column=0, sticky="ew", padx=16, pady=(0, 10))
        outer.columnconfigure(0, weight=1)
        ctk.CTkLabel(outer, text=title, text_color=MUTED, anchor="w",
                     font=ctk.CTkFont(size=12, weight="bold")).grid(row=0, column=0, sticky="w", padx=16, pady=(10, 4))
        return outer

    def build_controls(self):
        outer = ctk.CTkFrame(self, width=396, corner_radius=0, fg_color="transparent")
        outer.grid(row=0, column=0, sticky="nsew")
        outer.grid_propagate(False)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(0, weight=1)
        left = SmoothScrollFrame(outer, corner_radius=0, fg_color="transparent", **SCROLLBAR)
        self.left_panel = left
        left.grid(row=0, column=0, sticky="nsew")
        left.columnconfigure(0, weight=1)
        bottom = ctk.CTkFrame(outer, corner_radius=0, fg_color="transparent")
        bottom.grid(row=1, column=0, sticky="ew")
        bottom.columnconfigure(0, weight=1)

        head = ctk.CTkFrame(left, fg_color="transparent")
        head.grid(row=0, column=0, sticky="ew", padx=20, pady=(14, 10))
        head.columnconfigure(0, weight=1)
        ctk.CTkLabel(head, text="Photo_Lab", font=ctk.CTkFont(size=24, weight="bold")
                     ).grid(row=0, column=0, sticky="w")
        self.theme_var = tk.StringVar(value=PALETTES[THEME]["label"])
        ctk.CTkSegmentedButton(head, values=[v["label"] for v in PALETTES.values()], variable=self.theme_var,
                               width=96, height=26, corner_radius=8, selected_color=ACCENT,
                               selected_hover_color=ACCENT_HOVER, unselected_color=BTN, unselected_hover_color=BTN_HOVER,
                               text_color=("gray10", "gray95"), font=ctk.CTkFont(size=11), command=self.on_theme
                               ).grid(row=0, column=1, sticky="e")

        # presets
        c0 = self.card(left, "預設組合", 1)
        pr = ctk.CTkFrame(c0, fg_color="transparent")
        pr.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 14))
        pr.columnconfigure(0, weight=1)
        self.preset_menu = ctk.CTkOptionMenu(pr, values=self.preset_names(), variable=self.preset_var, height=32,
                                             corner_radius=10, fg_color=BTN, button_color=BTN_HOVER,
                                             button_hover_color=BTN_HOVER, text_color=("gray10", "gray95"),
                                             dropdown_text_color=("gray10", "gray95"), command=self.apply_preset)
        self.preset_menu.grid(row=0, column=0, sticky="ew")
        small = dict(height=32, corner_radius=10, fg_color=BTN, hover_color=BTN_HOVER, text_color=("gray10", "gray95"))
        ctk.CTkButton(pr, text="儲存", width=52, command=self.save_preset, **small).grid(row=0, column=1, padx=(6, 0))
        ctk.CTkButton(pr, text="刪除", width=52, command=self.delete_preset, **small).grid(row=0, column=2, padx=(6, 0))

        # folders
        c1 = self.card(left, "來源與輸出", 2)
        sf = ctk.CTkFrame(c1, fg_color="transparent")             # the source being shown: choose another or add one
        sf.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 10))
        sf.columnconfigure(0, weight=1)
        self.src_label = ctk.CTkLabel(sf, text="", anchor="w", height=34, corner_radius=10, fg_color=BTN)
        self.src_label.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        self.src_choose = ctk.CTkButton(sf, text="選擇 ▾", width=78, height=34, corner_radius=10, fg_color=BTN,
                                        hover_color=BTN_HOVER, text_color=("gray10", "gray95"),
                                        command=lambda: self.show_pick_menu(self.src_choose))
        self.src_choose.grid(row=0, column=1)
        self.src_label.bind("<Configure>", lambda e: self.fit_source_label())
        self.out_entry = self.folder_row(c1, 2, "輸出到", self.out_var, self.pick_out, "recent_out", last=True)
        self.entry_color = self.out_entry.cget("text_color")
        self.rebuild_source_card()

        # border
        c2 = self.card(left, "邊框", 3)
        grid = ctk.CTkFrame(c2, fg_color="transparent")
        grid.grid(row=1, column=0, padx=10)
        self.ratio_btns = {}
        for i, (label, val) in enumerate(RATIOS):
            b = ctk.CTkButton(grid, text=label, image=self.icons[val][0], compound="top", width=54, height=64,
                              corner_radius=12, font=ctk.CTkFont(size=11), border_spacing=4,
                              command=lambda v=val: self.set_ratio(v))
            b.grid(row=i // 5, column=i % 5, padx=2, pady=3)
            self.ratio_btns[val] = b
        self.refresh_ratio_buttons()

        row = ctk.CTkFrame(c2, fg_color="transparent")
        row.grid(row=2, column=0, sticky="ew", padx=16, pady=(12, 0))
        row.columnconfigure(0, weight=1)
        ctk.CTkLabel(row, text="粗細", anchor="w").grid(row=0, column=0, sticky="w")
        self.thick_lbl = ctk.CTkLabel(row, text="", width=40, corner_radius=8, fg_color=BTN)
        self.thick_lbl.grid(row=0, column=1, sticky="e")
        ctk.CTkSlider(c2, from_=0, to=50, number_of_steps=50, variable=self.thick_var, height=18,
                      button_color=ACCENT, button_hover_color=ACCENT_HOVER, progress_color=ACCENT,
                      command=self.on_thick).grid(row=3, column=0, sticky="ew", padx=16, pady=(6, 12))
        ctk.CTkSegmentedButton(c2, values=list(STYLE_LABELS), variable=self.style_var, height=32,
                               corner_radius=10, selected_color=ACCENT, selected_hover_color=ACCENT_HOVER,
                               unselected_color=BTN, unselected_hover_color=BTN_HOVER,
                               text_color=("gray10", "gray95"), command=lambda v: self.schedule_preview()
                               ).grid(row=4, column=0, sticky="ew", padx=16, pady=(0, 16))
        self.on_thick()

        # camera info
        menu = dict(height=30, corner_radius=10, fg_color=BTN, button_color=BTN_HOVER, button_hover_color=BTN_HOVER,
                    text_color=("gray10", "gray95"), dropdown_text_color=("gray10", "gray95"))
        c4 = self.card(left, "相機資訊", 5)
        ctk.CTkSwitch(c4, text="在底部顯示相機參數", variable=self.footer_on, progress_color=ACCENT,
                      command=self.schedule_preview).grid(row=1, column=0, sticky="w", padx=16, pady=(0, 10))
        looks = ctk.CTkFrame(c4, fg_color="transparent")
        looks.grid(row=2, column=0, sticky="ew", padx=16, pady=(0, 10))
        for i in range(3):
            looks.columnconfigure(i, weight=1, uniform="looks")
        for i, name in enumerate(FOOTER_LOOKS):
            ctk.CTkButton(looks, text=name, height=30, corner_radius=10, fg_color=BTN, hover_color=BTN_HOVER,
                          text_color=("gray10", "gray95"), font=ctk.CTkFont(size=12),
                          command=lambda n=name: self.apply_look(n)
                          ).grid(row=i // 3, column=i % 3, sticky="ew", padx=2, pady=2)
        lrow = ctk.CTkFrame(c4, fg_color="transparent")
        lrow.grid(row=3, column=0, sticky="ew", padx=16, pady=(0, 10))
        lrow.columnconfigure(0, weight=1)
        ctk.CTkOptionMenu(lrow, values=list(LAYOUT_LABELS), variable=self.layout_var, height=32, corner_radius=10,
                          fg_color=BTN, button_color=BTN_HOVER, button_hover_color=BTN_HOVER,
                          text_color=("gray10", "gray95"), dropdown_text_color=("gray10", "gray95"),
                          command=self.on_footer_change).grid(row=0, column=0, sticky="ew")
        ctk.CTkButton(lrow, text="編輯樣式…", width=88, height=32, corner_radius=10, fg_color=BTN,
                      hover_color=BTN_HOVER, text_color=("gray10", "gray95"), command=self.open_style_editor
                      ).grid(row=0, column=1, padx=(6, 0))
        fg = ctk.CTkFrame(c4, fg_color="transparent")
        fg.grid(row=4, column=0, sticky="ew", padx=16)
        cb = dict(checkbox_width=18, checkbox_height=18, fg_color=ACCENT, hover_color=ACCENT_HOVER,
                  font=ctk.CTkFont(size=12), command=self.on_footer_change)
        labels = {k: l for l, k in FIELD_LABELS}
        self.field_cbs = {}
        for i, key in enumerate(["camera", "lens", "date", "exposure"]):
            self.field_cbs[key] = ctk.CTkCheckBox(fg, text=labels[key], variable=self.field_vars[key], width=80, **cb)
            self.field_cbs[key].grid(row=i // 3, column=i % 3, sticky="w", pady=3)
        eg = ctk.CTkFrame(c4, fg_color="transparent")          # which exposure values, right under 拍攝參數
        eg.grid(row=5, column=0, sticky="w", padx=(40, 16), pady=(0, 2))
        self.exp_cbs = {}
        for i, (label, key) in enumerate(EXPO_LABELS):
            self.exp_cbs[key] = ctk.CTkCheckBox(eg, text=label, variable=self.exp_vars[key], width=58,
                                                checkbox_width=16, checkbox_height=16, fg_color=ACCENT,
                                                hover_color=ACCENT_HOVER, font=ctk.CTkFont(size=12),
                                                command=self.schedule_preview)
            self.exp_cbs[key].grid(row=0, column=i, padx=(0, 4))
        self.divider_cb = ctk.CTkCheckBox(c4, text="分隔線", variable=self.divider_var, width=100, **cb)   # relabelled per layout
        self.divider_cb.grid(row=6, column=0, sticky="w", padx=16, pady=(4, 0))
        self.footer_hint = ctk.CTkLabel(c4, text="", text_color=MUTED, font=ctk.CTkFont(size=11), wraplength=290,
                                        justify="left", anchor="w")
        self.footer_hint.grid(row=7, column=0, sticky="w", padx=16, pady=(4, 0))
        ctk.CTkLabel(c4, text="logo：放進 logos/ 資料夾，檔名如 sony.png。",
                     text_color=MUTED, font=ctk.CTkFont(size=11), wraplength=290, justify="left", anchor="w"
                     ).grid(row=8, column=0, sticky="w", padx=16, pady=(4, 12))

        # output
        c3 = self.card(left, "輸出長邊 (px)", 4)
        ctk.CTkSegmentedButton(c3, values=list(SIZE_LABELS), variable=self.size_var, height=34,
                               corner_radius=10, selected_color=ACCENT, selected_hover_color=ACCENT_HOVER,
                               unselected_color=BTN, unselected_hover_color=BTN_HOVER,
                               text_color=("gray10", "gray95"), command=lambda v: self.schedule_preview()
                               ).grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 10))
        ctk.CTkCheckBox(c3, text="覆蓋已存在的輸出檔", variable=self.overwrite_var, checkbox_width=20,
                        checkbox_height=20, fg_color=ACCENT, hover_color=ACCENT_HOVER
                        ).grid(row=2, column=0, sticky="w", padx=16, pady=(0, 4))
        ctk.CTkLabel(c3, text="預設關閉：輸出已存在就略過。改了設定想重轉再勾選。",
                     text_color=MUTED, font=ctk.CTkFont(size=11), wraplength=290, justify="left", anchor="w"
                     ).grid(row=3, column=0, sticky="w", padx=16, pady=(0, 14))

        # footer details: the everyday controls stay visible, the rest folds away under 進階
        c6 = self.card(left, "資訊列細節", 6)
        self.slider_row(c6, 1, "文字大小", self.text_scale, 50, 200)
        self.slider_row(c6, 2, "logo 大小", self.logo_scale, 40, 250)

        def line(row, text, pady=(8, 0), parent=c6):
            f = ctk.CTkFrame(parent, fg_color="transparent")
            f.grid(row=row, column=0, sticky="ew", padx=16, pady=pady)
            f.columnconfigure(1, weight=1)
            ctk.CTkLabel(f, text=text, width=64, anchor="w").grid(row=0, column=0)
            return f

        r = line(3, "日期格式", (4, 0))
        self.datefmt_menu = ctk.CTkOptionMenu(r, values=list(DATE_LABELS), variable=self.datefmt_var,
                                              command=lambda v: self.schedule_preview(), **menu)
        self.datefmt_menu.grid(row=0, column=1, sticky="ew")
        self.adv_btn = ctk.CTkButton(c6, text="", height=28, corner_radius=10, fg_color="transparent",
                                     hover_color=BTN, text_color=MUTED, anchor="w", command=self.toggle_advanced)
        self.adv_btn.grid(row=4, column=0, sticky="ew", padx=10, pady=(6, 0))
        adv = self.adv_frame = ctk.CTkFrame(c6, fg_color="transparent")
        adv.columnconfigure(0, weight=1)
        self.slider_row(adv, 0, "資訊列高度", self.height_scale, 60, 250)
        fr = line(1, "字體", (4, 0), adv)
        self.font_menu = ctk.CTkOptionMenu(fr, values=list(self.font_labels), variable=self.font_var,
                                           command=lambda v: self.schedule_preview(), **menu)
        self.font_menu.grid(row=0, column=1, sticky="ew")
        ctk.CTkButton(fr, text="↻", width=30, height=30, corner_radius=10, fg_color=BTN, hover_color=BTN_HOVER,
                      text_color=("gray10", "gray95"), command=self.refresh_fonts).grid(row=0, column=2, padx=(6, 0))
        cr = line(2, "文字顏色", parent=adv)
        ctk.CTkOptionMenu(cr, values=COLOR_LABELS, variable=self.color_var, command=self.on_color, width=96, **menu
                          ).grid(row=0, column=1, sticky="w")
        ctk.CTkSwitch(cr, text="粗體", variable=self.bold_var, progress_color=ACCENT, width=60,
                      command=self.schedule_preview).grid(row=0, column=2, sticky="e")
        r = line(3, "logo 位置", parent=adv)
        self.logopos_menu = ctk.CTkOptionMenu(r, values=list(LOGO_POS_LABELS), variable=self.logopos_var,
                                              command=lambda v: self.schedule_preview(), **menu)
        self.logopos_menu.grid(row=0, column=1, sticky="ew")
        orow = line(4, "排列順序", parent=adv)
        self.exporder_menu = ctk.CTkOptionMenu(orow, values=list(EXPO_ORDER_LABELS), variable=self.exporder_var,
                                               command=lambda v: self.schedule_preview(), **menu)
        self.exporder_menu.grid(row=0, column=1, sticky="ew")
        sw = ctk.CTkFrame(adv, fg_color="transparent")
        sw.grid(row=5, column=0, sticky="ew", padx=16, pady=(10, 0))
        self.main_sw = ctk.CTkSwitch(sw, text="鏡頭當主文字（粗體），機身放下面", variable=self.main_var,
                                     progress_color=ACCENT, command=self.schedule_preview)
        self.main_sw.grid(row=0, column=0, sticky="w")
        self.mirror_sw = ctk.CTkSwitch(sw, text="左右對調（參數在左，logo 與機型在右）", variable=self.mirror_var,
                                       progress_color=ACCENT, command=self.schedule_preview)
        self.mirror_sw.grid(row=1, column=0, sticky="w", pady=(8, 0))
        ct = line(6, "自訂文字", (10, 4), adv)
        ctk.CTkEntry(ct, textvariable=self.custom_text_var, height=30, corner_radius=10, border_width=0, fg_color=BTN,
                     placeholder_text="例如 @你的 IG 帳號（最多 60 字）").grid(row=0, column=1, sticky="ew")
        ctk.CTkFrame(c6, height=10, fg_color="transparent").grid(row=6, column=0)
        self.apply_advanced()
        self.update_footer_controls()

        # actions (pinned at the bottom)
        self.run_btn = ctk.CTkButton(bottom, text="處理勾選的照片", height=46, corner_radius=14,
                                     font=ctk.CTkFont(size=16, weight="bold"),
                                     fg_color=ACCENT, hover_color=ACCENT_HOVER, command=self.process_selected)
        self.run_btn.grid(row=0, column=0, sticky="ew", padx=16, pady=(8, 6))
        self.progress = ctk.CTkProgressBar(bottom, height=6, progress_color=ACCENT)
        self.progress.grid(row=1, column=0, sticky="ew", padx=20, pady=(0, 4))
        self.progress.grid_remove()
        st = ctk.CTkFrame(bottom, fg_color="transparent")
        st.grid(row=2, column=0, sticky="ew", padx=20, pady=(0, 8))
        st.columnconfigure(2, weight=1)
        self.dot = ctk.CTkLabel(st, text="●", text_color=MUTED, width=16)
        self.dot.grid(row=0, column=0)
        self.status = ctk.CTkLabel(st, text="待機中", text_color=MUTED, anchor="w")
        self.status.grid(row=0, column=1, padx=(2, 0), sticky="w")
        ctk.CTkButton(st, text="開啟輸出資料夾", width=100, height=24, corner_radius=12, fg_color="transparent",
                      hover_color=BTN_HOVER, text_color=MUTED, font=ctk.CTkFont(size=12),
                      command=self.open_output).grid(row=0, column=2, sticky="e")

    def folder_row(self, parent, row, title, var, cmd, which, last=False):
        f = ctk.CTkFrame(parent, fg_color="transparent")
        f.grid(row=row, column=0, sticky="ew", padx=16, pady=(0, 16 if last else 10))
        f.columnconfigure(1, weight=1)
        ctk.CTkLabel(f, text=title, width=56, anchor="w").grid(row=0, column=0)
        ent = ctk.CTkEntry(f, textvariable=var, height=34, corner_radius=10, border_width=0, fg_color=BTN,
                           placeholder_text="選擇輸出資料夾")
        ent.grid(row=0, column=1, sticky="ew", padx=(0, 6))
        ent.bind("<Return>", lambda e: self.out_changed())
        # long paths: show the end (the folder name) unless the user is editing the field
        def show_end(*_):
            try:
                if self.focus_get() is not ent._entry:
                    ent._entry.xview_moveto(1.0)
            except Exception:
                pass
        var.trace_add("write", lambda *a: ent.after(20, show_end))
        ent.after(300, show_end)
        ent.bind("<FocusOut>", lambda e: ent.after(20, show_end), add="+")
        btn = ctk.CTkButton(f, text="選擇 ▾", width=78, height=34, corner_radius=10, fg_color=BTN,
                            hover_color=BTN_HOVER, text_color=("gray10", "gray95"))
        btn.configure(command=lambda: self.show_source_menu(var, which, btn, cmd))
        btn.grid(row=0, column=2)
        if HAVE_DND:
            try:
                ent.drop_target_register(DND_FILES)
                ent.dnd_bind("<<Drop>>", lambda e, v=var: self.on_drop(e, v))
            except Exception:
                pass
        return ent

    # recently used folders (kept separately for input and output)
    def push_recent(self, which, text):
        text = self.clean_path(text)
        if text:
            setattr(self, which, ([text] + [x for x in getattr(self, which) if x != text])[:MAX_RECENT])

    def recent_entries(self, which):
        """[(menu label, path, missing)] for the recent list."""
        home = str(Path.home())
        out = []
        for t in getattr(self, which):
            try:
                missing = not Path(t).expanduser().is_dir()
            except OSError:
                missing = True
            shown = ("~" + t[len(home):]) if t.startswith(home) else t
            shown = shown if len(shown) <= 56 else "…" + shown[-55:]
            out.append((shown + ("（找不到）" if missing else ""), t, missing))
        return out

    def source_menu_items(self, which):
        """The entries of the 選擇 ▾ menu of the output folder as [(kind, label, state)]."""
        items = [("pick", "選擇資料夾…", "normal"), ("sep", "", "")]
        recents = self.recent_entries(which)
        if recents:
            items.append(("head", "最近使用", "disabled"))
            items += [("recent:" + path, label, "disabled" if missing else "normal") for label, path, missing in recents]
            items.append(("clear", "清除最近紀錄", "normal"))
        else:
            items.append(("head", "（還沒有最近使用的紀錄）", "disabled"))
        return items

    def show_source_menu(self, var, which, widget, pick_cmd):
        menu = tk.Menu(self, tearoff=0)
        for kind, label, state in self.source_menu_items(which):
            if kind == "sep":
                menu.add_separator()
            elif kind == "pick":
                menu.add_command(label=label, command=pick_cmd)
            elif kind == "head":
                menu.add_command(label=label, state="disabled")
            elif kind == "clear":
                menu.add_command(label=label, command=lambda: setattr(self, which, []))
            else:
                menu.add_command(label=label, state=state,
                                 command=lambda t=kind[len("recent:"):]: self.use_recent(var, which, t))
        try:
            menu.tk_popup(widget.winfo_rootx(), widget.winfo_rooty() + widget.winfo_height())
        finally:
            menu.grab_release()

    def use_recent(self, var, which, text):
        var.set(text)
        self.out_changed()

    def check_saved_paths(self):
        """Tell the user when the remembered output location is gone (e.g. an external drive that is not connected).
        Missing source folders are reported when the first background scan arrives."""
        out = self.out_var.get().strip()
        if out:
            po = Path(out).expanduser()
            if not po.exists() and not po.parent.is_dir():     # the drive / parent folder is not there
                self.set_status("找不到上次輸出資料夾的位置（外接硬碟沒有連上？）", AMBER)

    def build_right(self):
        right = ctk.CTkFrame(self, fg_color="transparent")
        right.grid(row=0, column=1, sticky="nsew", padx=(0, 16), pady=16)
        right.columnconfigure(0, weight=1)
        right.rowconfigure(0, weight=6)
        right.rowconfigure(2, weight=0, minsize=178)

        pv = ctk.CTkFrame(right, corner_radius=16, fg_color=PV_BG)
        pv.grid(row=0, column=0, sticky="nsew")
        pv.columnconfigure(0, weight=1)
        pv.rowconfigure(0, weight=1)
        # a plain Tk label: swapping the image of a CTkLabel costs ~60 ms per frame, a Tk label ~5 ms
        self.preview_frame = pv
        self.preview_bg_cache = self.preview_bg()
        self.preview_photo = None
        self.preview_lbl = tk.Label(pv, bd=0, highlightthickness=0, bg=self.preview_bg_cache)
        self.preview_lbl.grid(row=0, column=0, sticky="nsew", padx=12, pady=(12, 4))
        self.preview_lbl.bind("<Configure>", lambda e: self.schedule_view())
        self.preview_lbl.bind("<MouseWheel>", self.on_wheel)
        try:
            self.preview_lbl.bind("<TouchpadScroll>", self.on_touchpad)
        except tk.TclError:
            pass
        self.preview_lbl.bind("<ButtonPress-1>", self.on_press)
        self.preview_lbl.bind("<B1-Motion>", self.on_drag)
        self.preview_lbl.bind("<ButtonRelease-1>", self.on_release)
        self.preview_lbl.bind("<Double-Button-1>", self.on_double)
        sbc = dict(fg_color="transparent", button_color=("#9aa0ab", "#5a5f69"), button_hover_color=("#7b818e", "#737985"))
        self.vbar = ctk.CTkScrollbar(pv, orientation="vertical", command=self.on_vscroll, width=12, **sbc)
        self.hbar = ctk.CTkScrollbar(pv, orientation="horizontal", command=self.on_hscroll, height=12, **sbc)
        bar = ctk.CTkFrame(pv, fg_color="transparent")
        bar.grid(row=1, column=0, sticky="ew", padx=12, pady=(0, 2))
        bar.columnconfigure(2, weight=1)                              # spare space sits between button and zoom controls
        hq = ctk.CTkFrame(bar, fg_color="transparent", width=124, height=28)    # fixed box for the status text
        hq.grid(row=0, column=0, sticky="w")
        hq.grid_propagate(False)
        self.hq_lbl = ctk.CTkLabel(hq, text="", text_color=MUTED, font=ctk.CTkFont(size=12))
        self.hq_lbl.grid(row=0, column=0)
        self.hq_bar = ctk.CTkProgressBar(hq, mode="indeterminate", width=60, height=5, progress_color=ACCENT)
        self.hq_bar.grid(row=0, column=1, padx=(8, 0))
        self.hq_bar.grid_remove()
        cmp_btn = ctk.CTkButton(bar, text="按住對照原圖", width=96, height=28, corner_radius=14, fg_color=BTN,
                                hover_color=BTN_HOVER, text_color=("gray10", "gray95"), font=ctk.CTkFont(size=12))
        cmp_btn.grid(row=0, column=1, sticky="w", padx=(4, 0))      # right after the fixed status box: never moves
        cmp_btn.bind("<ButtonPress-1>", lambda e: self.set_compare(True), add="+")
        cmp_btn.bind("<ButtonRelease-1>", lambda e: self.set_compare(False), add="+")
        zc = ctk.CTkFrame(bar, fg_color="transparent")
        zc.grid(row=0, column=2, sticky="e")
        small = dict(height=28, corner_radius=14, fg_color=BTN, hover_color=BTN_HOVER,
                     text_color=("gray10", "gray95"), font=ctk.CTkFont(size=12))
        ctk.CTkButton(zc, text="－", width=30, command=lambda: self.zoom_step(1 / 1.25), **small
                      ).grid(row=0, column=0)
        self.zoom_slider = ctk.CTkSlider(zc, from_=0, to=1, width=80, height=16, button_color=ACCENT,
                                         button_hover_color=ACCENT_HOVER, progress_color=ACCENT,
                                         command=self.on_zoom_slider)
        self.zoom_slider.set(0)
        self.zoom_slider.grid(row=0, column=1, padx=6)
        ctk.CTkButton(zc, text="＋", width=30, command=lambda: self.zoom_step(1.25), **small).grid(row=0, column=2)
        self.zoom_pct = ctk.CTkLabel(zc, text="", width=46, font=ctk.CTkFont(size=12))
        self.zoom_pct.grid(row=0, column=3, padx=(6, 2))
        ctk.CTkButton(zc, text="100%", width=48, command=lambda: self.zoom_to(1.0), **small
                      ).grid(row=0, column=4, padx=2)
        ctk.CTkButton(zc, text="適合視窗", width=72, command=self.reset_view, **small).grid(row=0, column=5, padx=(2, 0))
        ctk.CTkLabel(pv, text="雙指滑動：平移　⌘＋滑動：縮放　雙擊：100% / 適合視窗　按住 \\ ：對照原圖",
                     text_color=MUTED, font=ctk.CTkFont(size=11)).grid(row=2, column=0, pady=(0, 8))

        head = ctk.CTkFrame(right, fg_color="transparent")
        head.grid(row=1, column=0, sticky="ew", pady=(12, 6))
        head.columnconfigure(0, weight=1)
        self.count_lbl = ctk.CTkLabel(head, text="尚未加入來源", anchor="w", font=ctk.CTkFont(size=14, weight="bold"))
        self.count_lbl.grid(row=0, column=0, sticky="w")
        for i, (label, cmd) in enumerate((("全選", lambda: self.set_all(True)), ("全不選", lambda: self.set_all(False)),
                                          ("重新整理", self.reload))):
            ctk.CTkButton(head, text=label, width=64, height=26, corner_radius=13, fg_color=BTN,
                          hover_color=BTN_HOVER, text_color=("gray10", "gray95"), font=ctk.CTkFont(size=12),
                          command=cmd).grid(row=0, column=1 + i, padx=(6, 0))

        self.strip = SmoothScrollFrame(right, orientation="horizontal", corner_radius=14, fg_color=CARD, height=140,
                                       **SCROLLBAR)
        self.strip.grid(row=2, column=0, sticky="nsew")
        if HAVE_DND:
            for target in (self.strip._parent_canvas, self.preview_lbl):
                try:
                    target.drop_target_register(DND_FILES)
                    target.dnd_bind("<<Drop>>", lambda e: self.on_drop(e, None))
                except Exception:
                    pass
        self.empty_lbl = ctk.CTkLabel(self.strip, text="用左邊的「＋ 資料夾」或「＋ 照片」加入來源，也可以直接把照片拖進來", text_color=MUTED)
        self.empty_lbl.grid(row=0, column=0, padx=24, pady=50)

    # ---------------- config ----------------
    def load_cfg(self):
        try:
            if CONFIG.stat().st_size > 1_000_000:
                return {}
            data = json.loads(CONFIG.read_text())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def save_cfg(self):
        try:
            data = {
                "sources": [dict(x) for x in self.sources], "active_source": self.active_source,
                "output": self.out_var.get(), "ratio": self.ratio,
                "size": self.size_var.get(), "thickness": round(self.thick_var.get(), 1),
                "footer": bool(self.footer_on.get()), "footer_layout": self.layout_var.get(),
                "style": self.style_var.get(), "footer_divider": bool(self.divider_var.get()),
                "footer_center_divider": bool(self.cdivider_var.get()),
                "overwrite": bool(self.overwrite_var.get()),
                "footer_fields": [k for k, v in self.field_vars.items() if v.get()],
                "text_scale": round(self.text_scale.get()), "logo_scale": round(self.logo_scale.get()),
                "height_scale": round(self.height_scale.get()), "bold": bool(self.bold_var.get()),
                "color_choice": self.color_var.get(), "custom_color": self.custom_color,
                "date_format": DATE_LABELS.get(self.datefmt_var.get(), "ymd_dot"),
                "logo_pos": LOGO_POS_LABELS.get(self.logopos_var.get(), "left"),
                "custom_text": self.clean_text(self.custom_text_var.get()),
                "lens_main": bool(self.main_var.get()), "mirror": bool(self.mirror_var.get()),
                "advanced_open": bool(self.adv_open), "theme": THEME,
                "exposure_items": [k for k, v in self.exp_vars.items() if v.get()],
                "exposure_order": EXPO_ORDER_LABELS.get(self.exporder_var.get(), "std"),
                "font": self.font_labels.get(self.font_var.get(), "auto"),
                "style_slots": self.style_slots, "imported": [str(p) for p in self.imported],
                "recent_outputs": self.recent_out,
                "presets": self.presets, "geometry": self.winfo_geometry()}
        except tk.TclError:
            return
        tmp = None
        try:                                    # write-then-rename so a crash never leaves half a file
            fd, tmp = tempfile.mkstemp(prefix=".ig_border_gui.", suffix=".tmp", dir=str(CONFIG.parent))
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.replace(tmp, CONFIG)
            tmp = None
        except (OSError, TypeError, ValueError):
            pass
        finally:
            if tmp and os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass

    # ---------------- controls ----------------
    def set_ratio(self, val):
        self.ratio = val
        self.refresh_ratio_buttons()
        self.schedule_preview()

    def refresh_ratio_buttons(self):
        for val, b in self.ratio_btns.items():
            if val == self.ratio:
                b.configure(fg_color=ACCENT, hover_color=ACCENT_HOVER, text_color="white", image=self.icons[val][1])
            else:
                b.configure(fg_color=BTN, hover_color=BTN_HOVER, text_color=("gray10", "gray95"),
                            image=self.icons[val][0])

    def on_thick(self, *_):
        self.thick_lbl.configure(text="%d" % round(self.thick_var.get()))
        self.schedule_preview(interactive=True)

    def pick_folder(self):
        """Add a folder to the sources (and show it)."""
        start = Path(self.active_source).parent if self.find_source(self.active_source) else Path.home()
        d = filedialog.askdirectory(initialdir=str(start) if start.is_dir() else str(Path.home()))
        if d and self.add_folder(d):
            self.on_sources_changed()
            self.set_status("已加入資料夾「%s」" % self.source_label(self.active_source), GREEN)

    def pick_out(self):
        d = filedialog.askdirectory(initialdir=self.out_var.get() or str(Path.home()))
        if d:
            self.out_var.set(d)
            self.out_changed()

    def on_drop(self, event, var):
        """Drop photos and / or folders: photos are imported, folders become sources.
        The output field only takes a folder."""
        try:
            paths = [Path(x).expanduser() for x in self.tk.splitlist(event.data)][:2000]
        except (tk.TclError, OSError, ValueError):
            return
        folders = [q for q in paths if q.is_dir()]
        files = [q for q in paths if q.is_file()]
        if var is self.out_var:
            if folders:
                var.set(str(folders[0].resolve()))
                self.out_changed()
            else:
                self.set_status("輸出位置請拖入資料夾", MUTED)
            return
        if files:
            self.import_files(files)
        added = 0
        for q in folders[:MAX_SOURCES]:
            if self.add_folder(str(q), activate=(added == 0)):
                added += 1
        if added:
            self.on_sources_changed()
        if not folders and not files:
            self.set_status("沒有可用的照片或資料夾", MUTED)

    def import_dialog(self):
        picked = filedialog.askopenfilenames(title="匯入照片", filetypes=[("照片", "*.jpg *.jpeg *.png *.tif *.tiff")])
        if picked:
            self.import_files([Path(x) for x in picked])

    def import_files(self, paths):
        """Add photos to the list where they are (nothing is copied or moved). Returns how many were new."""
        added, skipped = [], 0
        for q in paths:
            try:
                rp = q.expanduser().resolve()
                valid = rp.is_file() and rp.suffix.lower() in ig_border.EXTS and not rp.name.startswith(".")
            except (OSError, RuntimeError):
                valid = False
            if not valid:
                skipped += 1
            elif rp not in self.imported and len(self.imported) < MAX_PHOTOS:
                self.imported.append(rp)
                added.append(rp)
        if added:
            self.active_source = "imported"          # like Lightroom: show what was just imported
        self.on_sources_changed(save=bool(added))
        if added:
            self.select_photo(added[0])
        msg = "已匯入 %d 張照片" % len(added)
        if skipped:
            msg += "，略過 %d 個不是照片的檔案" % skipped
        self.set_status(msg, GREEN if added else AMBER)
        return len(added)

    def clear_imported(self):
        self.remove_sources(["imported"])

    def tile_menu(self, event, p):
        """Right-click on a thumbnail: remove an imported photo from the list (the file itself is untouched)."""
        if p not in self.imported:
            return
        menu = tk.Menu(self, tearoff=0)
        menu.add_command(label="從清單移除（不會刪除檔案）", command=lambda: self.remove_imported(p))
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def remove_imported(self, p):
        """Right-click on one imported photo: take it out of the list (the file itself is untouched)."""
        if p in self.imported:
            self.imported.remove(p)
            if not self.imported and self.active_source == "imported":
                self.active_source = "all"
            self.on_sources_changed()

    def open_output(self):
        try:
            out = Path(self.out_var.get().strip()).expanduser().resolve()
        except (OSError, RuntimeError):
            return
        if not out.is_dir():
            self.set_status("輸出資料夾還不存在", MUTED)
            return
        cmd = ["open", str(out)] if sys.platform == "darwin" else ["xdg-open", str(out)]   # absolute path, no shell
        try:
            subprocess.Popen(cmd)                # do not block the UI
        except OSError:
            self.set_status("無法開啟資料夾", RED)

    def color_hex(self):
        c = self.color_var.get()
        return self.custom_color if c == "自訂…" else COLOR_VALUES.get(c)

    def footer_opts(self):
        return {"footer": bool(self.footer_on.get()),
                "footer_layout": LAYOUT_LABELS.get(self.layout_var.get(), "classic3"),
                "footer_fields": [k for k, v in self.field_vars.items() if v.get()],
                "footer_divider": bool(self.divider_var.get()),
                "footer_center_divider": bool(self.cdivider_var.get()),
                "footer_text_scale": self.text_scale.get() / 100, "footer_logo_scale": self.logo_scale.get() / 100,
                "footer_height_scale": self.height_scale.get() / 100, "footer_color": self.color_hex(),
                "footer_bold": bool(self.bold_var.get()),
                "footer_date_format": DATE_LABELS.get(self.datefmt_var.get(), "ymd_dot"),
                "footer_logo_pos": LOGO_POS_LABELS.get(self.logopos_var.get(), "left"),
                "footer_custom_text": self.clean_text(self.custom_text_var.get()),
                "footer_main": "lens" if self.main_var.get() else "model",
                "footer_mirror": bool(self.mirror_var.get()),
                "footer_exposure_items": [k for k, v in self.exp_vars.items() if v.get()],
                "footer_exposure_order": EXPO_ORDER_LABELS.get(self.exporder_var.get(), "std"),
                "footer_font": self.font_labels.get(self.font_var.get(), "auto"),
                "footer_style": self.style_slots}

    def refresh_fonts(self):
        """Re-scan system fonts and ./fonts/ (after the user drops a new font file there)."""
        ig_border._font.cache_clear()
        self.font_labels = {label: key for key, label in ig_border.available_fonts()}
        self.font_menu.configure(values=list(self.font_labels))
        if self.font_var.get() not in self.font_labels:
            self.font_var.set(DEFAULT_FONT_LABEL)
        self.set_status("已重新掃描字體（%d 種）" % len(self.font_labels), GREEN)
        self.schedule_preview()

    def on_theme(self, label):
        """Colours are baked into the widgets when they are built, so a new palette means restarting the program."""
        name = next((k for k, v in PALETTES.items() if v["label"] == label), THEME)
        if name == THEME:
            return
        if self.batch and self.batch.is_alive():
            messagebox.showinfo("處理中", "還有照片正在處理，請等處理完再切換配色。")
            self.theme_var.set(PALETTES[THEME]["label"])
            return
        if not messagebox.askyesno("切換配色", "切換配色需要重新啟動程式（設定會保留）。現在重新啟動嗎？"):
            self.theme_var.set(PALETTES[THEME]["label"])
            return
        self.save_cfg()
        try:                                   # save_cfg wrote the old name; update only that key, atomically
            data = json.loads(CONFIG.read_text())
            data["theme"] = name
            fd, tmp = tempfile.mkstemp(prefix=".ig_border_gui.", suffix=".tmp", dir=str(CONFIG.parent))
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.replace(tmp, CONFIG)
        except (OSError, ValueError):
            self.theme_var.set(PALETTES[THEME]["label"])
            return
        os.execv(sys.executable, [sys.executable] + sys.argv)

    def set_app_icon(self):
        """Window / Dock icon from assets/icon_1024.png (optional: the app runs fine without it)."""
        try:
            img = Image.open(ICON_FILE).convert("RGBA").resize((256, 256), Image.LANCZOS)
            self.app_icon = ImageTk.PhotoImage(img)           # keep a reference or Tk drops it
            self.iconphoto(True, self.app_icon)
        except (OSError, tk.TclError, ValueError):
            pass

    def toggle_advanced(self):
        self.adv_open = not self.adv_open
        self.apply_advanced()

    def apply_advanced(self):
        if self.adv_open:
            self.adv_frame.grid(row=5, column=0, sticky="ew")
        else:
            self.adv_frame.grid_remove()
        self.adv_btn.configure(text=("▾ 進階" if self.adv_open else "▸ 進階（字體、顏色、logo 位置…）"))

    def on_footer_change(self, *_):
        self.update_footer_controls()
        self.schedule_preview()

    def update_footer_controls(self):
        """Grey out what the chosen layout does not use, and say why, instead of relying on small print."""
        layout = LAYOUT_LABELS.get(self.layout_var.get(), "classic3")

        def on(widget, flag):
            widget.configure(state="normal" if flag else "disabled")

        for cb in self.field_cbs.values():
            on(cb, layout in FIELDS_LAYOUTS)
        expo_ok = layout in ("classic3", "center1", "center2", "split", "custom")
        for cb in self.exp_cbs.values():
            on(cb, expo_ok and (layout == "custom" or self.field_vars["exposure"].get()))
        on(self.exporder_menu, expo_ok)
        on(self.datefmt_menu, layout != "logo")
        classic = layout == "classic3"
        centred = layout in ("center1", "center2")
        if centred:                                  # same checkbox, bound to the setting the layout actually uses
            self.divider_cb.configure(text="項目之間加分隔線", variable=self.cdivider_var)
        else:
            self.divider_cb.configure(text="分隔線（右側區塊前）", variable=self.divider_var)
        on(self.divider_cb, classic or centred)
        on(self.main_sw, classic)
        on(self.mirror_sw, classic)
        on(self.logopos_menu, classic)
        if layout == "custom":
            self.footer_hint.configure(text="自訂樣式：顯示項目由「編輯樣式」決定。")
        elif layout == "logo":
            self.footer_hint.configure(text="只放 logo：不顯示相機、鏡頭、日期與參數。")
        elif not classic:
            self.footer_hint.configure(text="鏡頭主文字、左右對調、logo 位置只在「經典三欄」有效。")
        else:
            self.footer_hint.configure(text="")

    def apply_look(self, name):
        look = FOOTER_LOOKS.get(name)
        if look is not None:
            self.apply_settings({**FOOTER_BASE, **look})
            self.set_status("已套用樣式：%s" % name, GREEN)

    def slider_row(self, parent, row, text, var, lo, hi):
        f = ctk.CTkFrame(parent, fg_color="transparent")
        f.grid(row=row, column=0, sticky="ew", padx=16, pady=(0, 6))
        f.columnconfigure(0, weight=1)
        ctk.CTkLabel(f, text=text, anchor="w").grid(row=0, column=0, sticky="w")
        pct = ctk.CTkLabel(f, text="", width=48, corner_radius=8, fg_color=BTN)
        pct.grid(row=0, column=1, sticky="e")

        def show(*_):
            try:
                pct.configure(text="%d%%" % round(var.get()))
            except tk.TclError:
                pass

        def changed(*_):
            show()
            self.schedule_preview(interactive=True)

        sl = ctk.CTkSlider(f, from_=lo, to=hi, number_of_steps=hi - lo, variable=var, height=16,
                           button_color=ACCENT, button_hover_color=ACCENT_HOVER, progress_color=ACCENT, command=changed)
        sl.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(4, 0))
        sl.bind("<Double-Button-1>", lambda e: (var.set(100), changed()), add="+")     # double-click = reset
        var.trace_add("write", show)          # presets / config also update the label
        show()

    def on_color(self, choice):
        if choice == "自訂…":
            picked = colorchooser.askcolor(color=self.custom_color, title="選擇文字顏色")
            if picked and picked[1] and re.fullmatch(r"#[0-9a-fA-F]{6}", picked[1]):
                self.custom_color = picked[1]
            elif self.custom_color == DEFAULT_CUSTOM_COLOR and not picked[1]:
                self.color_var.set("自動")
        self.schedule_preview()

    # ---------------- sources (Lightroom-style: remembered places, nothing is copied or moved) ----------------
    @staticmethod
    def norm_path(text):
        text = App.clean_path(text)
        if not text:
            return ""
        try:
            return str(Path(text).expanduser().resolve())
        except (OSError, RuntimeError):
            return text

    @staticmethod
    def load_sources(cfg):
        """The remembered source folders: type-checked, de-duplicated, capped. (Earlier versions kept a single
        input folder under "input".)"""
        raw = cfg.get("sources")
        if not isinstance(raw, list):
            old = cfg.get("input")
            raw = [{"path": old}] if isinstance(old, str) and old.strip() else []
        out, seen = [], set()
        for x in raw[:MAX_SOURCES * 2]:
            if not isinstance(x, dict):
                continue
            path = App.norm_path(x.get("path"))
            if not path or path in seen:
                continue
            seen.add(path)
            out.append({"path": path, "name": App.clean_text(x.get("name"), 40)})
            if len(out) >= MAX_SOURCES:
                break
        return out

    def find_source(self, key):
        return next((x for x in self.sources if x["path"] == key), None)

    def source_label(self, key):
        if key == "all":
            return "全部照片"
        if key == "imported":
            return "已匯入的照片"
        src = self.find_source(key)
        return (src["name"] or Path(key).name or key) if src else key

    def active_missing(self):
        key = self.active_source
        if key in ("all", "imported"):
            return False
        try:
            return not Path(key).is_dir()
        except OSError:
            return True

    def source_missing(self, key):
        info = self.src_info.get(key)
        return bool(info and info.get("missing"))

    def source_count_text(self, key):
        """(text, missing) for the card and the manager, from the background scan."""
        info = self.src_info.get(key)
        if info is None:
            return "…", False
        if info.get("missing"):
            return "找不到", True
        return "%d 張 · 已輸出 %d" % (info["total"], info["done"]), False

    def add_folder(self, text, activate=True):
        path = self.norm_path(text)
        try:
            ok = bool(path) and Path(path).is_dir()
        except OSError:
            ok = False
        if not ok:
            self.set_status("這不是資料夾", AMBER)
            return False
        if self.find_source(path) is None:
            if len(self.sources) >= MAX_SOURCES:
                self.set_status("來源最多 %d 個，請先移除不用的" % MAX_SOURCES, AMBER)
                return False
            self.sources.append({"path": path, "name": ""})
        if activate:
            self.active_source = path
        return True

    def set_active(self, key):
        if key not in ("all", "imported") and self.find_source(key) is None:
            return
        if key == self.active_source:
            return
        self.active_source = key
        self.on_sources_changed()

    def remove_sources(self, keys):
        """Take sources out of the list ("imported" clears the imported photos). No file is touched."""
        keys = set(keys)
        if "imported" in keys:
            self.imported = []
        self.sources = [x for x in self.sources if x["path"] not in keys]
        if self.active_source in keys:
            self.active_source = "all"
        self.on_sources_changed()
        self.set_status("已從清單移除 %d 個來源（檔案沒有動）" % len(keys), MUTED)

    def open_source_manager(self):
        if self.manager_open():
            self.source_manager.lift()
            self.source_manager.focus_force()
            return
        self.scan_sources()
        self.source_manager = SourceManager(self)

    def manager_open(self):
        try:
            return self.source_manager is not None and bool(self.source_manager.winfo_exists())
        except tk.TclError:
            return False

    def refresh_manager(self):
        if self.manager_open():
            self.source_manager.build_rows()

    def source_menu_label(self, key):
        """Name of a source for the menu, with its photo count once the background scan has it."""
        if key == "all":
            return "全部照片"
        text, missing = self.source_count_text(key)
        base = self.source_label(key)
        if missing:
            return base + "（找不到）"
        return base if text == "…" else "%s（%s）" % (base, text.split(" · ")[0])

    def popup(self, menu, widget):
        try:
            menu.tk_popup(widget.winfo_rootx(), widget.winfo_rooty() + widget.winfo_height())
        finally:
            menu.grab_release()

    def show_pick_menu(self, widget):
        """選擇: switch the shown source (全部照片, a folder, the imported photos) or add folders / photos."""
        menu = tk.Menu(self, tearoff=0)
        keys = ["all"] + [x["path"] for x in self.sources] + (["imported"] if self.imported else [])
        for key in keys:
            label = "已匯入的照片（%d 張）" % len(self.imported) if key == "imported" else self.source_menu_label(key)
            mark = "✓ " if key == self.active_source else "    "
            menu.add_command(label=mark + label, command=lambda k=key: self.set_active(k))
        menu.add_separator()
        menu.add_command(label="加入資料夾…", command=self.pick_folder)
        menu.add_command(label="匯入照片…", command=self.import_dialog)
        menu.add_separator()
        menu.add_command(label="管理來源…", command=self.open_source_manager)
        self.popup(menu, widget)

    def source_label_parts(self):
        """(name, count text) of the source that is on screen."""
        key = self.active_source
        if key == "imported":
            if len(self.imported) == 1:
                return self.imported[0].name, "1 張"
            return "已匯入的照片", "%d 張" % len(self.imported)
        if not self.sources and not self.imported:
            return "還沒有來源，按「選擇」加入", ""
        if key == "all":
            total = sum(i["total"] for k, i in self.src_info.items() if not i.get("missing"))
            return "全部照片", ("%d 張" % total) if self.src_info else ""
        text, missing = self.source_count_text(key)
        return self.source_label(key) + ("（找不到）" if missing else ""), ("" if missing or text == "…" else text.split(" · ")[0])

    def rebuild_source_card(self):
        """The main window shows only the source that is on screen right now."""
        self.fit_source_label()

    def fit_source_label(self):
        """Folder / file name plus count, the name shortened in the middle when the box is too narrow."""
        try:
            name, count = self.source_label_parts()
            suffix = "（%s）" % count if count else ""
            font = self.src_label.cget("font")
            room = max(40, self.src_label.winfo_width() - 24)
            if font.measure(name + suffix) > room:
                suffix = ""                      # the name matters more than the count (which is also above the strip)
            if font.measure(name) > room:
                keep = len(name)
                while keep > 4 and font.measure(name[:keep // 2 + keep % 2] + "…" + name[len(name) - keep // 2:]) > room:
                    keep -= 1
                name = name[:keep // 2 + keep % 2] + "…" + name[len(name) - keep // 2:]
            key = self.active_source
            missing = key not in ("all", "imported") and self.source_missing(key)
            self.src_label.configure(text="  " + name + suffix, text_color=RED if missing else ("gray10", "gray95"))
        except (tk.TclError, AttributeError):
            pass

    def scan_sources(self):
        """Count the photos of every source in the background (a slow or missing drive must not freeze the UI)."""
        self.scan_id += 1
        threading.Thread(target=self.scan_worker, daemon=True,
                         args=(self.scan_id, [x["path"] for x in self.sources], list(self.imported),
                               self.out_var.get().strip())).start()

    def scan_worker(self, sid, folders, imported, out_text):
        out = Path(out_text).expanduser() if out_text else None

        def exported(p):
            try:
                return out is not None and (out / ig_border.output_name(p)).exists()
            except OSError:
                return False

        info = {}
        for key in folders:
            try:
                d = Path(key)
                if not d.is_dir():
                    info[key] = {"missing": True, "total": 0, "done": 0}
                    continue
                files = list(ig_border.candidates(d))
                info[key] = {"missing": False, "total": len(files), "done": sum(exported(p) for p in files)}
            except OSError:
                info[key] = {"missing": True, "total": 0, "done": 0}
        files = []
        for p in imported:
            try:
                if p.is_file():
                    files.append(p)
            except OSError:
                pass
        info["imported"] = {"missing": False, "total": len(files), "done": sum(exported(p) for p in files)}
        self.msg_q.put(("src_counts", sid, info))

    def on_src_counts(self, sid, info):
        if sid != self.scan_id:                       # an older scan: a newer one is on its way
            return
        self.src_info = info
        self.rebuild_source_card()
        if self.manager_open():
            self.source_manager.update_counts()
        if not self.first_scan_seen:
            self.first_scan_seen = True
            gone = sum(1 for x in self.sources if self.source_missing(x["path"]))
            if gone:
                self.set_status("有 %d 個來源資料夾找不到（外接硬碟沒有連上？）" % gone, AMBER)
            if not self.photos:
                self.refresh_photos(force=True)

    # ---------------- photo strip ----------------
    def out_dir(self):
        text = self.out_var.get().strip()
        return Path(text).expanduser() if text else None

    def initial_state(self, p):
        out = self.out_dir()
        try:
            if out is not None and (out / self.out_name(p)).exists():
                return "已有輸出"
        except OSError:
            pass
        return "待處理"

    def scope_sources(self):
        """Folder sources that belong to the current view."""
        if self.active_source == "all":
            return [x["path"] for x in self.sources]
        if self.active_source == "imported":
            return []
        return [self.active_source]

    def list_photos(self):
        """(photo, mtime) of the current view (a source, or all of them), de-duplicated, at most MAX_PHOTOS."""
        items, seen = [], set()
        for key in self.scope_sources():
            try:
                d = Path(key)
                if not d.is_dir():
                    continue
                for p in ig_border.candidates(d):
                    try:
                        rk = str(p.resolve())
                        if rk not in seen:
                            items.append((p, p.stat().st_mtime_ns))
                            seen.add(rk)
                    except OSError:
                        continue
            except OSError:
                continue
        if self.active_source in ("all", "imported"):
            for p in self.imported:
                try:
                    if str(p) not in seen and p.is_file():
                        items.append((p, p.stat().st_mtime_ns))
                        seen.add(str(p))
                except OSError:
                    continue
        return items[:MAX_PHOTOS], len(items) > MAX_PHOTOS

    @staticmethod
    def assign_names(paths):
        """Output file name per photo; two photos that would get the same name (e.g. IMG_1.jpg from two
        different folders) get _2, _3 ... so that they never overwrite each other."""
        used, out = {}, {}
        for p in paths:
            base = ig_border.output_name(p)
            used[base] = used.get(base, 0) + 1
            out[p] = base if used[base] == 1 else "%s_%d.jpg" % (base[:-len(".jpg")], used[base])
        return out

    def out_name(self, p):
        return self.name_map.get(p) or ig_border.output_name(p)

    def reload(self):
        self.refresh_photos(force=True)
        self.scan_sources()

    def out_changed(self):
        self.refresh_states()
        self.scan_sources()          # the "already exported" counts of the sources depend on the output folder

    def on_sources_changed(self, save=True):
        """The list of sources or the shown source changed: re-list, redraw the card, update the counts."""
        self.refresh_photos(force=True)
        if self.photos and self.selected not in self.photos:
            self.select_photo(self.photos[0])
        self.rebuild_source_card()
        self.scan_sources()
        self.refresh_manager()
        if save:
            self.save_cfg()

    def poll(self):
        delay = 2000
        try:
            t0 = time.monotonic()
            self.poll_tick += 1
            if self.poll_tick % 10 == 0 and self.manager_open():
                self.scan_sources()
            self.refresh_photos()
            if time.monotonic() - t0 > 0.15:     # huge folder / slow disk: poll less often
                delay = 6000
        except Exception:
            pass
        finally:
            self.after(delay, self.poll)

    def refresh_photos(self, force=False):
        missing = self.active_missing()
        items, capped = self.list_photos()
        sig = (self.active_source, tuple((p.name, mt) for p, mt in items))
        if sig == self.photo_sig and not force:
            self.refresh_states()
            return
        self.photo_sig = sig
        self.capped = capped
        paths = [p for p, _ in items]
        mtimes = dict(items)
        for p in list(self.tiles):                       # drop tiles that are not in this view any more
            if p not in mtimes:
                self.tiles.pop(p)["tile"].destroy()
                try:
                    gone = not p.exists()
                except OSError:
                    gone = True
                if gone:                                 # deleted: forget it; just not shown: keep ticks / state / thumbnail
                    self.checked.pop(p, None)
                    self.states.pop(p, None)
                    self.thumbs.pop(p, None)
                    self.thumb_base.pop(p, None)
                    self.badge_shown.pop(p, None)
        if self.selected is not None and self.selected not in mtimes:      # the selected photo was deleted
            self.selected = None
        if self.empty_lbl is not None and paths:
            self.empty_lbl.destroy()
            self.empty_lbl = None
        new_tiles = []
        for p in paths:
            if p not in self.tiles:
                self.make_tile(p)
                new_tiles.append(p)
            cached = self.thumb_base.get(p)
            if (cached is None or cached[0] != mtimes[p]) and (p, mtimes[p]) not in self.thumb_pending:
                self.thumb_pending.add((p, mtimes[p]))
                self.thumb_q.put((p, mtimes[p]))
        for i, p in enumerate(paths):
            self.tiles[p]["tile"].grid(row=0, column=i, padx=4, pady=4)
        self.photos = paths
        self.name_map = self.assign_names(paths)
        for p in new_tiles:                              # only a state that changed while the tile was away is redrawn
            if self.badge_shown.get(p) != self.states.get(p, "待處理"):
                self.refresh_thumb(p)
        if (self.selected is not None and self.preview_path == self.selected
                and self.preview_mtime is not None and mtimes[self.selected] != self.preview_mtime):
            self.select_photo(self.selected)        # same name re-exported from Lightroom: reload the preview
        self.refresh_states()
        self.update_count()
        if not paths:
            if not self.sources and not self.imported:
                msg = "用左邊的「＋ 資料夾」或「＋ 照片」加入來源，也可以直接把照片拖進來"
            elif missing:
                msg = "找不到這個資料夾（外接硬碟沒有連上？）"
            else:
                msg = "這個來源裡沒有 jpg / png / tif 照片"
            if self.empty_lbl is None:
                self.empty_lbl = ctk.CTkLabel(self.strip, text=msg, text_color=MUTED)
                self.empty_lbl.grid(row=0, column=0, padx=24, pady=50)
            else:
                self.empty_lbl.configure(text=msg)

    def make_tile(self, p):
        cached = self.thumbs.get(p)                 # a tile that comes back already has its thumbnail and badge
        var = self.checked.get(p) or tk.BooleanVar(value=True)
        self.checked[p] = var
        name = p.name
        if p in self.imported:                      # "＋" marks photos that were imported (not from the folder)
            name = "＋" + name
        name = name if len(name) <= 13 else name[:12] + "…"
        tile = PhotoTile(self.strip, name, var, cached[1] if cached else self.placeholder_thumb,
                         on_select=lambda path=p: self.select_photo(path),
                         on_menu=lambda e, path=p: self.tile_menu(e, path), on_check=self.update_count)
        self.tiles[p] = {"tile": tile}
        tile.set_state(self.states.get(p, "待處理"))

    def set_state(self, p, text):
        self.states[p] = text
        self.refresh_thumb(p)

    def refresh_thumb(self, p, force=False):
        """Show the thumbnail of `p` with the badge of its current state drawn on it."""
        t = self.tiles.get(p)
        if t is None:
            return
        state = self.states.get(p, "待處理")
        if not force and self.badge_shown.get(p) == state:
            return                                   # nothing changed: avoid needless redraws on every poll
        base = self.thumb_base[p][1] if p in self.thumb_base else None
        if base is None:
            if not STATE_TEXT.get(state):
                self.badge_shown[p] = state
                return                                # placeholder, no badge: the tile already shows it
            base = Image.new("RGB", THUMB, THUMB_BG)
        mt = self.thumb_base[p][0] if p in self.thumb_base else 0
        cached = self.thumbs.get(p)
        if p in self.thumb_base and cached is not None and cached[0] == mt:
            ph = cached[1]                                 # the plain thumbnail did not change: only the pill did
        else:
            ph = ImageTk.PhotoImage(base)
            self.thumbs[p] = (mt, ph)
        t["tile"].set_photo(ph)
        t["tile"].set_state(state)
        self.badge_shown[p] = state

    def refresh_states(self):
        """Idle photos show whether an output already exists; finished / failed states are kept."""
        for p in self.tiles:
            cur = self.states.get(p)
            if cur in (None, "待處理", "已有輸出"):
                self.set_state(p, self.initial_state(p))

    def update_count(self):
        n = len(self.photos)
        name = self.source_label(self.active_source)
        if n == 0:
            if not self.sources and not self.imported:
                text = "尚未加入來源"
            else:
                text = "%s · %s" % (name, "找不到資料夾" if self.active_missing() else "尚無照片")
            self.count_lbl.configure(text=text)
            return
        sel = sum(1 for p in self.photos if self.checked[p].get())
        extra = "（僅顯示前 %d 張）" % MAX_PHOTOS if self.capped else ""
        imported = set(self.imported)
        imp = sum(1 for p in self.photos if p in imported)
        if imp and self.active_source != "imported":
            extra += "（含匯入 %d 張，＋ 為匯入）" % imp
        self.count_lbl.configure(text="%s · %d 張相片 · 已選 %d 張%s" % (name, n, sel, extra))

    def set_all(self, value):
        for p in self.photos:
            self.checked[p].set(value)
        self.update_count()

    def select_photo(self, p):
        """Show `p` in the preview. Returns False when the file cannot be read."""
        if self.set_preview_file(p):
            self.selected = p
            for q, t in self.tiles.items():
                t["tile"].set_selected(q == p)
            self.schedule_preview()
            return True
        return False

    # thumbnails (one background thread; the UI thread only builds the CTkImage)
    def thumb_worker(self):
        while True:
            item = self.thumb_q.get()
            if item is None:
                return
            p, mt = item
            thumb = None
            try:
                with ig_border.open_image(p, 320) as im:      # JPEG: decoded at reduced size
                    im = ig_border._to_rgb(ImageOps.exif_transpose(im))
                    im.thumbnail(THUMB, Image.LANCZOS)
                    thumb = im.copy()
            except Exception:
                thumb = None
            self.msg_q.put(("thumb", p, mt, thumb))

    def on_thumb(self, p, mt, pil):
        self.thumb_pending.discard((p, mt))
        tile = self.tiles.get(p)
        if tile is None or pil is None:       # photo gone meanwhile (do not cache) or unreadable
            return
        canvas = Image.new("RGB", THUMB, THUMB_BG)            # fixed-size box: the badge always sits in the same spot
        canvas.paste(pil, ((THUMB[0] - pil.width) // 2, (THUMB[1] - pil.height) // 2))
        self.thumb_base[p] = (mt, canvas)
        self.refresh_thumb(p, force=True)

    # ---------------- preview ----------------
    def set_preview_file(self, path):
        try:
            with ig_border.open_image(path, PREVIEW_SRC_EDGE) as im:
                info = ig_border.read_exif(im)
                im = ig_border._to_rgb(ImageOps.exif_transpose(im))
                im.thumbnail((PREVIEW_SRC_EDGE, PREVIEW_SRC_EDGE), Image.LANCZOS)
                self.preview_src = im.copy()
                self.preview_small = im.copy()
                self.preview_small.thumbnail((640, 640), Image.BILINEAR)
                self.preview_info = info
            self.preview_path = Path(path)
            try:
                self.preview_mtime = Path(path).stat().st_mtime_ns
            except OSError:
                self.preview_mtime = None
            self.hq_canvas = None
            self.zoom, self.cxn, self.cyn = 1.0, 0.5, 0.5
            return True
        except Exception:
            return False

    def params_key(self):
        fo = self.footer_opts()
        return (self.ratio, round(self.thick_var.get()), STYLE_LABELS.get(self.style_var.get(), "white"),
                SIZE_LABELS.get(self.size_var.get(), 2048), tuple((k, str(v)) for k, v in sorted(fo.items())),
                str(self.preview_path), self.preview_mtime)

    # fast path: instant, from the reduced copy
    def schedule_preview(self, interactive=False):
        """interactive=True (slider drags, typing): throttled draft frames from a small copy, then one sharp
        render when the input pauses. Otherwise a short debounce."""
        self.sync_editor()
        if self.save_job:                      # settings follow changes after a pause, not only on close
            self.after_cancel(self.save_job)
        self.save_job = self.after(2000, self.save_cfg_later)
        if not interactive:
            if self.preview_job:
                self.after_cancel(self.preview_job)
            self.preview_job = self.after(60, self.render_preview)
            return
        if self.preview_job is None:
            wait = max(0, int(35 - (time.monotonic() - self.last_fast) * 1000))
            self.preview_job = self.after(wait, lambda: self.render_preview(interactive=True))
        if self.settle_job:
            self.after_cancel(self.settle_job)
        self.settle_job = self.after(180, self.settle_preview)

    def save_cfg_later(self):
        self.save_job = None
        self.save_cfg()

    def settle_preview(self):
        self.settle_job = None
        self.render_preview()

    def render_preview(self, interactive=False):
        self.preview_job = None
        src = self.preview_small if (interactive and self.preview_small is not None) else self.preview_src
        if src is None:
            return
        info = ig_border.SAMPLE_INFO if self.preview_info is None else self.preview_info
        footer = ig_border.make_footer(src, Namespace(**self.footer_opts()), info=info)
        self.fast_canvas = ig_border.build_canvas(src, self.ratio, round(self.thick_var.get()), 0, footer,
                                                  STYLE_LABELS.get(self.style_var.get(), "white"))
        self.last_fast = time.monotonic()
        self.hq_canvas = None            # parameters changed: the real render is stale
        if interactive:
            self.hq_lbl.configure(text="● 調整中…", text_color=MUTED)
            self.render_view(fast=True, labels=False)
        else:
            self.render_view()
            self.schedule_hq()

    # slow path: the real output, full resolution, in a background thread
    def schedule_hq(self):
        if self.hq_job:
            self.after_cancel(self.hq_job)
            self.hq_job = None
        if self.preview_path is None:
            self.hq_state(False)
            return
        self.hq_state(True)
        self.hq_job = self.after(300, self.start_hq)

    def start_hq(self):
        self.hq_job = None
        if self.hq_running:              # one worker at a time; re-run with the latest settings afterwards
            self.hq_pending = True
            return
        job = {"key": self.params_key(), "path": self.preview_path, "ratio": self.ratio,
               "thick": round(self.thick_var.get()), "max_edge": SIZE_LABELS.get(self.size_var.get(), 2048),
               "style": STYLE_LABELS.get(self.style_var.get(), "white"), "footer": self.footer_opts()}
        self.hq_running, self.hq_pending = True, False
        threading.Thread(target=self.hq_worker, args=(job,), daemon=True).start()

    def hq_worker(self, job):
        canvas = None
        try:
            with ig_border.open_image(job["path"], job["max_edge"]) as im:
                footer = ig_border.make_footer(im, Namespace(**job["footer"]))
                canvas = ig_border.build_canvas(im, job["ratio"], job["thick"], job["max_edge"], footer,
                                                job["style"])
                canvas.load()
        except Exception:
            canvas = None
        self.msg_q.put(("hq", job["key"], canvas))

    def on_hq_done(self, key, canvas):
        self.hq_running = False
        if canvas is not None and key == self.params_key():
            self.hq_canvas = canvas
            self.render_view()
        if self.hq_pending:
            self.start_hq()
        elif self.hq_job is None:
            self.hq_state(False)

    def hq_state(self, loading):
        if loading:
            self.hq_lbl.configure(text="● 產生中…", text_color=MUTED)
            self.hq_bar.grid()
            self.hq_bar.start()
        else:
            self.hq_bar.stop()
            self.hq_bar.grid_remove()
            ok = self.hq_canvas is not None
            self.hq_lbl.configure(text="● 高畫質" if ok else "", text_color=GREEN if ok else MUTED)

    # view: fit / zoom / pan on whichever canvas is best right now
    def schedule_view(self):
        if self.view_job:
            self.after_cancel(self.view_job)
        self.view_job = self.after(40, self.render_view)

    def view_changed(self):
        """Zoom / pan: draw a cheap frame now and the sharp one when the gesture pauses."""
        self.render_view(fast=True)
        if self.view_settle_job:
            self.after_cancel(self.view_settle_job)
        self.view_settle_job = self.after(150, self.settle_view)

    def settle_view(self):
        self.view_settle_job = None
        self.render_view()

    def render_view(self, fast=False, labels=True):
        self.view_job = None
        canvas = self.preview_src if (self.compare and self.preview_src is not None) \
            else (self.hq_canvas or self.fast_canvas)
        if canvas is None:
            return
        cw, ch = canvas.size
        box_w = max(200, self.preview_lbl.winfo_width() - 8)
        box_h = max(200, self.preview_lbl.winfo_height() - 8)
        s_fit = min(box_w / cw, box_h / ch)
        self.zoom = min(max(self.zoom, ZOOM_MIN), max(1.0, MAX_SCALE / s_fit))
        scale = s_fit * self.zoom
        vw, vh = min(cw, box_w / scale), min(ch, box_h / scale)     # visible area, in canvas pixels
        cx = min(max(self.cxn * cw, vw / 2), cw - vw / 2)
        cy = min(max(self.cyn * ch, vh / 2), ch - vh / 2)
        self.cxn, self.cyn = cx / cw, cy / ch
        crop = canvas.crop((round(cx - vw / 2), round(cy - vh / 2), round(cx + vw / 2), round(cy + vh / 2)))
        size = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
        if size != crop.size:
            if fast:
                crop = crop.resize(size, Image.BILINEAR, reducing_gap=2.0 if scale < 1 else None)
            elif scale < 1:
                crop = crop.resize(size, Image.LANCZOS, reducing_gap=3.0)   # pre-reduce, then the sharp filter
            else:
                crop = crop.resize(size, Image.BICUBIC)
        fitted = self.zoom <= 1.0001
        if fitted:
            crop = ImageOps.expand(crop, border=1, fill=(150, 150, 150))
        self.view = (scale, cw, ch, box_w, box_h)
        self.view_ext = (vw / cw, vh / ch)
        self.show_image(crop)
        if labels:
            lo, hi = math.log(ZOOM_MIN), math.log(max(1.0001, MAX_SCALE / s_fit))
            self.zoom_slider.set((math.log(self.zoom) - lo) / (hi - lo))
            self.zoom_pct.configure(text="%d%%" % round(scale * 100))
        self.update_scrollbars(cx, cy, vw, vh, cw, ch, not fitted and (vw < cw - 0.5 or vh < ch - 0.5))

    def preview_bg(self):
        pv = self.preview_frame
        try:
            return pv._apply_appearance_mode(pv.cget("fg_color"))      # follows light / dark mode
        except (tk.TclError, AttributeError):
            return PV_BG[1]

    def show_image(self, im):
        """Show a PIL image in the preview, reusing the PhotoImage when the size is unchanged (no allocations)."""
        bg = self.preview_bg()
        if bg != self.preview_bg_cache:
            self.preview_lbl.configure(bg=bg)
            self.preview_bg_cache = bg
        ph = self.preview_photo
        if ph is not None and ph.width() == im.width and ph.height() == im.height:
            ph.paste(im)
        else:
            self.preview_photo = ImageTk.PhotoImage(im)
            self.preview_lbl.configure(image=self.preview_photo)

    def update_scrollbars(self, cx, cy, vw, vh, cw, ch, show):
        """Overlay scrollbars (no layout change) that show which part of the image is visible."""
        try:
            self.preview_lbl.configure(cursor="openhand" if show else "")
        except (tk.TclError, ValueError):
            pass
        if not show:
            if self.sb_shown:
                self.vbar.place_forget()
                self.hbar.place_forget()
                self.sb_shown = False
            return
        lx, ly = self.preview_lbl.winfo_x(), self.preview_lbl.winfo_y()
        lw, lh = self.preview_lbl.winfo_width(), self.preview_lbl.winfo_height()
        self.vbar.configure(height=max(40, lh - 28))          # customtkinter: size via configure, not place()
        self.hbar.configure(width=max(40, lw - 28))
        self.vbar.place(x=lx + lw - 16, y=ly + 8)
        self.hbar.place(x=lx + 8, y=ly + lh - 16)
        self.vbar.set((cy - vh / 2) / ch, (cy + vh / 2) / ch)
        self.hbar.set((cx - vw / 2) / cw, (cx + vw / 2) / cw)
        self.vbar.lift()
        self.hbar.lift()
        self.sb_shown = True

    def on_hscroll(self, *args):
        self.scrollbar_move("x", args)

    def on_vscroll(self, *args):
        self.scrollbar_move("y", args)

    def scrollbar_move(self, axis, args):
        ext = self.view_ext[0 if axis == "x" else 1]
        try:
            if args[0] == "moveto":
                centre = float(args[1]) + ext / 2
            else:                                   # ("scroll", n, "units" | "pages")
                step = ext * (0.9 if args[2] == "pages" else 0.1)
                centre = (self.cxn if axis == "x" else self.cyn) + int(args[1]) * step
        except (IndexError, ValueError):
            return
        if axis == "x":
            self.cxn = centre
        else:
            self.cyn = centre
        self.view_changed()

    def reset_view(self):
        self.zoom, self.cxn, self.cyn = 1.0, 0.5, 0.5
        self.render_view()

    def pan_by(self, sx, sy):
        """Move the viewport by (sx, sy) screen pixels (positive = right / down). Only meaningful when zoomed in."""
        if self.view is None or self.zoom <= 1.0001:
            return
        scale, cw, ch, *_ = self.view
        self.cxn += sx / scale / cw
        self.cyn += sy / scale / ch
        self.view_changed()

    def zoom_to(self, scale, x=None, y=None):
        """Zoom so that 1 canvas pixel = `scale` screen pixels (clamped to fit..max); around (x, y) if given."""
        if self.view is None:
            return
        s_fit = self.view[0] / self.zoom
        self.zoom_about(x, y, scale / s_fit)

    def zoom_step(self, factor):
        self.zoom *= factor
        self.view_changed()

    def on_zoom_slider(self, t):
        if self.view is None:
            return
        lo, hi = math.log(ZOOM_MIN), math.log(max(1.0001, MAX_SCALE / (self.view[0] / self.zoom)))
        self.zoom = math.exp(lo + t * (hi - lo))
        self.view_changed()

    # Mac conventions: two-finger scroll pans, Command (or Control) + scroll zooms at the cursor,
    # double-click toggles fit <-> 100%, drag pans.  (Tk 9 has no pinch event.)
    ZOOM_MODS = 0x4 | 0x8                      # Control | Command

    def on_wheel(self, e):
        d = e.delta / 120 if abs(e.delta) >= 120 else e.delta     # macOS reports small steps, Windows 120s
        if e.state & self.ZOOM_MODS:
            self.zoom_at(e.x, e.y, d)
        elif e.state & 0x1:                    # Shift + wheel = horizontal
            self.pan_by(-d * 30, 0)
        else:
            self.pan_by(0, -d * 30)

    def on_touchpad(self, e):
        dx, dy = decode_touchpad(e.delta)
        if e.state & self.ZOOM_MODS:
            self.zoom_at(e.x, e.y, dy / 4)
        else:
            self.pan_by(-dx, -dy)              # content follows the fingers

    def zoom_at(self, x, y, d):
        """Zoom around the cursor position; d > 0 zooms in."""
        d = max(-5, min(5, d))
        if d:
            self.zoom_about(x, y, self.zoom * 1.12 ** d)

    def zoom_about(self, x, y, new_zoom):
        if self.view is None:
            return
        scale, cw, ch, box_w, box_h = self.view
        s_fit = scale / self.zoom
        new_zoom = min(max(new_zoom, ZOOM_MIN), max(1.0, MAX_SCALE / s_fit))
        if x is not None:
            ex = x - (self.preview_lbl.winfo_width() - box_w) / 2 - box_w / 2   # cursor offset from view centre
            ey = y - (self.preview_lbl.winfo_height() - box_h) / 2 - box_h / 2
            px, py = self.cxn * cw + ex / scale, self.cyn * ch + ey / scale        # canvas point under the cursor
            new_scale = s_fit * new_zoom
            self.cxn, self.cyn = (px - ex / new_scale) / cw, (py - ey / new_scale) / ch
        self.zoom = new_zoom
        self.view_changed()

    def on_double(self, e):
        if self.view is None:
            return
        if self.zoom > 1.0001:
            self.reset_view()
        else:
            s_fit = self.view[0]
            self.zoom_to(max(1.0, s_fit * 2), e.x, e.y)

    def on_press(self, e):
        self.drag = (e.x, e.y)
        if self.zoom > 1.0001:
            try:
                self.preview_lbl.configure(cursor="closedhand")
            except (tk.TclError, ValueError):
                pass

    def on_release(self, e):
        self.drag = None
        try:
            self.preview_lbl.configure(cursor="openhand" if self.zoom > 1.0001 else "")
        except (tk.TclError, ValueError):
            pass

    def on_drag(self, e):
        if self.drag is None or self.view is None or self.zoom <= 1.0001:
            return
        sx, sy = e.x - self.drag[0], e.y - self.drag[1]
        self.drag = (e.x, e.y)
        self.pan_by(-sx, -sy)

    # ---------------- before / after ----------------
    def set_compare(self, on):
        if self.compare == on:
            return
        self.compare = on
        if on:
            self.hq_lbl.configure(text="● 原圖", text_color=AMBER)
        else:
            self.hq_state(self.hq_job is not None or self.hq_running)
        self.render_view()

    # ---------------- presets ----------------
    def preset_names(self):
        return list(BUILTIN_PRESETS) + sorted(self.presets)

    def collect_settings(self):
        fo = self.footer_opts()
        return {"ratio": self.ratio, "thickness": round(self.thick_var.get()),
                "style": STYLE_LABELS.get(self.style_var.get(), "white"), "size": self.size_var.get(),
                "footer": fo["footer"], "layout": fo["footer_layout"], "fields": fo["footer_fields"],
                "divider": fo["footer_divider"], "center_divider": fo["footer_center_divider"],
                "text_scale": round(self.text_scale.get()),
                "logo_scale": round(self.logo_scale.get()), "height_scale": round(self.height_scale.get()),
                "bold": fo["footer_bold"], "color_choice": self.color_var.get(), "custom_color": self.custom_color,
                "date_format": fo["footer_date_format"], "logo_pos": fo["footer_logo_pos"],
                "custom_text": fo["footer_custom_text"], "main": fo["footer_main"], "mirror": fo["footer_mirror"],
                "exposure_items": fo["footer_exposure_items"], "exposure_order": fo["footer_exposure_order"],
                "font": fo["footer_font"], "style_slots": copy.deepcopy(self.style_slots)}

    def apply_settings(self, d):
        """Apply a preset dict. Unknown / invalid values are ignored, so a hand-edited file cannot break the UI."""
        if not isinstance(d, dict):
            return
        ratios = [r for _, r in RATIOS]
        if self.choice(d.get("ratio"), ratios, None):
            self.ratio = d["ratio"]
            self.refresh_ratio_buttons()
        if "thickness" in d:
            self.thick_var.set(self.num(d["thickness"], 0, 50, 10))
        if self.choice(d.get("style"), STYLE_LABELS.values(), None):
            self.style_var.set(self.label_of(STYLE_LABELS, d["style"], "白底"))
        if self.choice(d.get("size"), SIZE_LABELS, None):
            self.size_var.set(d["size"])
        if "footer" in d:
            self.footer_on.set(d["footer"] is True)
        if self.choice(d.get("layout"), LAYOUT_LABELS.values(), None):
            self.layout_var.set(self.label_of(LAYOUT_LABELS, d["layout"], "經典三欄"))
        if isinstance(d.get("fields"), list):
            for k, v in self.field_vars.items():
                v.set(k in d["fields"])
        if "divider" in d:
            self.divider_var.set(d["divider"] is True)
        if "center_divider" in d:
            self.cdivider_var.set(d["center_divider"] is not False)
        for key, var, lo, hi in (("text_scale", self.text_scale, 50, 200), ("logo_scale", self.logo_scale, 40, 250),
                                 ("height_scale", self.height_scale, 60, 250)):
            if key in d:
                var.set(self.num(d[key], lo, hi, 100))
        if "bold" in d:
            self.bold_var.set(d["bold"] is not False)
        if self.choice(d.get("color_choice"), COLOR_LABELS, None):
            self.color_var.set(d["color_choice"])
        if isinstance(d.get("custom_color"), str) and re.fullmatch(r"#[0-9a-fA-F]{6}", d["custom_color"]):
            self.custom_color = d["custom_color"]
        if self.choice(d.get("date_format"), DATE_LABELS.values(), None):
            self.datefmt_var.set(self.label_of(DATE_LABELS, d["date_format"], "2026.05.25"))
        if self.choice(d.get("logo_pos"), LOGO_POS_LABELS.values(), None):
            self.logopos_var.set(self.label_of(LOGO_POS_LABELS, d["logo_pos"], "機型左側"))
        if "custom_text" in d:
            self.custom_text_var.set(self.clean_text(d["custom_text"]))
        if self.choice(d.get("main"), ("model", "lens"), None):
            self.main_var.set(d["main"] == "lens")
        if "mirror" in d:
            self.mirror_var.set(d["mirror"] is True)
        if isinstance(d.get("exposure_items"), list):
            for k, v in self.exp_vars.items():
                v.set(k in d["exposure_items"])
        if self.choice(d.get("exposure_order"), EXPO_ORDER_LABELS.values(), None):
            self.exporder_var.set(self.label_of(EXPO_ORDER_LABELS, d["exposure_order"], next(iter(EXPO_ORDER_LABELS))))
        if isinstance(d.get("font"), str) and d["font"] in self.font_labels.values():
            self.font_var.set(self.label_of(self.font_labels, d["font"], DEFAULT_FONT_LABEL))
        if "style_slots" in d:
            self.style_slots = ig_border.sanitize_style(d["style_slots"])
            if self.style_editor is not None and self.style_editor.winfo_exists():
                self.style_editor.load(self.style_slots)
        self.on_thick()
        self.update_footer_controls()
        self.schedule_preview()

    def apply_preset(self, name):
        data = self.presets.get(name)
        if name in BUILTIN_PRESETS:
            data = {**PRESET_BASE, **BUILTIN_PRESETS[name]}
        if data is not None:
            self.apply_settings(data)
            self.set_status("已套用預設：%s" % name, GREEN)

    def save_preset(self):
        dlg = ctk.CTkInputDialog(text="預設名稱（最多 30 字）：", title="儲存預設")
        name = self.clean_text(dlg.get_input() or "", 30)
        if not name:
            return
        if name in BUILTIN_PRESETS:
            messagebox.showinfo("名稱重複", "這是內建預設的名稱，請換一個。")
            return
        if name not in self.presets and len(self.presets) >= MAX_PRESETS:
            messagebox.showinfo("預設太多", "最多只能儲存 %d 個自訂預設，請先刪除一些。" % MAX_PRESETS)
            return
        if name in self.presets and not messagebox.askyesno("覆蓋確認", "已有名為「%s」的預設，要覆蓋嗎？" % name):
            return
        self.presets[name] = self.collect_settings()
        self.preset_menu.configure(values=self.preset_names())
        self.preset_var.set(name)
        self.save_cfg()
        self.set_status("已儲存預設：%s" % name, GREEN)

    def delete_preset(self):
        name = self.preset_var.get()
        if name in BUILTIN_PRESETS:
            messagebox.showinfo("無法刪除", "內建預設不能刪除。")
            return
        if name not in self.presets:
            return
        if messagebox.askyesno("刪除預設", "要刪除預設「%s」嗎？" % name):
            del self.presets[name]
            self.preset_menu.configure(values=self.preset_names())
            self.preset_var.set(PRESET_PLACEHOLDER)
            self.save_cfg()

    # ---------------- window geometry ----------------
    def restore_geometry(self, cfg):
        m = re.fullmatch(r"(\d+)x(\d+)([+-]\d+)([+-]\d+)", str(cfg.get("geometry", "")))
        if not m:
            return
        w, h, x, y = int(m[1]), int(m[2]), int(m[3]), int(m[4])
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        w, h = min(max(w, 1000), sw), min(max(h, 700), sh)
        x, y = min(max(x, 0), max(0, sw - 200)), min(max(y, 0), max(0, sh - 120))      # keep it reachable
        self.geometry("%dx%d+%d+%d" % (w, h, x, y))

    # ---------------- keyboard ----------------
    def typing(self):
        try:
            return isinstance(self.focus_get(), (tk.Entry, tk.Text))
        except (KeyError, tk.TclError):
            return False

    def event_in_main(self, e):
        """Global key bindings belong to the main window: a key pressed in the style editor / source manager
        (Return = process, Esc = stop, arrows = switch photo ...) must not trigger them."""
        try:
            w = e.widget if not isinstance(e.widget, str) else self.nametowidget(e.widget)
            return w.winfo_toplevel() is self
        except (KeyError, tk.TclError, AttributeError):
            return False

    def bind_keys(self):
        def guard(fn):
            return lambda e: None if (not self.event_in_main(e) or self.typing()) else (fn(), "break")[1]

        def main_only(fn):
            return lambda e: fn() if self.event_in_main(e) else None
        self.bind_all("<Left>", guard(lambda: self.arrow(-1, 0)))
        self.bind_all("<Right>", guard(lambda: self.arrow(1, 0)))
        self.bind_all("<Up>", guard(lambda: self.arrow(0, -1)))
        self.bind_all("<Down>", guard(lambda: self.arrow(0, 1)))
        self.bind_all("<Option-Left>", guard(lambda: self.nav(-1)))
        self.bind_all("<Option-Right>", guard(lambda: self.nav(1)))
        self.bind_all("<bracketleft>", guard(lambda: self.nav(-1)))
        self.bind_all("<bracketright>", guard(lambda: self.nav(1)))
        self.bind_all("<Command-1>", main_only(lambda: self.zoom_to(1.0)))
        self.bind_all("<space>", guard(self.toggle_check))
        self.bind_all("<Return>", guard(self.start_by_key))
        self.bind_all("<Escape>", main_only(self.batch_stop.set))
        self.bind_all("<Command-o>", lambda e: self.pick_folder())
        for seq in ("<Command-equal>", "<Command-plus>"):
            self.bind_all(seq, main_only(lambda: self.zoom_step(1.25)))
        self.bind_all("<Command-minus>", main_only(lambda: self.zoom_step(1 / 1.25)))
        self.bind_all("<Command-0>", main_only(self.reset_view))
        self.bind_all("<KeyPress-backslash>", lambda e: None if (not self.event_in_main(e) or self.typing())
                      else self.set_compare(True))
        self.bind_all("<KeyRelease-backslash>", lambda e: self.set_compare(False))

    def arrow(self, dx, dy):
        """Zoomed in: pan like a Mac image viewer. At fit: left / right switch photos."""
        if self.zoom > 1.0001 and self.view is not None:
            self.pan_by(dx * self.view[3] * 0.15, dy * self.view[4] * 0.15)
        elif dx:
            self.nav(dx)

    def start_by_key(self):
        """Return starts a batch, but never stops a running one (Escape / the button do that)."""
        if not (self.batch and self.batch.is_alive()):
            self.process_selected()

    def nav(self, step):
        if not self.photos:
            return
        i = self.photos.index(self.selected) if self.selected in self.photos else (-1 if step > 0 else 0)
        j = i + step
        while 0 <= j < len(self.photos):
            p = self.photos[j]
            if self.select_photo(p):
                self.after(10, lambda q=p: self.ensure_visible(q))
                return
            self.set_status("無法讀取 %s，已略過" % p.name, AMBER)    # unreadable file: keep going in the same direction
            j += step

    def ensure_visible(self, p):
        t = self.tiles.get(p)
        if t is None:
            return
        cv = self.strip._parent_canvas
        try:
            total = max(1, int(cv.cget("scrollregion").split()[2]))
            x0, x1 = t["tile"].winfo_x(), t["tile"].winfo_x() + t["tile"].winfo_width()
            lo, hi = cv.xview()
            if x0 < lo * total:
                cv.xview_moveto(max(0, (x0 - 8) / total))
            elif x1 > hi * total:
                cv.xview_moveto(min(1, (x1 + 8) / total - (hi - lo)))
        except (tk.TclError, TypeError, ValueError, AttributeError):
            pass

    def toggle_check(self):
        if self.selected in self.checked:
            self.checked[self.selected].set(not self.checked[self.selected].get())
            self.update_count()

    # ---------------- status / messages ----------------
    def set_status(self, text, color):
        self.status.configure(text=text)
        self.dot.configure(text_color=color)

    def drain_msgs(self):
        try:
            for _ in range(200):                     # bounded work per tick keeps the UI responsive
                try:
                    kind, *rest = self.msg_q.get_nowait()
                except queue.Empty:
                    break
                try:
                    self.handle_msg(kind, *rest)
                except Exception:                    # one bad message must not stop the whole loop
                    pass
        finally:
            self.after(150, self.drain_msgs)

    def handle_msg(self, kind, *rest):
        if kind == "state":
            self.set_state(*rest)
        elif kind == "progress":
            done, total = rest
            self.progress.set(done / max(1, total))
            self.set_status("處理中 %d / %d" % (done, total), ACCENT)
        elif kind == "batch_done":
            self.on_batch_done(*rest)
        elif kind == "thumb":
            self.on_thumb(*rest)
        elif kind == "status":
            self.set_status(rest[0], RED)
        elif kind == "hq":
            self.on_hq_done(*rest)
        elif kind == "src_counts":
            self.on_src_counts(*rest)

    # ---------------- processing ----------------
    def build_job(self):
        """Validate the form; return (out, opts) or None after showing why. Photos come from the shown source(s)."""
        try:
            out = Path(self.out_var.get().strip()).expanduser().resolve()
            opts = Namespace(ratio=self.ratio, thickness=round(float(self.thick_var.get()), 1),
                             max_edge=SIZE_LABELS[self.size_var.get()], quality=95,
                             overwrite=bool(self.overwrite_var.get()),
                             style=STYLE_LABELS[self.style_var.get()], **self.footer_opts())
        except (ValueError, KeyError, tk.TclError, OSError):
            messagebox.showerror("錯誤", "請檢查資料夾與設定")
            return None
        if not self.out_var.get().strip():
            messagebox.showerror("錯誤", "請先選擇輸出資料夾")
            return None
        if not self.sources and not self.imported:
            messagebox.showerror("錯誤", "請先加入資料夾，或匯入照片")
            return None
        if self.active_missing():
            messagebox.showerror("錯誤", "找不到這個來源資料夾（外接硬碟沒有連上？）")
            return None
        for x in self.sources:                    # every source, not only the shown one: it would break later
            try:
                d = Path(x["path"])
                if d.is_dir() and ig_border.folders_conflict(d, out):
                    messagebox.showerror("錯誤", "輸出資料夾不可與來源資料夾「%s」相同或互相包含" % (d.name or "/"))
                    return None
            except OSError:
                continue
        err = ig_border.validate(opts.ratio, opts.thickness, opts.max_edge, opts.quality,
                                 opts.footer_layout, opts.footer_fields, opts.style)
        if err:
            messagebox.showerror("錯誤", err)
            return None
        if not out.exists() and not out.parent.is_dir():
            messagebox.showerror("錯誤", "找不到輸出資料夾的位置（外接硬碟沒有連上？）。為了避免在錯的地方建立資料夾，已取消。")
            return None
        try:
            out.mkdir(exist_ok=True)              # only the last level is created
        except OSError:
            messagebox.showerror("錯誤", "無法建立輸出資料夾")
            return None
        ig_border.cleanup_temp(out)               # leftovers of an earlier interrupted run
        self.push_recent("recent_out", self.out_var.get())
        return out, opts

    def process_one(self, p, out, opts, name=None):
        """Process a single photo and report its state. Returns 'done' / 'skip' / 'fail'."""
        self.msg_q.put(("state", p, "處理中"))
        try:
            if not ig_border.wait_until_stable(p, tries=40, interval=0.25, stop=self.batch_stop):
                raise OSError("unstable")
            dst = ig_border.process(p, out, opts, name)
        except Exception as e:
            if self.batch_fail_reason is None:           # type name only: no paths or details leak
                self.batch_fail_reason = "原因：%s" % type(e).__name__
            self.msg_q.put(("state", p, "失敗"))
            return "fail"
        self.msg_q.put(("state", p, "完成" if dst else "略過"))
        return "done" if dst else "skip"

    # batch: the ticked photos that are in the strip
    def process_selected(self):
        if self.batch and self.batch.is_alive():
            self.batch_stop.set()
            return
        job = self.build_job()
        if job is None:
            return
        out, opts = job
        paths = [p for p in self.photos if self.checked[p].get()]
        if not paths:
            messagebox.showinfo("沒有照片", "沒有勾選任何照片。")
            return
        if opts.overwrite:
            k = sum((out / self.out_name(p)).exists() for p in paths)
            if k and not messagebox.askyesno("覆蓋確認", "有 %d 張的輸出檔已存在，會被覆蓋。要繼續嗎？" % k):
                return
        self.save_cfg()
        for p in paths:
            self.states.pop(p, None)
            self.set_state(p, "待處理")
        self.batch_stop.clear()
        names = {p: self.out_name(p) for p in paths}
        self.batch = threading.Thread(target=self.batch_worker, args=(paths, out, opts, names), daemon=True)
        self.batch.start()
        self.run_btn.configure(text="停止處理", fg_color=RED, hover_color=RED_HOVER)
        self.progress.set(0)
        self.progress.grid()
        self.set_status("處理中 0 / %d" % len(paths), ACCENT)

    def batch_worker(self, paths, out, opts, names):
        count = {"done": 0, "skip": 0, "fail": 0}
        self.batch_fail_reason = None
        for i, p in enumerate(paths):
            if self.batch_stop.is_set():
                break
            count[self.process_one(p, out, opts, names.get(p))] += 1
            self.msg_q.put(("progress", i + 1, len(paths)))
        self.msg_q.put(("batch_done", count["done"], count["skip"], count["fail"], self.batch_stop.is_set()))

    def on_batch_done(self, done, skip, fail, stopped):
        self.scan_sources()
        self.run_btn.configure(text="處理勾選的照片", fg_color=ACCENT, hover_color=ACCENT_HOVER)
        self.progress.grid_remove()
        text = "%s：完成 %d 張" % ("已停止" if stopped else "處理結束", done)
        if skip:
            text += "・略過 %d 張（輸出已存在）" % skip
        if fail:
            text += "・失敗 %d 張" % fail
            if self.batch_fail_reason:
                text += "（%s）" % self.batch_fail_reason
        self.set_status(text, RED if fail else (AMBER if skip else GREEN))

    def on_close(self):
        if self.batch and self.batch.is_alive():
            if not messagebox.askyesno("還在處理", "還有照片正在處理，確定要關閉嗎？"):
                return
        self.batch_stop.set()
        self.thumb_q.put(None)
        if self.batch is not None and self.batch.is_alive():
            self.batch.join(timeout=3)                    # let the current photo finish writing
        out = self.out_dir()
        if out is not None and out.is_dir():
            ig_border.cleanup_temp(out, older_than=30)
        self.save_cfg()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
