#!/bin/bash
set -euo pipefail

MICRO_CONFIG="$HOME/.config/microide"
PLUG_DIR="$MICRO_CONFIG/plug/filemanager"
FMLUA="$PLUG_DIR/filemanager.lua"

echo ""
echo "=== micro IDE setup ==="
echo ""

# ── 0. INSTALL MICRO IF MISSING ──
if ! command -v micro &>/dev/null; then
    echo "[0/7] Installing micro editor..."
    tmpdir=$(mktemp -d)
    (cd "$tmpdir" && curl -fsSL https://getmic.ro | bash)
    mkdir -p "$HOME/.local/bin"
    mv "$tmpdir/micro" "$HOME/.local/bin/micro"
    rm -rf "$tmpdir"
    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        export PATH="$HOME/.local/bin:$PATH"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    echo "   Installed micro to ~/.local/bin/micro"
else
    echo "[0/7] micro already installed: $(micro -version 2>&1 | head -1)"
fi

# ── 1. CLEANUP ──
echo "[1/7] Deep cleanup..."
# Clean microide config
rm -f "$MICRO_CONFIG/init.lua"
rm -rf "$PLUG_DIR"
rm -rf /tmp/micro-up
mkdir -p "$MICRO_CONFIG/plug"
# Clean leftover plugins/config from old attempts in default micro config
rm -rf "$HOME/.config/micro/plug/filemanager"
rm -f "$HOME/.config/micro/init.lua"
# Fix broken bindings in default micro config (from previous attempts)
if [ -f "$HOME/.config/micro/bindings.json" ]; then
    python3 -c "
import json
p='$HOME/.config/micro/bindings.json'
try:
    b=json.load(open(p))
    changed=False
    for k in list(b):
        v=str(b[k])
        if 'FirstSplit' in v or 'filemanager' in v or 'MouseDoubleClick' in k:
            del b[k]; changed=True
    if changed:
        json.dump(b,open(p,'w'),indent=4)
        print('   Cleaned default micro bindings.json')
except: pass
"
fi
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

fpath = os.path.expanduser("~/.config/microide/plug/filemanager/filemanager.lua")
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
# IMPORTANT: guard against tree_view being destroyed during close_tree.
# update_current_dir calls ResizePane on tree_view, which crashes if
# tree_view has already been Quit'd. Use pcall to catch this safely.
new_lines.append("\n")
new_lines.append("-- [PATCHED] auto-refresh tree on save and pane switch\n")
new_lines.append("function onSave(view)\n")
new_lines.append("    if tree_view ~= nil then\n")
new_lines.append("        pcall(update_current_dir, current_dir)\n")
new_lines.append("    end\n")
new_lines.append("    return true\n")
new_lines.append("end\n")
new_lines.append("\n")
new_lines.append("function onSetActive(view)\n")
new_lines.append("    if tree_view ~= nil then\n")
new_lines.append("        pcall(update_current_dir, current_dir)\n")
new_lines.append("    end\n")
new_lines.append("end\n")

with open(fpath, 'w') as f:
    f.writelines(new_lines)

print(f"   A) VSplit->OpenBuffer (local var fix): {'OK' if p_vsplit else 'FAILED'}")
print(f"   B) Enter opens in tree:                {'OK' if p_enter else 'FAILED'}")
print(f"   C) Click=select, DblClick=open:        {'OK' if p_mouse else 'FAILED'}")
print(f"   D) Auto-refresh (with pcall guard):    OK")

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

spath = os.path.expanduser("~/.config/microide/settings.json")
settings = {}
if os.path.exists(spath):
    try:
        with open(spath) as f:
            settings = json.load(f)
    except:
        pass

settings["filemanager.openonstart"] = True
settings["filemanager.foldersfirst"] = True
settings["softwrap"] = True

with open(spath, 'w') as f:
    json.dump(settings, f, indent=4, sort_keys=True)
print("   OK")
PYEOF

# ── 6. BINDINGS.JSON ──
echo "[6/7] Writing bindings.json..."

python3 << 'PYEOF'
import json, os

bpath = os.path.expanduser("~/.config/microide/bindings.json")
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
    if 'filemanager' in val or 'MouseDoubleClick' in key or 'FirstSplit' in val or 'NextSplit' in val:
        del bindings[key]

# Remove F2 if present (doesn't work inside terminal pane)
bindings.pop("F2", None)

with open(bpath, 'w') as f:
    json.dump(bindings, f, indent=4, sort_keys=True)
print("   OK")
PYEOF

# ── 7. BASH ALIAS ──
echo "[7/7] Setting up aliases..."

BASHRC="$HOME/.bashrc"
# Remove all old microide/microlite aliases first
sed -i '/^alias microide=/d' "$BASHRC"
sed -i '/^alias microlite=/d' "$BASHRC"
sed -i '/^# micro IDE alias/d' "$BASHRC"
sed -i '/^_microide()/d' "$BASHRC"
sed -i '/^alias microide/d' "$BASHRC"

# Add clean alias (function + alias for directory support)
{
    echo ''
    echo '# micro IDE alias'
    echo '_microide() { local d="${1:-.}"; (cd "$d" && micro -config-dir ~/.config/microide); }'
    echo 'alias microide="_microide"'
} >> "$BASHRC"
echo "   OK"

# ── DONE ──
echo ""
echo "=== DONE ==="
echo ""
echo "  microide           = IDE mode (tree + editor + terminal)"
echo "  microide ~/path    = IDE mode in specified directory"
echo "  micro              = plain/vanilla micro (unchanged)"
echo ""
echo "  Navigate panes: Ctrl+W or mouse click"
echo "  (Ctrl+W does not work inside the terminal pane — use mouse click)"
echo ""
echo "  Run: source ~/.bashrc && microide"
echo ""
