# Don't Delete Me

**English** · [简体中文](README.zh-CN.md)

> Every icon on your Mac desktop gets a face. They watch your cursor — and burst into tears when you drag them toward the Trash.

<!-- 待核实：演示动图尚未录制（分镜见 docs/发布/动图分镜.md）。录好后把下面这行占位文字换成：
     <p align="center"><img src="Assets/demo.gif" width="720" alt="Desktop icons with faces follow the cursor; one is dragged to the Trash and cries, the others cover their eyes, and a little ghost floats up."></p>
     动图的存放路径也待定。 -->
*Demo GIF goes here — it hasn't been recorded yet. **[TO VERIFY · 待核实]***

Don't Delete Me only *draws on top of* your desktop. It never changes, moves, renames, or deletes any of your files or icons. Open it and it works: no account, no settings, no network.

This is version 0.1.0, for macOS. A Windows version is planned but does not exist yet.

## What they do

| When you… | They… |
|---|---|
| move the mouse | follow it with their eyes, and blink every now and then |
| rest the pointer on one | it blushes and looks away |
| grab one and shake it around | it gets dizzy — spiral eyes, little stars — and stays dizzy for two or three seconds after you let go |
| drag one toward the Trash | the closer it gets, the worse it looks: first sweat, then trembling, then full-on crying. Everyone else reacts too — the timid ones cover their eyes, the curious ones peek between their fingers, the bold ones just stare — and the panic spreads outward like a ripple |
| change your mind and put it back | false alarm: the sweat slowly dries and the onlookers lower their hands |
| really delete it | a tiny ghost floats up from where it used to sit. It doesn't matter how you delete — dragging, the keyboard shortcut, or the right-click menu. Delete several at once and the ghosts rise one after another |
| leave a file untouched for more than half a year | it dozes off. At most a third of your icons sleep at the same time, and bringing the pointer close wakes them up |
| leave the mouse alone for ten seconds or so | they get bored and start looking around |
| put something new on the desktop | everyone turns to look at the newcomer |

Every icon looks a little different and has its own temperament (timid, curious, or bold). The same icon gets the same face every time.

The whole interface is one menu bar icon with two items: **Pause / Resume** and **Quit**. There is no Dock icon and no settings window. Two displays are supported (tested with a built-in display plus one external monitor), and opening the app a second time never gives you a second set of faces.

## Download and first launch

**Requirements:** the app declares macOS 14 as its minimum, but so far it has only been run on macOS 27.0.1 on an Apple Silicon Mac. Other versions are untested.

1. Download the app from the [Releases page](../../releases/latest). **[TO VERIFY · 待核实]** — nothing has been published yet; the link, the file name, and whether the download also runs on Intel Macs will be filled in with the first release.
2. Unzip it and put `DontDeleteMe.app` wherever you like. The Applications folder is a fine choice.
3. Open it. The first time, macOS will probably refuse — see below.
4. macOS asks whether Don't Delete Me may control Finder. Allow it. ([Why it asks](#permissions-and-privacy).)
5. Faces appear on your desktop icons, and a small icon appears in the menu bar.

### "macOS won't let me open it"

Don't Delete Me is not notarized by Apple: notarization requires a paid Apple developer account, and this project doesn't have one. So macOS will most likely block a downloaded copy the first time you open it.

> **[TO VERIFY · 待核实]** The steps below are what we expect on recent macOS versions. They have not yet been tested with a copy downloaded from the internet, so the exact wording may differ. Screenshots will be added once they are confirmed.
>
> 1. Double-click the app. macOS warns that it can't verify the app. Click **Done** — not "Move to Trash". (The icons would never forgive you.)
> 2. Open **System Settings → Privacy & Security**, scroll down to the Security section, and click **Open Anyway** next to the message about Don't Delete Me.
> 3. Confirm, and enter your password if asked. You only have to do this once.
>
> <!-- 待核实：截图位置 1 —— 第一次双击时的系统拦截提示 -->
> <!-- 待核实：截图位置 2 —— 系统设置 → 隐私与安全性里的「仍要打开」 -->
> <!-- 待核实：截图位置 3 —— 「是否允许控制访达」的授权弹窗 -->

Prefer not to deal with that at all? [Build it from source](#build-from-source) — an app you compile yourself opens without the warning.

## Permissions and privacy

The short version: **one permission, read-only, completely offline.**

### The one permission: control Finder

Don't Delete Me finds out where your desktop icons are by asking Finder. macOS guards that with the "Automation" permission, which is why you see a prompt on first launch. The prompt carries this explanation:

> Don't Delete Me needs to ask Finder where your desktop icons are, so it can draw faces on them. It never moves, modifies, or deletes any of your files.

What it asks Finder for: each desktop icon's position, name, kind, and modification date, plus desktop view settings such as the icon size. Every request is a *read*. The app contains no request that moves, renames, or deletes anything.

If you decline, the app simply draws nothing. You can change your mind in **System Settings → Privacy & Security → Automation**, and the faces should show up by themselves shortly after. **[TO VERIFY · 待核实]** — declining and recovering is covered by automated tests but has not been tried by hand yet.

### What it does not ask for

Accessibility, Input Monitoring, Screen Recording, Full Disk Access — none of them. It doesn't need them and never requests them.

### What else it looks at

These need no permission, and all of them are read-only:

- One of Finder's desktop display settings — whether Stacks is turned on.
- The Dock's settings and the list of running apps — only to count how many items are in the Dock, so it can work out where the Trash is.
- Which windows are on screen, their stacking order and their outlines — to tell whether the desktop is covered and whether the pointer is over the desktop. It does not read window titles and takes no screenshots.
- The pointer's position and whether the mouse button is down. It checks these on a timer; it does not intercept or alter any input.

### What it never does

- **It never goes online.** No network requests at all: no analytics, no update checks.
- **It never reads the contents of any file.**
- **It never keeps your file names.** A name is used only in memory, mixed with a random number, to give each icon an unreadable ID. Names are never saved and never written out anywhere.
- **It never touches your files or icons.** The faces are drawn in a transparent window that sits above the icons and lets every click pass straight through.

### What it stores

Two small things, in its own preferences: a random number (so each icon gets the same face every time) and where it has learned the Trash is (a few numbers).

Everything above can be checked in the source. All conversation with Finder lives in `Sources/IconBridge/`.

## FAQ

**Will it delete my files?**
No. It cannot move, rename, or delete anything; it only draws. Deleting is still entirely up to you — and it won't stop you, either. Crying is the only defence these icons have.

**Will it drain my battery?**
It tries to stay out of the way, but it is not free. Measured on one machine (Apple Silicon, macOS 27.0.1, about 20 desktop icons, release build), as a share of a single CPU core:

| Situation | CPU |
|---|---|
| Paused | about 0.1% |
| Desktop not visible (covered by windows, a full-screen app, locked, display asleep) | about the same as paused — nothing is drawn |
| Desktop visible, mouse mostly still | about 4.3–4.6% |
| Desktop visible, mouse moving on and off | about 5–6% |

Memory use is about 61 MB. Finder also does a little work answering the app's questions: roughly 0.9% of a core while the mouse is resting and 3.4% while you are moving it (measured with 19 icons; it grows with the number of icons), and practically nothing while the app is paused or the desktop is hidden. These numbers describe one machine and one desktop, and we have not measured battery life itself. If you want it gone for a while, choose **Pause** in the menu bar.

**Why are some icons asleep?**
A file that hasn't been modified for more than half a year dozes off. At most a third of your icons nap at the same time — the ones left alone the longest go first — and a sleeper wakes up when the pointer comes close.

**Why don't I see any faces?**
The usual reasons:

- The app is paused (the menu bar icon looks faded). Choose **Resume**.
- Stacks is turned on for the desktop. Icon positions aren't reliable with Stacks, so the faces stay hidden.
- Desktop items are hidden in System Settings. The faces hide along with the icons.
- You are in a full-screen app's space. There are no faces there.
- Finder access was declined. See [the one permission](#the-one-permission-control-finder).

**The faces cover part of my icons.**
Yes, a little. See [Known limitations](#known-limitations).

**How do I stop it or remove it?**
Choose **Quit** from the menu bar icon and the faces go away. To uninstall, quit and move the app to the Trash. (Yes, we see the irony.) **[TO VERIFY · 待核实]** To also clear its small preferences and its Finder permission record, run `defaults delete io.github.dont-delete-me` and `tccutil reset AppleEvents io.github.dont-delete-me` — the identifier in these commands is provisional and may change before the first release.

**Is there a Windows version?**
Not yet. It is planned, but not implemented.

## Known limitations

- Tested only on macOS 27.0.1 on Apple Silicon.
- Not notarized, so the first launch takes a few extra clicks (see above).
- No faces while Stacks is on, while desktop items are hidden, or in a full-screen app's space.
- The face always sits just above the middle of the icon. If the icon has something important there — an image thumbnail, say — the eyes cover it.
- Tears run over the top half of the file name; Zzz's and ghosts can spill onto the icon above.
- Desktop widgets cover the faces.
- If you drag several icons at once, only the one under the pointer plays the lead.
- Deleting immediately (skipping the Trash) leaves no ghost.
- Finder doesn't answer questions while you are dragging an icon, so icons that appear or vanish during a drag only show up after you let go.
- The app estimates where the Trash is from the Dock's settings and its actual extent on screen, and calibrates itself after the first real deletion.
- The first time you visit a new desktop space, the faces fade in about half a second late.
- Nothing has been adapted for accessibility settings such as Reduce Motion.
- Windows: planned, not implemented.

## Build from source

You need macOS and a Swift 6 toolchain. Apple's Command Line Tools are enough — the full Xcode is not required — and there are no third-party dependencies.

```bash
git clone https://github.com/OWNER/dont-delete-me.git   # [TO VERIFY · 待核实] the repository address isn't final
cd dont-delete-me

swift build                 # compile everything
swift run DontDeleteMe      # run it straight from the build
scripts/build-app.sh        # package it → build/DontDeleteMe.app
open build/DontDeleteMe.app
```

When you use `swift run`, the program has no identity of its own, so the "control Finder" prompt is attributed to your terminal app. For the real experience, package it and open `build/DontDeleteMe.app`.

For development:

```bash
scripts/test.sh             # run the unit tests
scripts/check.sh            # warnings-free build + dependency rules + tests + demos
```

Developer documentation (in Chinese) is in [`docs/`](docs/); start with [`docs/开发说明.md`](docs/开发说明.md).

## How it works

- **IconBridge** asks Finder where the desktop icons are and keeps watching for icons that appear, move, or vanish.
- **Overlay** shows the faces in transparent, click-through windows — one layer just above the desktop icons, plus one above everything else for the icon you are dragging — and stops drawing whenever the desktop isn't visible.
- **InputSense** watches the pointer and works out what you are doing: hovering, dragging, shaking, heading for the Trash, and how a drag ended.
- **Emotion** turns that into feelings. There are no on/off states — just a handful of continuous values (fear, sweat, tears, dizziness, blush, sleepiness…) that fade in and out, so moods blend smoothly.
- **Faces** draws every face in code with Core Graphics. There are no image assets.

The five modules know nothing about each other; the app target wires them into one pipeline. It is written in Swift with AppKit.

## Similar toys

If you like things that look back at you:

- [Googly Eyes](https://sindresorhus.com/googly-eyes) by Sindre Sorhus — a pair of eyes in the macOS menu bar that follow your cursor.
- [The Icon Battles](https://store.steampowered.com/app/2135980/) by Yenot Software — on Windows, your desktop icons come to life and fight each other.

## License

[MIT](LICENSE) © 2026 Don't Delete Me contributors
