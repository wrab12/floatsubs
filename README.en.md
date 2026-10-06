# FloatSubs

[简体中文](README.md) | **English**

FloatSubs takes YouTube's subtitles off the page and floats them on your Mac desktop as bilingual subtitles, like the desktop lyrics in NetEase Cloud Music.

![FloatSubs preview](docs/preview-subtitles.png)

## Why I built this

YouTube is full of great videos: podcasts, interviews, lectures, documentaries. But my computer can't stay on the YouTube page all day, because I still need to write, look things up and do other work.

As an English learner, I wanted to keep listening to these videos while working and still glance at the subtitles whenever I like. So I built this little tool. It takes the subtitles out of the web page and floats them on top of everything, anywhere on the screen. Even when the YouTube tab is in the background or the browser is covered by other windows, the subtitles keep scrolling. It works well for podcasts, interviews, talks and anything else you listen to.

## Features

- **Bilingual floating subtitles**: shows the dual subtitles from [Language Reactor](https://www.languagereactor.com/) (LR), or YouTube's own captions if LR isn't installed.
- **Always on top**: the window is transparent, can be dragged anywhere and shows over full-screen videos. When you lock it, clicks pass straight through.
- **Keeps updating in the background**: the subtitles keep going when another tab is in front or the window is covered or minimized.
- **Hover to pause**: the video pauses while your mouse is over the subtitles and resumes when you move away, just like LR.
- **Click a word to look it up**: shows the word's entry from the macOS dictionaries (e.g. the Oxford Chinese Dictionary) and reads it aloud in a US English voice.
- **Vocabulary highlighting**: words you look up go into your word list and appear in red wherever they show up again. Double-click a red word to remove it.
- **Subtitle-style line breaks**: about 42 letters per line. Longer sentences are split into two balanced lines.
- **Adjustable**: font size, color and line length.

## Requirements

- macOS 12 or later
- Google Chrome (latest version recommended)
- Xcode Command Line Tools, to build the Mac app on your own machine. If you don't have them, run:
  ```bash
  xcode-select --install
  ```
- [Language Reactor](https://www.languagereactor.com/) is recommended, since the bilingual subtitles come from it.

## Installation

**1. Get the code**

```bash
git clone https://github.com/wrab12/floatsubs.git
cd floatsubs
```

Or click **Code → Download ZIP** on this page, unzip it and open the folder in Terminal.

**2. Install the Mac app**

```bash
bash install.sh
```

This builds the app on your Mac, puts it in `~/Applications/FloatSubs.app` and registers it with Chrome so the extension can start it.

**3. Install the Chrome extension**

1. Open `chrome://extensions` in Chrome
2. Turn on **Developer mode** (top right)
3. Click **Load unpacked** and choose the `extension` folder inside `floatsubs`

**4. Start watching**

Open a YouTube video that has subtitles, with LR on as usual. When the first subtitle appears, the floating subtitles pop up.

> After installing the extension, reload any YouTube tabs that were already open.

### Definitions in your language

FloatSubs uses the dictionaries enabled in the macOS **Dictionary** app. To see definitions in your language, open Dictionary, go to Settings, turn on a bilingual dictionary (for Chinese, the Oxford Chinese Dictionary) and drag it to the top of the list.

### A more natural US voice (optional)

Go to **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices** and download a premium English (US) voice such as Ava. FloatSubs automatically uses the best US English voice on your Mac.

## How to use

| Action | What happens |
| --- | --- |
| Drag the subtitles | Moves them; the position is remembered |
| Hover over the subtitles | Pauses the video; it resumes when you move away |
| Click a word | Shows its dictionary entry and reads it aloud; the word is added to your word list and turns red |
| Double-click a red word | Removes it from your word list |
| Click the speaker on the dictionary card | Plays the pronunciation again |
| Click the menu bar icon, or right-click the subtitles | Opens the settings menu (see below) |
| Click the extension's icon in the Chrome toolbar | Turns FloatSubs on or off |

![Dictionary card](docs/preview-dictionary.png)

The menus are currently in Chinese. Here is what each item does:

| Menu item | Meaning |
| --- | --- |
| 锁定字幕（鼠标可穿透） | Lock the subtitles (clicks pass through) |
| 鼠标悬停时暂停视频 | Pause the video on hover |
| 点词时朗读（美式发音） | Read clicked words aloud (US voice) |
| 显示原文 / 显示翻译 | Show the original / show the translation |
| 句子间隙保留上一句 | Keep the previous line during gaps |
| 放大字号 / 缩小字号 | Larger / smaller text |
| 颜色 | Color |
| 每行长度（超出自动分两行） | Line length (longer sentences wrap onto two lines) |
| 重置位置 | Reset position |
| 暂时隐藏悬浮窗 | Hide for now |
| 关闭悬浮字幕 | Quit FloatSubs (turn it back on from the Chrome toolbar icon) |

Your word list is saved in `~/Library/Application Support/FloatSubs/vocabulary.json`. Each entry records the word, its base form, when you added it and the subtitle line it came from, so you can review or export it later.

## FAQ

- **The extension icon shows a red `!`**: the Mac app couldn't start. Hover over the icon to see why. Running `bash install.sh` again usually fixes it.
- **No subtitles appear**: make sure the video has subtitles and that LR shows them on the YouTube page, then reload the page.
- **The icon shows `OFF`**: FloatSubs is turned off. Click the icon to turn it back on.
- **Subtitles stop working after an LR update**: FloatSubs falls back to YouTube's own captions. Please open an issue.

## Uninstall

```bash
bash uninstall.sh
```

Then remove the extension in `chrome://extensions`. The app is moved to the Trash and your word list is kept.

## How it works

```
YouTube page (LR subtitles) → Chrome extension → Chrome Native Messaging → floating window on your Mac
```

- `extension/`: the Chrome extension (Manifest V3). `content.js` reads the current subtitle, `page.js` keeps subtitles updating while the page is in the background, and `background.js` relays them to the Mac app.
- `mac/main.m`: the Mac app (Objective-C), which handles the floating window, dictionary lookup, pronunciation and word list.
- `install.sh` / `uninstall.sh`: build and install, or uninstall.

## Privacy

Everything happens on your own computer. Subtitles only travel between the Chrome extension and the app on your Mac, lookups use the built-in macOS dictionaries, and your word list stays on your Mac. Nothing is collected or uploaded.

## Disclaimer

This is a personal open-source project. It is not affiliated with Language Reactor, YouTube or Google.

## License

[MIT](LICENSE)

---

If you find FloatSubs useful, please give it a ⭐ **Star**, and feel free to **follow** me [@wrab12](https://github.com/wrab12)!
