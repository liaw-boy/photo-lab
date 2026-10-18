# Changelog

Version number lives in `VERSION` (single source; shown in the window title and the header).
Scheme: `MAJOR.MINOR.PATCH` — while MAJOR is 0, MINOR = new feature / UI change, PATCH = bug fix.

## 1.2.0 — 2026-10-18
- Outputs know their source: each one carries a source ID in its JPEG comment, an HMAC (with a key made on this
  Mac and kept in the settings, so nothing can be read back from a shared picture) of what stays the same when a
  folder is renamed or moved, a disk mounts under another name, or the photo is edited and exported again: the
  file name, the capture time, the camera model and serial number (the serial only goes into the HMAC; the path,
  for pictures without a capture time). A photo's earlier output is found among `IMG_1234_ig.jpg`, `-2`, `-3` ...
  whatever is selected, and an output from 1.2 on that belongs to another photo with the same name, or a file of
  another tool, is never overwritten or taken for it: the new output gets the next free number. Outputs made
  before 1.2 have no ID and are matched by their plain name, as before (the prompt says how many). Not told apart:
  versions of one original with the same file name and the same capture data in two folders (say a colour and a
  black-and-white virtual copy exported under one name): give versions different file names.
- The key lives in its own file (`source.key` next to the settings, mode 0600), made once and never replaced, also
  when it cannot be read (the app then says so when it starts and uses a key for that run only). Another Mac or a
  lost key does not recognise earlier outputs: new ones get numbers, nothing is overwritten.
- What each photo gets (write, overwrite, copy, skip) is decided in one place; the prompt and the export use it.
  Right before an overwrite the file is checked again; if it is no longer the photo's own, a numbered copy is
  written instead.
- Privacy: the source ID reveals nothing about the photo, but pictures shared from one Mac that came from the same
  original carry the same ID, so someone holding several of them can tell they share an original.
- Hardening: output files are read only when they are regular files (no symlinks; a FIFO cannot stall the scan);
  the key file is written in one step and used only when it is a regular file of this user, not readable by others.
- An own output cut off while it was written (exFAT) is always written again, also with 略過.
- 既有檔案 (in 來源與輸出, remembered), for a photo whose own earlier output is in the output folder, as in
  Lightroom: 每次詢問 (default), 自動改名 (a new copy at the next free `-2`, `-3` ...), 覆蓋, 略過. With 每次詢問
  the prompt offers the same three.
- Photos of one export that share a name (the same file name in two folders, or differing only in case) no
  longer skip or overwrite each other; the status line says how many got a number.
- 來源管理 shows, per source, how many photos already have their own output in the current output folder
  (`N 張 · 已輸出 M`).
- Choosing another output folder clears the 完成 / 略過 / 失敗 marks of the last export; the folder cannot be
  changed while an export runs.
- 自動改名 writes the picture once and only retries the no-overwrite move for the next number. On exFAT the temp
  file is removed before the direct write (never two copies on the disk), and once a disk has turned exclusive
  rename down, later photos go straight to the direct write.
- The output folder is scanned in the background (the window no longer waits for a slow disk); the 已輸出 counts
  are worked out when 來源管理 opens.

## 1.1.1 — 2026-10-18
- Export without overwrite on exFAT and other volumes without exclusive rename (also those that report it as
  EINVAL / ENOSYS): the output file is now created with O_EXCL and written in place, so a file that exists or
  appears at the same moment (another export, another app) is never replaced. Not covered: network / FUSE file
  systems that only emulate O_EXCL. On these volumes a half-written file can be seen while it is written; a crash
  can leave a cut-off file. APFS and other volumes with exclusive rename keep the atomic temp-file-and-rename save.
- The overwrite prompt counts an output without the JPEG end marker (cut off while written) as different from the
  current settings instead of up to date. Choosing to skip existing files still skips it; choose overwrite to
  replace it.
- The 有新版本 button goes back to 檢查更新 after 跳過此版本 (before installing has begun); it stays after 暫緩提醒,
  a skip while installing, or a failed check, download or install, since the newer version is still on offer. The
  next daily check settles it.
- `release.sh --publish`: the GitHub release creates its tag in the same step (no stray tag when an upload fails;
  tags are now lightweight). It stops before building when origin is not this repository, when the tag or a release
  (also a leftover draft) already exists on GitHub, or when either lookup fails.
- CI (`.github/workflows/ci.yml`): build and test on pushes to main and on pull requests.

## 1.1.0 — 2026-10-18
- Updates from GitHub: the app checks once a day for a newer release, shows its notes and installs it with one
  click, then restarts. A 檢查更新 button beside the title (also Photo_Lab → 檢查更新…) checks by hand and turns
  into 有新版本 x.y.z when one is found. The update dialog and the standard menus are in Traditional Chinese. Nothing is installed without asking. Built on Sparkle 2.10.0;
  every update must carry an EdDSA signature made with the publisher's key, so a changed download is refused.
- The check contacts GitHub (github.com and its download servers), which sees your IP address and app version.
- Hardened runtime; libraries are only loaded from the system or the app bundle (no build-machine paths).
- `release.sh` makes the signed update feed (`appcast.xml`) and, with `--publish`, the GitHub release.
- From 1.0.3 or older, install 1.1.0 once by hand; later versions then arrive through the app.

## 1.0.3 — 2026-10-18
- Export failures: the status line groups the reasons with counts (e.g. "失敗 29 張（無法寫入輸出資料夾 29）"),
  in Chinese; unexpected errors show only "未知錯誤" instead of raw error text.

## 1.0.2 — 2026-10-17
- Fix: exporting to an exFAT disk (many external drives) failed for every photo, because the "do not overwrite"
  save used an exclusive rename that exFAT does not support. It now falls back to checking first, then renaming.
- The status line now shows why photos failed to export, instead of only the count.

## 1.0.1 — 2026-10-11
- Swift app: Help menu "自備品牌 logo 與字體…" shows where to put your own brand logos / fonts and the file-name rules,
  and opens (creating it when missing) the folder. README has the same walk-through.
- `package.sh` builds a clean package by default (no brand logos / fonts); `--with-logos` makes a personal build.

## 1.0.0 — 2026-10-11
First stable release, and the first one with the native macOS app (`swift/PhotoLab`, Swift / SwiftUI, no Python
needed). The Python app (`python/`) stays as the cross-platform edition and as the reference renderer.
- **Native Swift app**: the same borders, footers and presets as the Python app, an own JPEG encoder (4:4:4, ICC
  profile kept), thumbnail cache, pinch / double-tap zoom, resizable thumbnail strip. `swift/PhotoLab/package.sh`
  builds `dist/PhotoLab.app` and a zip (ad-hoc signed): clean by default, `--with-logos` packs your own `logos/` and
  `fonts/` (never in git) into a personal build that should not be passed on. A packaged app reads
  `~/Library/Application Support/Photo_Lab/{logos,fonts}` and does not look at `PHOTOLAB_ROOT` or parent folders.
- Both renderers match (`tools/compare_swift.py`: mean difference 0.06-1.6 of 255 over the border and ten footer cases).
- **Footer: logo beside the model name** (経典 layout, logo on the left): `[logo] EOS 90D` on the first line, the
  lens below. Logo and text in one row are aligned on their bottom edges instead of their centres.
- **Style editor (Swift)**: drag the elements (品牌 logo / 機型 / 鏡頭 / 焦距 / 拍攝參數 / 日期 / 自訂文字) into the
  three blocks; drag a placed element to move it (an insertion bar shows where it lands, also after the last one),
  drag it back to the tray to remove it; drag a block by its title to swap two blocks; the block being edited is
  drawn wider. The editing rules are unit tested (`swift test`).
- 焦距 is its own element, 曝光參數 is now called 拍攝參數 (aperture, shutter, ISO only); older custom styles get a
  焦距 element in front of each 拍攝參數 once, so they look the same as before.
- A logo element inside a block replaces the old "logo left of the whole block" flag (no double logo).
- Main window: 機型 / 鏡頭 / 焦距 / 參數 / 日期 checks, one-click looks with the active one shown solid black,
  macOS-style segmented control with a sliding thumb; the options that the style editor covers (版面 menu, 粗體,
  logo 位置, 鏡頭放上面, 左右對調, 加分隔線) were removed from the main window.
- 鏡頭主角 look is now "logo 機型": logo + model on top, shooting values and date below with a thin divider.
- 拍攝參數 order: eight arrangements instead of two.

## 0.6.1 — 2026-10-11
- Ratio tiles are drawn as vectors like the other icons (sharp on Retina).
- Removed the 按住對照原圖 button and the `\` hold-to-compare shortcut.

## 0.6.0 — 2026-10-11
- **Style editor in the Stitch layout**: the three blocks side by side, every line shows its own 粗體 / 大小 /
  字色 / 加線 and its items as chips with ✕ ("＋ 加入" for more; click a chip to get ◀ ▶ re-order arrows); the
  preview strip is shorter so everything fits. Chips carry small item icons.
- **Icons**: the open-source Lucide set (ISC, SVGs in `assets/icons_src/`) on buttons, card titles, the 選擇 / 進階
  arrows and the editor chips. Drawn as vectors on a canvas (`python/icon_paths.py`, generated by
  `tools/make_icons.py`) so they are sharp on Retina - a Tk image is only 1 px = 1 pt and always gets up-scaled.
  Menu entries still use 16 px rasters (`assets/icons/*.png`), because a menu cannot hold a canvas.
- Style editor: drag a chip to move it - a copy follows the pointer, its slot stays as an empty outline and the other
  chips make room as you pass them; a plain click still selects it and shows the ◀ ▶ arrows.
- Style editor: click a block to widen it (full settings) while the other two fold into read-only summaries (the same outlined line boxes with small item chips); the centre block is open at start and the widths ease over.
- Style editor: removed the 「logo 放在整塊文字左邊」 and 「logo 後加分隔線」 checkboxes (built-in looks keep their
  logo placement and divider).
- Style editor: chips are placed at their own widths (a wide selected chip no longer pushes its neighbour away).
- Style editor: the three block cards have a fixed height (they fill the window); a block with more content than
  fits scrolls with the wheel / trackpad; the scroll bar only shows while there is something to scroll.
- Removed the 輸出長邊 (px) card: exports always keep the original resolution (it was 原尺寸 by choice; the default
  of a fresh install used to be 2048). A saved `size` in settings or presets is ignored.
- Style editor: faster - unchanged lines keep their chips when something else changes, selecting a chip no longer
  rebuilds every block, and switching the open block is a short 3-step width change (about 0.15 s instead of ~0.8 s).
- 進階: its widgets are drawn once off-screen shortly after launch, so the first unfold takes ~0.18 s instead of ~0.32 s.
- Style editor: an empty line now has the same gap above and below its item box.
- Removed the 覆蓋已存在的輸出檔 checkbox (the 輸出已存在 dialog covers it); an old `overwrite` setting is ignored.
- Style editor: the 靠左 / 置中 / 靠右 menu of a block is gone (it only aligned the two lines of a block against each
  each other, and a wrong choice just looked misaligned). Blocks keep the alignment of their style: left block left,
  centre block centred, right block right; stored values are still read and written.
- Style editor: every line is laid out on equal columns (three items, 字級 | 顏色, 粗體 | 項目之間加線), and the
  block cards fill their column.
- 進階 starts folded at every launch (its open/closed state is no longer remembered).
- Icons unified: every drop-down uses the same slim rounded chevron as the 進階 toggle and the 選擇 buttons
  (same proportions, same stroke) instead of the stock thick arrow.

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
