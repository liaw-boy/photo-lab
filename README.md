# Photo_Lab

替照片加上白邊／模糊背景邊框，並在底部加上相機資訊列（機型、鏡頭、焦距、光圈、快門、ISO、日期與品牌 logo），
輸出適合 Instagram 的 JPEG。照片處理全部在本機完成，不連網、不上傳任何東西。

有兩個版本，功能與輸出一致：

| 版本 | 位置 | 說明 |
|---|---|---|
| **macOS 原生版**（主要） | `swift/PhotoLab` | Swift / SwiftUI，雙擊即可使用，不需要 Python |
| Python 版 | `python/` | customtkinter 介面，跨平台，也是輸出的參考實作 |

## 功能

- 邊框：比例（原始、平均、1:1、2:3、3:2、4:5、3:4、5:4、9:16、16:9）、粗細、白底／模糊背景、圓角與弧度。
- 相機資訊列：一鍵樣式（經典、簡約置中、logo 機型、只放 logo、完整資訊、左右分開），可勾選機型／鏡頭／焦距／參數／日期。
- 樣式編輯器：把「品牌 logo、機型、鏡頭、焦距、拍攝參數、日期、自訂文字」拖進左／中／右區塊，
  拖移排序、整塊對調、每行設定字級／顏色／粗體／加線；樣式可匯入、匯出（`.igstyle.json`）。
- 即時預覽（可縮放）、縮圖列（可調高度）、批次匯出勾選的照片、預設組合、多個來源資料夾。
- 輸出保留原解析度、JPEG 4:4:4 與 ICC 色彩描述檔；已存在的檔案會先詢問再覆蓋。

## 安裝（macOS 14 以上）

1. 從 [Releases](../../releases) 下載 `PhotoLab-<版本>-macOS.zip`，解壓縮後把 `PhotoLab.app` 放進「應用程式」。
2. App 沒有經過 Apple 公證：第一次請在檔案上按右鍵 → **打開**（或到「系統設定 → 隱私權與安全性」按「仍要打開」）。
3. **品牌 logo 與字體不內含**（商標與授權），請自備，見下一節。

## 自備品牌 logo 與字體

1. 建立並打開資料夾（終端機貼上這兩行，或在 Finder 按 ⌘⇧G 貼上路徑）：

   ```sh
   mkdir -p ~/Library/Application\ Support/Photo_Lab/logos
   open ~/Library/Application\ Support/Photo_Lab/logos
   ```

2. 把 logo 的 PNG 放進去，**檔名用小寫品牌名（只留英文字母與數字）**：

   | 相機品牌 | 檔名 |
   |---|---|
   | Canon / Sony / Nikon | `canon.png` / `sony.png` / `nikon.png` |
   | Fujifilm / Panasonic / Leica | `fujifilm.png` / `panasonic.png` / `leica.png` |
   | OM System | `omsystem.png` |
   | Olympus、Ricoh、Pentax、Sigma、Hasselblad、DJI、Apple、GoPro… | 同樣小寫，例如 `olympus.png` |

3. 檔案要求：**PNG**、背景透明、深色 logo（預設是白邊）、單檔 5 MB 以下。
   用「模糊背景」（深色底）時，可另外放淺色版 `品牌名_dark.png`（例如 `sony_dark.png`），深色背景會優先用它。
4. App 內也有說明：選單列「說明 → 自備品牌 logo 與字體…」會列出路徑與規則，並可一鍵打開（必要時建立）資料夾。
5. 切換一下樣式或重新開啟 App，頁尾就會出現 logo。沒有檔案的品牌會顯示成純文字，不會出錯。

字體：放到 `~/Library/Application Support/Photo_Lab/fonts/`（`.ttf`／`.otf`／`.ttc`），
之後在 App 的「進階 → 字體」裡選用。請只使用你有權使用的字體。

設定與縮圖快取存放位置：`~/Library/Application Support/Photo_Lab/settings.json`、`~/Library/Caches/Photo_Lab/`。
刪掉它們就是全新狀態。

## 從原始碼建置

macOS 原生版（需要 Xcode 命令列工具，Swift 6）：

```sh
cd swift/PhotoLab
./run.sh                     # 建置 release 版並啟動（debug 版慢很多）
swift test                   # 樣式編輯規則的單元測試
./package.sh                 # dist/PhotoLab.app 與 zip（乾淨版，不含 logo）
./package.sh --with-logos    # 把你自己的 logos/ fonts/ 一起包進去（只給自己用）
```

Python 版（建議 Python 3.12 + Tk 9；macOS 內建的 Tk 8.5 會顯示成黑畫面）：

```sh
python3 -m venv .venv && .venv/bin/pip install -r python/requirements.txt
.venv/bin/python python/ig_border_gui.py
```

兩個版本的輸出對照：`.venv/bin/python tools/compare_swift.py`（需要先 `swift build -c release`）。

## 目錄

```
swift/PhotoLab/   原生 macOS 版（PhotoLabCore 渲染核心、PhotoLabApp 介面、photolab-render 命令列工具）
python/           Python 版與參考渲染器
assets/ styles/   圖示與樣式範例
logos/ fonts/     放你自己的品牌 logo 與字體（不進 git）
tools/            對照腳本、圖示產生
CHANGELOG.md      更新紀錄
VERSION           版本號（唯一來源）
```

## 授權與商標

專案本身尚未附授權條款。品牌 logo 為各公司商標、字體各有授權，本專案不提供也不內含；請只使用你有權使用的檔案。
