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
chmod +x setup.sh
./setup.sh
source ~/.bashrc
microide
```

Re-running the script is safe — it cleans up and starts fresh each time.

## Aliases

| Command | What it does |
|---------|-------------|
| `microide` | Full IDE in current directory |
| `microide ~/path` | Full IDE in specified directory (returns to original dir on exit) |
| `micro` | Plain/vanilla micro — completely unmodified by this setup |

The `microide` alias passes `-config-dir ~/.config/microide` so that all IDE plugins and settings live in a separate directory. It accepts an optional directory argument and runs in a subshell, so you return to your original directory when you exit micro. Running `micro` directly uses its default config (`~/.config/micro/`), which this script never touches (and cleans up any leftover files from previous setup attempts).

## What the script does

### 1. Deep cleanup

Removes any leftover filemanager plugins and init.lua from both `~/.config/microide/` and `~/.config/micro/` (from previous attempts). Fixes broken bindings in the default micro config so that `micro` (vanilla) works cleanly.

### 2. Installs the filemanager plugin

Clones the official [micro-editor/updated-plugins](https://github.com/micro-editor/updated-plugins) repository and copies `filemanager-plugin` into `~/.config/microide/plug/filemanager/`.

### 3. Patches the plugin (4 changes to `filemanager.lua`)

**A) Open files in the existing editor pane**

By default the plugin opens every file in a new vertical split. The patch finds the existing editor pane and replaces its buffer instead. Also fixes a Lua issue where `buffer.NewBufferFromFile()` returns two values (buffer + error) which caused a runtime error when passed directly to `OpenBuffer()`.

**B) Enter key opens files and directories**

Overrides `preInsertNewline()` so that pressing Enter in the tree opens the selected file or enters the selected directory.

**C) Single click selects, double click opens**

Replaces `preMousePress()` with a timing-based double-click detector using Go's `time.Now():UnixNano()`. Two clicks within 400ms open the file/directory. A single click just moves the cursor.

**D) Auto-refresh on save and pane switch**

Adds `onSave()` and `onSetActive()` callbacks that call `update_current_dir()` to rescan the filesystem and redraw the tree. Both are wrapped in `pcall()` to prevent crashes when the tree is being closed.

- Saving a file (Ctrl+S) triggers an immediate refresh.
- Switching panes (F2 or mouse click) triggers a refresh — this catches changes made from the terminal or external tools.

> **Note:** changes made in the terminal pane are only reflected after leaving the terminal (F2 or click on another pane), because micro's terminal emulator does not fire Lua plugin callbacks.

### 4. Auto-opens a terminal at the bottom

Creates `init.lua` with a `postinit()` function that opens a horizontal split with a terminal emulator. The terminal opens at 50% height — drag the split border with the mouse to resize.

### 5. Keybinding cleanup

Cleans up any broken bindings from previous setup attempts in both `~/.config/microide/bindings.json` and `~/.config/micro/bindings.json`.

### 6. Bash alias

Adds the `microide` alias to `~/.bashrc`. Also removes any stale `microlite` aliases from previous versions.

## Keybindings

| Key | In tree | In editor | In terminal |
|-----|---------|-----------|-------------|
| **Enter** | Open file / enter dir | Newline | Send command |
| **Double click** | Open file / enter dir | Select word | Select word |
| **Single click** | Select | Move cursor | Move cursor |
| **← / →** | Collapse / expand dir | Move cursor | — |
| **Ctrl+W** | Next pane | Next pane | *(captured by bash)* |
| **Ctrl+S** | — | Save + refresh tree | — |
| **Ctrl+Q** | Close tree | Close file | Close terminal |
| **Ctrl+E** | Command bar | Command bar | — |

> **Terminal pane limitation:** Ctrl+W does not work inside the terminal pane because bash captures it (delete previous word). Use **mouse click** on the editor or tree pane to switch out of the terminal.

## Files modified

| File | Action |
|------|--------|
| `~/.config/microide/plug/filemanager/` | Installed + patched |
| `~/.config/microide/settings.json` | Created |
| `~/.config/microide/bindings.json` | Cleaned up |
| `~/.config/microide/init.lua` | Created (terminal auto-open) |
| `~/.config/micro/bindings.json` | Cleaned up (remove broken entries) |
| `~/.config/micro/plug/filemanager/` | Removed (cleanup) |
| `~/.config/micro/init.lua` | Removed (cleanup) |
| `~/.bashrc` | Added `microide` alias |

## Uninstall

```bash
rm -rf ~/.config/microide
```

Remove the `microide` alias line from `~/.bashrc`.
