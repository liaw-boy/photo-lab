# Changelog

Version number lives in `VERSION` (single source; shown in the window title and the header).
Scheme: `MAJOR.MINOR.PATCH` — while MAJOR is 0, MINOR = new feature / UI change, PATCH = bug fix.

## 0.5.1 — 2026-10-10
- Exporting when outputs already exist now asks first: "輸出檔已存在" with 覆蓋 / 取消 / 只匯出新的 (and how many
  of them were made with different settings). The choice applies to that run only. Every export now carries a
  small settings fingerprint in the JPEG comment, which is what lets the dialog tell the two cases apart.
- 儲存預設 dialog is the app's own paper-style prompt (outlined entry, 取消 / 儲存) instead of the stock blue
  English Ok / Cancel one.

## 0.5.0 — 2026-10-10
- **UI is now only the 紙稿 (paper) look**, after the Paper Wireframe Kit: white cards with 2 px black outlines,
  outlined buttons, solid black main button, grey selected segments, no shadows, system font, always light.
  The 暗房 / 炭灰 themes, the theme switch (and its restart path) and the preview glow are removed; an old
  settings file with `"theme": ...` is simply ignored.
- 圓角 has an adjustable radius ("弧度" slider, 1-60 per mille of the long edge, default 12); the slider is only
  shown while 圓角 is on. Saved in the settings and in presets.
- Resizing / zooming the window no longer leaves the left panel unscrollable: once the size settles the window is
  nudged 1 px and back (the manual workaround of moving it), skipped while zoomed / full screen. (macOS Tk keeps
  routing the wheel to a stale widget map after a resize; not reproducible without a real trackpad.)
- UI consistency pass: one corner radius (8; 10 for the ratio tiles and the export button) and two control heights
  (28 compact / 34 regular) across the main window, the style editor and the source manager; the 進階 toggle uses
  a drawn chevron like the 選擇 buttons; the advanced rows line up with the rows above.
- Card corners: the advanced section no longer clips the rounded outline.
- Thumbnail strip: the empty band between the tiles and the horizontal scrollbar is gone.
- Source cache / settings: the paper card outlines are no longer covered by the advanced section.

## 0.4.0 — 2026-10-10
- The thumbnail strip is resizable: drag the small bar between the preview and the strip; the thumbnails scale
  with it (56–180 px high, remembered). Thumbnails are now decoded / cached at 240x180 so enlarging stays sharp
  (the cache is rebuilt once).

## 0.3.1 — 2026-10-10
- 選擇 buttons: the little ▾ is replaced by a drawn macOS-style up/down chevron icon (crisp on Retina).
- Persistent thumbnail cache (`~/Library/Caches/Photo_Lab/thumbs`, private 0700, JPEG ~7 KB each, keyed by
  path + mtime + size + thumbnail size, pruned above 8000 files): a folder of 119 photos on an external disk
  opens in 0.24 s instead of ~9 s the second time. Safe to delete at any time.

## 0.3.0 — 2026-10-10
- Rounded corners are an independent switch: background 白底 / 模糊 and 圓角 on/off combine freely (new
  blurred-background + square-corners style `blur_square`). Old settings and presets are converted.
- Preview: the 1 px grey outline is only drawn for white backgrounds (it looked like a white ring around the
  blurred background; it was never part of the exported file).
- Wording unified: export (匯出) instead of 處理 in the status line, dialogs and the status pill.
- Preview: soft ambient glow behind the photo, tinted with the photo's own average colour (dark themes, when
  the image does not fill the preview area).
- 重設 now ticks every photo again, clears the 完成 / 失敗 / 略過 marks and re-reads the folder
  (it used to only re-read the folder).

## 0.2.0 — 2026-10-10
- Python app moved to `python/`; `logos/`, `fonts/`, `styles/`, `assets/` shared at the repo root.
- Batch export faster (no fixed per-photo wait), stop works while waiting, failure reason shown.
- Large photos are shrunk before orientation / colour conversion (lower peak memory).
- Settings are saved a moment after any change, not only on close.
- Camera-info UI: one-click footer looks, controls greyed out per layout, advanced section folded,
  divider toggle for the centred layouts.
- Style editor: start-from templates, collapsible empty lines, clearer wording.
- Themes: darkroom (default) and carbon.
- App icon (`assets/icon_1024.png`, `assets/PhotoLab.icns`) in the window / Dock and beside the title.
- Source manager: add folder / import photos buttons.
- Thumbnails larger (150×112); status pills drawn as canvas items (crisp text); the
  "already exported" pill is no longer shown; main button "處理 N 張" next to the thumbnails.

## 0.1.0 — initial
- Border (ratio + thickness, white / rounded / blur), camera-info footer with brand logos,
  live preview, photo strip, presets, style editor, source list.
