# Changelog

Version number lives in `VERSION` (single source; shown in the window title and the header).
Scheme: `MAJOR.MINOR.PATCH` — while MAJOR is 0, MINOR = new feature / UI change, PATCH = bug fix.

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
