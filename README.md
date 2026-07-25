# PreviewBezel

一鍵把 Xcode Preview 截圖套上 iPhone bezel 外框,並複製到剪貼簿。

按下 Xcode 裡綁定的快捷鍵(例如 ⌘P),就會自動:

1. 觸發 Xcode 選單 **Editor ▸ Canvas ▸ Copy Preview Screenshot**,取得乾淨的 preview 渲染圖(無狀態列、Dynamic Island 為黑色藥丸)
2. 自動偵測 `bezel.png` 的透明螢幕區域,把截圖以 aspect-fill 合成進去
3. 合成結果存到 `.build/last-output.png`,同時以 PNG + TIFF 放回剪貼簿,直接貼到 Slack、簡報或社群

## 安裝

1. Clone 這個 repo
2. 在 Xcode ▸ Settings ▸ Behaviors 新增一個 behavior,勾選 **Run**,選擇 `preview-bezel.sh`,並綁定快捷鍵(建議 ⌘P)
3. 第一次執行時,若系統詢問「輔助使用」(Accessibility)權限,請允許——點擊 Xcode 選單需要這個權限。若沒有跳出詢問但執行失敗,到「系統設定 ▸ 隱私權與安全性 ▸ 輔助使用」手動把 Xcode 打開

## 使用

1. 在 Xcode 打開 SwiftUI 檔案,讓 Canvas preview 跑起來
2. 按下綁定的快捷鍵
3. 收到「已合成並複製到剪貼簿」通知後直接貼上即可

## 更換 bezel

把 `bezel.png` 換成任何「螢幕區域為透明」的裝置外框圖即可,程式會自動偵測透明區域的位置與大小,不需要改程式碼。目前附的是 iPhone 17 Pro(宇宙橙),螢幕挖洞剛好是 1206×2622,與 preview 截圖 1:1。

## 運作原理

- `preview-bezel.sh`:入口腳本,原始碼有更新時自動用 `swiftc` 重新編譯,再執行 binary
- `PreviewBezel.swift`:核心邏輯
  - 用 AppleScript(System Events)點擊 Copy Preview Screenshot,輪詢剪貼簿 `changeCount` 取得截圖
  - 讀取 bezel 圖的 alpha channel,從中心往四周走出螢幕的透明矩形(垂直方向取螢幕寬度 18%–82% 的直欄,避開 Dynamic Island)
  - 從影像邊界 flood fill 找出手機輪廓以外的區域,清除 aspect-fill 溢出的像素(螢幕是圓角,外接矩形的四角會超出輪廓)
  - 最後把 bezel 疊在最上層,輸出 PNG 並寫入剪貼簿

> 註:Editor 選單有兩個同名的「Canvas」項目(顯示開關與子選單),而且 AppleScript 會把存進變數的索引引用改寫成名稱引用,所以選單存取全部使用行內索引鏈,細節見 `PreviewBezel.swift` 的註解。
