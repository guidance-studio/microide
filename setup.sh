#!/bin/bash
set -euo pipefail

MICRO_CONFIG="$HOME/.config/micro"
PLUG_DIR="$MICRO_CONFIG/plug/filemanager"
FMLUA="$PLUG_DIR/filemanager.lua"

echo ""
echo "=== micro IDE setup ==="
echo ""

# ── 1. CLEANUP ──
echo "[1/7] Cleanup..."
rm -f "$MICRO_CONFIG/init.lua"
rm -rf "$PLUG_DIR"
rm -rf /tmp/micro-up
mkdir -p "$MICRO_CONFIG/plug"
echo "   OK"

# ── 2. CLONE OFFICIAL REPO ──
echo "[2/7] Cloning micro-editor/updated-plugins..."
git clone --quiet --depth 1 https://github.com/micro-editor/updated-plugins.git /tmp/micro-up
cp -r /tmp/micro-up/filemanager-plugin "$PLUG_DIR"
rm -rf /tmp/micro-up

if ! grep -q 'import("micro")' "$FMLUA"; then
    echo "   ERROR: downloaded file does not contain modern micro API"
    exit 1
fi
echo "   OK"

# ── 3. PATCH FILEMANAGER.LUA ──
echo "[3/7] Patching filemanager.lua..."

python3 << 'PYEOF'
import os, re, sys

fpath = os.path.expanduser("~/.config/micro/plug/filemanager/filemanager.lua")
with open(fpath, 'r') as f:
    lines = f.readlines()

def skip_function(lines, start):
    """Given index of 'function ...' line, return index after its closing 'end'."""
    i = start + 1
    depth = 1
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith('--'):
            i += 1
            continue
        if re.search(r'\bfunction\b', s):
            depth += 1
        if re.search(r'\bif\b.+\bthen\b', s) and not s.endswith('end'):
            depth += 1
        if re.search(r'\bfor\b.+\bdo\b', s):
            depth += 1
        if re.search(r'\bwhile\b.+\bdo\b', s):
            depth += 1
        for _ in re.finditer(r'\bend\b', s):
            depth -= 1
        if depth <= 0:
            return i + 1
        i += 1
    return i

total = len(lines)
new_lines = []
i = 0
p_vsplit = p_enter = p_mouse = False

while i < total:
    s = lines[i].rstrip('\n')

    # ── PATCH A: file open — replace VSplitIndex with OpenBuffer in existing editor pane
    # buffer.NewBufferFromFile() returns (buf, err); assigning to local captures only buf
    if 'VSplitIndex' in s and 'NewBufferFromFile' in s and 'abspath' in s:
        indent = len(s) - len(s.lstrip())
        ws = ' ' * indent
        new_lines.append(ws + "-- [PATCHED] open in existing editor pane\n")
        new_lines.append(ws + "local _buf = buffer.NewBufferFromFile(scanlist[y].abspath)\n")
        new_lines.append(ws + "local _tab = micro.CurTab()\n")
        new_lines.append(ws + "for _i = 1, #_tab.Panes do\n")
        new_lines.append(ws + "    if _tab.Panes[_i] ~= tree_view then\n")
        new_lines.append(ws + "        _tab:SetActive(_i - 1)\n")
        new_lines.append(ws + "        _tab.Panes[_i]:OpenBuffer(_buf)\n")
        new_lines.append(ws + "        break\n")
        new_lines.append(ws + "    end\n")
        new_lines.append(ws + "end\n")
        p_vsplit = True
        i += 1
        continue

    # ── PATCH B: Enter key opens file/dir in tree
    if s.strip().startswith('function preInsertNewline'):
        new_lines.append("function preInsertNewline(view)\n")
        new_lines.append("    if view == tree_view then\n")
        new_lines.append("        try_open_at_cursor()\n")
        new_lines.append("        return false\n")
        new_lines.append("    end\n")
        new_lines.append("end\n")
        p_enter = True
        i = skip_function(lines, i)
        continue

    # ── PATCH C: single click = select, double click = open (timing-based)
    if s.strip().startswith('function preMousePress'):
        new_lines.append("-- [PATCHED] single click = select, double click = open\n")
        new_lines.append("local _gotime = import(\"time\")\n")
        new_lines.append("local _last_tree_click = 0\n")
        new_lines.append("\n")
        new_lines.append("function preMousePress(view, event)\n")
        new_lines.append("    if view == tree_view then\n")
        new_lines.append("        local now = _gotime.Now():UnixNano() / 1000000\n")
        new_lines.append("        if now - _last_tree_click < 400 then\n")
        new_lines.append("            _last_tree_click = 0\n")
        new_lines.append("            try_open_at_cursor()\n")
        new_lines.append("            return false\n")
        new_lines.append("        end\n")
        new_lines.append("        _last_tree_click = now\n")
        new_lines.append("    end\n")
        new_lines.append("end\n")
        p_mouse = True
        i = skip_function(lines, i)
        continue

    new_lines.append(lines[i])
    i += 1

# ── PATCH D: auto-refresh tree on save and pane switch
new_lines.append("\n")
new_lines.append("-- [PATCHED] auto-refresh tree on save and pane switch\n")
new_lines.append("function onSave(view)\n")
new_lines.append("    if tree_view ~= nil then\n")
new_lines.append("        update_current_dir(current_dir)\n")
new_lines.append("    end\n")
new_lines.append("    return true\n")
new_lines.append("end\n")
new_lines.append("\n")
new_lines.append("function onSetActive(view)\n")
new_lines.append("    if tree_view ~= nil then\n")
new_lines.append("        update_current_dir(current_dir)\n")
new_lines.append("    end\n")
new_lines.append("end\n")

with open(fpath, 'w') as f:
    f.writelines(new_lines)

print(f"   A) VSplit->OpenBuffer (local var fix): {'OK' if p_vsplit else 'FAILED'}")
print(f"   B) Enter opens in tree:                {'OK' if p_enter else 'FAILED'}")
print(f"   C) Click=select, DblClick=open:        {'OK' if p_mouse else 'FAILED'}")
print(f"   D) Auto-refresh on save/pane switch:   OK")

if not (p_vsplit and p_enter and p_mouse):
    sys.exit(1)
PYEOF

if [ $? -ne 0 ]; then
    echo "   ERROR in patches!"
    exit 1
fi

# ── 4. INIT.LUA (auto terminal at bottom) ──
echo "[4/7] Writing init.lua (auto terminal)..."

cat > "$MICRO_CONFIG/init.lua" << 'LUAEOF'
local micro = import("micro")

function postinit()
    -- postinit() runs after all plugins (including filemanager) have initialized.
    -- At this point the tree is already open and the editor pane is active.
    local pane = micro.CurPane()
    if pane ~= nil then
        -- Create horizontal split (new pane below, which gets focus)
        pane:HSplitAction()
        -- Open terminal in the new bottom pane
        micro.CurPane():HandleCommand("term")
        -- Cursor starts in terminal; press F2 or click to switch to editor
    end
end
LUAEOF

echo "   OK"

# ── 5. SETTINGS.JSON ──
echo "[5/7] Writing settings.json..."

python3 << 'PYEOF'
import json, os

spath = os.path.expanduser("~/.config/micro/settings.json")
settings = {}
if os.path.exists(spath):
    try:
        with open(spath) as f:
            settings = json.load(f)
    except:
        pass

settings["filemanager.openonstart"] = True
settings["filemanager.foldersfirst"] = True

with open(spath, 'w') as f:
    json.dump(settings, f, indent=4, sort_keys=True)
print("   OK")
PYEOF

# ── 6. BINDINGS.JSON ──
echo "[6/7] Writing bindings.json..."

python3 << 'PYEOF'
import json, os

bpath = os.path.expanduser("~/.config/micro/bindings.json")
bindings = {}
if os.path.exists(bpath):
    try:
        with open(bpath) as f:
            bindings = json.load(f)
    except:
        pass

# Remove broken bindings from previous setup attempts
for key in list(bindings.keys()):
    val = str(bindings.get(key, ''))
    if 'filemanager' in val or 'MouseDoubleClick' in key:
        del bindings[key]

# F2 = cycle panes (works even from the terminal pane, because
# bash/zsh don't use F2 and the terminal emulator passes it through)
bindings["F2"] = "NextSplit|FirstSplit"

with open(bpath, 'w') as f:
    json.dump(bindings, f, indent=4, sort_keys=True)
print("   OK (F2 = cycle panes)")
PYEOF

# ── 7. BASH ALIAS ──
echo "[7/7] Setting up aliases..."

BASHRC="$HOME/.bashrc"

# microide alias (full IDE: tree + editor + terminal)
if ! grep -q 'alias microide=' "$BASHRC" 2>/dev/null; then
    echo '' >> "$BASHRC"
    echo '# micro IDE aliases' >> "$BASHRC"
    echo 'alias microlite="micro --clean"' >> "$BASHRC"
    echo "   OK — added 'microlite' aliases to .bashrc"
else
    # Update existing aliases
    sed -i 's|^alias microlite=.*|alias microlite="micro --clean"|' "$BASHRC"
    echo "   OK — updated existing aliases in .bashrc"
fi

# ── DONE ──
echo ""
echo "=== DONE ==="
echo ""
echo "  microlite   = plain micro, no plugins/config"
echo "  F2          = cycle panes (works from terminal too)"
echo ""
echo "  Run: source ~/.bashrc && microide"
echo ""
