# micro IDE Setup

A setup script that turns the [micro](https://micro-editor.github.io/) terminal editor (v2.0.15) into a lightweight IDE with a file tree, editor pane, and integrated terminal — without modifying micro's default configuration.

## Layout

```
┌──────────┬──────────────────────────┐
│ tree     │       editor             │
│          │                          │
│ project/ │   your code here         │
│ ├─ src/  │                          │
│ ├─ docs/ │                          │
│ └─ ...   │                          │
│          ├──────────────────────────┤
│          │       terminal           │
│          │  $ _                     │
└──────────┴──────────────────────────┘
```

## Requirements

- **micro** 2.0.15 (`micro -version`)
- **git**, **python3**
- Tested on Ubuntu 25.10

## Installation

```bash
git clone git@gitlab.com:gd-pub/microide.git
cd microide
chmod +x setup.sh
./setup.sh
source ~/.bashrc
microide
```

Re-running the script is safe — it cleans up and starts fresh each time.

## Aliases

| Command | What it does |
|---------|-------------|
| `microide` | Full IDE: tree + editor + terminal (uses `~/.config/microide/`) |
| `micro` | Plain/vanilla micro — completely unmodified by this setup |

The `microide` alias sets `MICRO_CONFIG_DIR=~/.config/microide` so that all IDE plugins and settings live in a separate directory. Running `micro` directly uses its default config (`~/.config/micro/`), which this script never touches.

## What the script does

### 1. Installs the filemanager plugin

Clones the official [micro-editor/updated-plugins](https://github.com/micro-editor/updated-plugins) repository and copies `filemanager-plugin` into `~/.config/microide/plug/filemanager/`.

### 2. Patches the plugin (4 changes to `filemanager.lua`)

**A) Open files in the existing editor pane**

By default the plugin opens every file in a new vertical split. The patch finds the existing editor pane and replaces its buffer instead. Also fixes a Lua issue where `buffer.NewBufferFromFile()` returns two values (buffer + error) which caused a runtime error when passed directly to `OpenBuffer()`.

**B) Enter key opens files and directories**

Overrides `preInsertNewline()` so that pressing Enter in the tree opens the selected file or enters the selected directory.

**C) Single click selects, double click opens**

Replaces `preMousePress()` with a timing-based double-click detector using Go's `time.Now():UnixNano()`. Two clicks within 400ms open the file/directory. A single click just moves the cursor.

**D) Auto-refresh on save and pane switch**

Adds `onSave()` and `onSetActive()` callbacks that call `update_current_dir()` to rescan the filesystem and redraw the tree.

- Saving a file (Ctrl+S) triggers an immediate refresh.
- Switching panes (F2, Ctrl+W, or mouse click) triggers a refresh — this catches changes made from the terminal or external tools.

> **Note:** changes made in the terminal pane are only reflected after leaving the terminal (F2 or click on another pane), because micro's terminal emulator does not fire Lua plugin callbacks.

### 3. Auto-opens a terminal at the bottom

Creates `~/.config/microide/init.lua` with a `postinit()` function that opens a horizontal split with a terminal emulator. The terminal opens at 50% height — drag the split border with the mouse to resize.

### 4. F2 = cycle panes (works everywhere)

Binds **F2** to `NextSplit|FirstSplit` in `bindings.json`. This is the recommended way to navigate between panes because:

- **Ctrl+W** works in tree and editor, but **not in the terminal** (bash interprets it as "delete previous word").
- **F2** is not used by bash, zsh, or the GNOME terminal, so it passes through cleanly to micro even from the terminal pane.
- **Mouse click** on any pane also always works.

### 5. Bash alias

Adds the `microide` alias to `~/.bashrc`:
- `microide` → `MICRO_CONFIG_DIR=~/.config/microide micro .`

## Keybindings

| Key | In tree | In editor | In terminal |
|-----|---------|-----------|-------------|
| **F2** | Next pane | Next pane | Next pane |
| **Enter** | Open file / enter dir | Newline | Send command |
| **Double click** | Open file / enter dir | Select word | Select word |
| **Single click** | Select | Move cursor | Move cursor |
| **← / →** | Collapse / expand dir | Move cursor | — |
| **Ctrl+S** | — | Save + refresh tree | — |
| **Ctrl+Q** | Close tree | Close file | Close terminal |
| **Ctrl+E** | Command bar | Command bar | — |

## Files modified

| File | Action |
|------|--------|
| `~/.config/microide/plug/filemanager/` | Installed + patched |
| `~/.config/microide/settings.json` | Updated (merged) |
| `~/.config/microide/bindings.json` | F2 binding + cleanup |
| `~/.config/microide/init.lua` | Created (terminal auto-open) |
| `~/.bashrc` | Added alias |

## Uninstall

```bash
rm -rf ~/.config/microide
```

Remove the `microide` alias line from `~/.bashrc`.
