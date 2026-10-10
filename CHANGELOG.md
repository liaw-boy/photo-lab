# Changelog

Version number lives in `VERSION` (single source; shown in the window title and the header).
Scheme: `MAJOR.MINOR.PATCH` — while MAJOR is 0, MINOR = new feature / UI change, PATCH = bug fix.

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
