#!/bin/bash
# ============================================================================
# openclaw-to-claude — Migrate OpenClaw to Claude Code
# https://github.com/anthropics/claude-code
#
# Automatically migrates:
#   - Environment variables
#   - System prompt (CLAUDE.md) from workspace docs
#   - Long-term + daily memory
#   - Telegram bot (token, allowlist, plugin, MCP)
#   - Permissions (full access, no prompts)
#   - systemd service (tmux + expect, auto-start)
#   - Cron tasks from HEARTBEAT.md (templated)
#
# Usage:
#   ./migrate.sh                          # defaults: ~/.openclaw
#   ./migrate.sh /path/to/.openclaw       # custom path
#   ./migrate.sh --dry-run                # preview without changes
#
# Requirements: claude (CLI), tmux, expect, python3, bun/npm
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
OPENCLAW_DIR="${1:-$HOME/.openclaw}"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$HOME/CLAUDE.md"
SERVICE_NAME="claude-telegram"
WRAPPER_PATH="/usr/local/bin/claude-telegram-wrapper.sh"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && OPENCLAW_DIR="$HOME/.openclaw"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

# ── Colors ──────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[!!]${N} $1"; }
err()  { echo -e "${R}[ERR]${N} $1"; }
info() { echo -e "${C}[..]${N} $1"; }
dry()  { $DRY_RUN && echo -e "${C}[DRY]${N} Would: $1" && return 0 || return 1; }

# ── Helpers ─────────────────────────────────────────────────────────────────
require() {
    local cmd="$1" msg="${2:-}"
    command -v "$cmd" &>/dev/null || { err "${msg:-$cmd not found}"; exit 1; }
}

oc_json() {
    python3 -c "
import json, sys
with open('$OPENCLAW_DIR/openclaw.json') as f:
    data = json.load(f)
$1
" 2>/dev/null
}

# ============================================================================
echo ""
echo "  openclaw-to-claude"
echo "  =================="
echo ""

# ── Preflight ───────────────────────────────────────────────────────────────
[ -d "$OPENCLAW_DIR" ]              || { err "OpenClaw dir not found: $OPENCLAW_DIR"; exit 1; }
[ -f "$OPENCLAW_DIR/openclaw.json" ] || { err "openclaw.json not found"; exit 1; }
[ -d "$CLAUDE_DIR" ]                || { err "~/.claude not found — run 'claude' once first"; exit 1; }
require claude "Claude Code CLI not found"
require python3

for pkg in tmux expect; do
    command -v "$pkg" &>/dev/null || {
        info "Installing $pkg..."
        dry "apt install $pkg" || apt-get install -y -qq "$pkg" &>/dev/null
    }
done

if ! command -v bun &>/dev/null; then
    info "Installing bun..."
    dry "install bun" || {
        curl -fsSL https://bun.sh/install | bash &>/dev/null
        [ -f "$HOME/.bun/bin/bun" ] && ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
    }
fi

WORKSPACE="$OPENCLAW_DIR/workspace"
MEMORY_DIR="$CLAUDE_DIR/projects/-root/memory"
SETTINGS="$CLAUDE_DIR/settings.json"
LOCAL_SETTINGS="$CLAUDE_DIR/settings.local.json"
BACKUP="$HOME/openclaw-backup-$(date +%Y%m%d-%H%M%S)"

ok "OpenClaw: $OPENCLAW_DIR"
ok "Claude Code: $CLAUDE_DIR"

# ============================================================================
# 1. STOP OPENCLAW
# ============================================================================
echo ""
echo "--- 1. Stop OpenClaw ---"

dry "stop OpenClaw" || {
    # systemd user service
    systemctl --user stop openclaw-gateway 2>/dev/null && ok "Stopped user service" || true
    systemctl --user disable openclaw-gateway 2>/dev/null && ok "Disabled user service" || true

    # systemd system service
    systemctl stop openclaw-gateway 2>/dev/null && ok "Stopped system service" || true
    systemctl disable openclaw-gateway 2>/dev/null && ok "Disabled system service" || true

    # Process
    pkill -f "openclaw-gateway" 2>/dev/null && { sleep 2; ok "Killed process"; } || true

    # Disable telegram in openclaw config
    oc_json "
oc = data
if oc.get('channels', {}).get('telegram', {}).get('enabled'):
    oc['channels']['telegram']['enabled'] = False
    with open('$OPENCLAW_DIR/openclaw.json', 'w') as f:
        json.dump(oc, f, indent=2)
    print('  Disabled Telegram in openclaw.json')
" || true

    pgrep -f openclaw &>/dev/null && warn "OpenClaw still running" || ok "OpenClaw stopped"
}

# ============================================================================
# 2. BACKUP
# ============================================================================
echo ""
echo "--- 2. Backup ---"
dry "backup to $BACKUP" || {
    mkdir -p "$BACKUP"
    for f in "$SETTINGS" "$LOCAL_SETTINGS" "$CLAUDE_MD"; do
        cp "$f" "$BACKUP/" 2>/dev/null || true
    done
    cp -r "$MEMORY_DIR" "$BACKUP/memory" 2>/dev/null || true
    ok "Backup: $BACKUP"
}

# ============================================================================
# 3. ENV VARS + SETTINGS
# ============================================================================
echo ""
echo "--- 3. Settings ---"
[ -f "$SETTINGS" ] && [ "$(cat "$SETTINGS" 2>/dev/null)" != "{}" ] || echo '{}' > "$SETTINGS"

dry "merge env vars into settings.json" || python3 << PYEOF
import json, os

with open("$OPENCLAW_DIR/openclaw.json") as f: oc = json.load(f)
with open("$SETTINGS") as f: settings = json.load(f)

env = oc.get("env", {})
if env:
    settings["env"] = {**settings.get("env", {}), **env}
    print(f"  Env: {', '.join(env.keys())}")

tg_plugin = "$CLAUDE_DIR/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
if os.path.isdir(tg_plugin):
    settings.setdefault("mcpServers", {})["telegram"] = {
        "command": "bun",
        "args": ["run", "--cwd", tg_plugin, "--shell=bun", "--silent", "start"]
    }
    print("  MCP: telegram")

settings["theme"] = "dark"
settings["hasCompletedOnboarding"] = True

with open("$SETTINGS", "w") as f: json.dump(settings, f, indent=2)
PYEOF
ok "Settings done"

# ============================================================================
# 4. PERMISSIONS
# ============================================================================
echo ""
echo "--- 4. Permissions ---"
dry "set full permissions" || cat > "$LOCAL_SETTINGS" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit(*)",
      "Write(*)",
      "Read(*)",
      "Grep(*)",
      "Glob(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "mcp__*(*)"
    ]
  }
}
EOF
ok "Full permissions (no prompts)"

# ============================================================================
# 5. CLAUDE.md
# ============================================================================
echo ""
echo "--- 5. CLAUDE.md ---"
dry "generate CLAUDE.md" || python3 << 'PYEOF'
import os, re

ws = os.path.expanduser(os.environ.get("WORKSPACE", "~/.openclaw/workspace"))
out = os.path.expanduser(os.environ.get("CLAUDE_MD", "~/CLAUDE.md"))
sections = []

def read_ws(name):
    p = os.path.join(ws, name)
    return open(p).read() if os.path.isfile(p) else None

# Identity
txt = read_ws("IDENTITY.md")
if txt:
    body = '\n'.join(l for l in txt.strip().split('\n') if not l.startswith('# '))
    sections.append(f"## Identity\n{body}")

# Soul
txt = read_ws("SOUL.md")
if txt:
    for h in ["Core Truths", "Boundaries", "Vibe"]:
        m = re.search(rf'## {h}\n(.*?)(?=\n## |\Z)', txt, re.DOTALL)
        if m: sections.append(f"## {h}\n{m.group(1).strip()}")

# User
txt = read_ws("USER.md")
if txt:
    m = re.search(r'\*\*Notes:\*\*(.*?)(?:\n## |\Z)', txt, re.DOTALL)
    ctx = re.search(r'## Context\n(.*?)(?:\n## |\Z)', txt, re.DOTALL)
    parts = [x.group(1).strip() for x in [m, ctx] if x]
    if parts: sections.append("## User Context\n" + '\n'.join(parts))

# Tools (strip OpenClaw-specific subagent routing)
txt = read_ws("TOOLS.md")
if txt:
    body = '\n'.join(l for l in txt.strip().split('\n') if not l.startswith('# '))
    body = re.sub(r'### /sonnet.*?(?=\n### /|\n## |\Z)', '', body, flags=re.DOTALL)
    body = re.sub(r'### /codex.*?(?=\n### /|\n## |\Z)', '', body, flags=re.DOTALL)
    body = re.sub(r'### /open.*?(?=\n## |\Z)', '', body, flags=re.DOTALL)
    if body.strip(): sections.append(f"## Tools & Infrastructure\n{body.strip()}")

# Safety from AGENTS.md
txt = read_ws("AGENTS.md")
if txt:
    for h, label in [("Safety", "Safety Rules"), ("External vs Internal", "External vs Internal")]:
        m = re.search(rf'## {h}\n(.*?)(?=\n## )', txt, re.DOTALL)
        if m: sections.append(f"## {label}\n{m.group(1).strip()}")

# Memory reference
sections.append("""## Memory
Long-term memory is in `~/.claude/projects/-root/memory/`.
When context is needed, read files from that directory.
Index: `~/.claude/projects/-root/memory/MEMORY.md`""")

# Embed long-term memory directly
txt = read_ws("MEMORY.md")
if txt:
    body = '\n'.join(l for l in txt.strip().split('\n') if not l.startswith('# '))
    if body.strip(): sections.append(f"## Long-term Memory\n{body.strip()}")

with open(out, 'w') as f:
    f.write("# Claude Code — System Instructions\n\n")
    f.write('\n\n'.join(sections) + '\n')
print(f"  {out} ({len(sections)} sections)")
PYEOF

export WORKSPACE="$WORKSPACE" CLAUDE_MD="$CLAUDE_MD"
ok "CLAUDE.md done"

# ============================================================================
# 6. MEMORY
# ============================================================================
echo ""
echo "--- 6. Memory ---"
dry "migrate memory files" || {
    mkdir -p "$MEMORY_DIR"
    [ -f "$WORKSPACE/MEMORY.md" ] && {
        cp "$WORKSPACE/MEMORY.md" "$MEMORY_DIR/openclaw_longterm.md"
        export MEMORY_DIR
        python3 << 'PYEOF'
import re, os
md = os.environ["MEMORY_DIR"]
with open(os.path.join(md, "openclaw_longterm.md")) as f: c = f.read()
secs = re.split(r'\n## ', c)
idx = []
tmap = {'identity':'user','role':'user','preference':'user',
        'infrastructure':'reference','external':'reference','vpn':'reference',
        'domain':'reference','cloudflare':'reference',
        'rule':'feedback','seo':'feedback','policy':'feedback','model':'feedback'}
for s in secs[1:]:
    lines = s.strip().split('\n'); title = lines[0].strip()
    body = '\n'.join(lines[1:]).strip()
    if not body: continue
    fn = re.sub(r'[^a-zA-Z0-9_-]','_',title.lower().replace(' ','_'))
    fn = re.sub(r'_+','_',fn).strip('_')[:60] + '.md'
    mt = next((t for k,t in tmap.items() if k in title.lower()), "project")
    with open(os.path.join(md,fn),'w') as f:
        f.write(f"---\nname: {title}\ndescription: {title}\ntype: {mt}\n---\n\n{body}\n")
    idx.append(f"- [{title}]({fn}) — {body[:80].replace(chr(10),' ')}")
with open(os.path.join(md,"MEMORY.md"),'w') as f:
    f.write("# Memory Index\n\n" + '\n'.join(idx) + '\n')
print(f"  {len(idx)} memory files")
PYEOF
    }
    [ -d "$WORKSPACE/memory" ] && {
        mkdir -p "$MEMORY_DIR/daily"
        cp "$WORKSPACE/memory"/*.md "$MEMORY_DIR/daily/" 2>/dev/null || true
        ok "Daily memory copied"
    }
    [ -f "$WORKSPACE/HEARTBEAT.md" ] && {
        { echo -e "---\nname: Heartbeat & Reminders\ndescription: Scheduled checks\ntype: project\n---\n"
          cat "$WORKSPACE/HEARTBEAT.md"
        } > "$MEMORY_DIR/heartbeat_reminders.md"
        echo "- [Heartbeat](heartbeat_reminders.md) — Scheduled checks" >> "$MEMORY_DIR/MEMORY.md"
    }
}
ok "Memory done"

# ============================================================================
# 7. TELEGRAM
# ============================================================================
echo ""
echo "--- 7. Telegram ---"

TG_TOKEN=$(oc_json "print(data.get('channels',{}).get('telegram',{}).get('botToken',''))")
TG_ALLOW=$(python3 << PYEOF
import json, os, re
allow = []
cf = os.path.join("$OPENCLAW_DIR", "credentials", "telegram-default-allowFrom.json")
if os.path.isfile(cf):
    try:
        d = json.load(open(cf))
        allow = [str(x) for x in (d if isinstance(d,list) else d.get("allowFrom",d.get("ids",[])))]
    except: pass
if not allow:
    mf = os.path.join("$WORKSPACE", "MEMORY.md")
    if os.path.isfile(mf):
        allow = list(dict.fromkeys(re.findall(r'\x60(\d{6,15})\x60', open(mf).read())))[:10]
print(json.dumps(allow))
PYEOF
)

if [ -n "$TG_TOKEN" ] && [ "$TG_TOKEN" != "" ]; then
    TG_STATE="$CLAUDE_DIR/channels/telegram"
    dry "configure Telegram" || {
        mkdir -p "$TG_STATE/inbox" "$TG_STATE/approved" && chmod 700 "$TG_STATE"
        echo "TELEGRAM_BOT_TOKEN=$TG_TOKEN" > "$TG_STATE/.env" && chmod 600 "$TG_STATE/.env"
        python3 -c "
import json
with open('$TG_STATE/access.json','w') as f:
    json.dump({'dmPolicy':'allowlist','allowFrom':json.loads('$TG_ALLOW'),'groups':{},'pending':{}},f,indent=2)
" && chmod 600 "$TG_STATE/access.json"
        ok "Token + allowlist (${TG_TOKEN%%:*}...)"
    }

    # Install plugin + deps + disable permission relay
    dry "install Telegram plugin" || {
        claude plugins install telegram 2>/dev/null || true
        TG_PLUGIN="$CLAUDE_DIR/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
        [ -d "$TG_PLUGIN" ] && [ ! -d "$TG_PLUGIN/node_modules" ] && {
            (cd "$TG_PLUGIN" && bun install --silent 2>/dev/null || npm install --silent 2>/dev/null || true)
        }
        [ -f "$TG_PLUGIN/server.ts" ] && {
            sed -i "s|'claude/channel/permission': {},|// permission relay disabled|" "$TG_PLUGIN/server.ts" 2>/dev/null
            ok "Permission relay disabled"
        }
    }
else
    warn "No Telegram token found — skipping"
fi

# ============================================================================
# 8. SYSTEMD SERVICE
# ============================================================================
echo ""
echo "--- 8. Service ---"

CLAUDE_BIN="$(which claude)"

dry "create systemd service" || {
    # Wrapper: tmux + expect (Claude needs TTY; expect auto-accepts bypass warning)
    cat > "$WRAPPER_PATH" << 'WEOF'
#!/bin/bash
SESSION="claude-tg"
tmux kill-session -t "$SESSION" 2>/dev/null || true
sleep 1
exec tmux new-session -d -s "$SESSION" "expect -c '
set timeout 60
spawn env IS_SANDBOX=1 claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions
sleep 5
send -- \"\x1b\[B\"
sleep 1
send \"\r\"
interact
'"
WEOF
    chmod +x "$WRAPPER_PATH"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SEOF
[Unit]
Description=Claude Code with Telegram channel
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=root
WorkingDirectory=$HOME
Environment="HOME=$HOME"
Environment="PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.bun/bin"
Environment="IS_SANDBOX=1"
ExecStart=$WRAPPER_PATH
ExecStop=/usr/bin/tmux kill-session -t claude-tg
RemainAfterExit=yes
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
SEOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" --quiet 2>/dev/null
    ok "Service: $SERVICE_NAME"
}

# ============================================================================
# 9. CRON (from HEARTBEAT.md)
# ============================================================================
echo ""
echo "--- 9. Cron ---"

CRON_SCRIPT="$HOME/claude-healthcheck.sh"
dry "create cron script" || {
    cat > "$CRON_SCRIPT" << 'CEOF'
#!/bin/bash
# Claude Code health check runner
# Edit the prompts below to match your infrastructure.
# Each case runs claude -p with a task prompt.

CLAUDE="$(which claude 2>/dev/null || echo /usr/local/bin/claude)"
LOG="/var/log/claude-healthcheck.log"

run() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG"
    timeout 120 "$CLAUDE" -p "$1" --permission-mode dontAsk >> "$LOG" 2>&1 || true
}

case "${1:-help}" in
    # Add your own checks here. Examples:
    # health)  run "SSH to myserver, check nginx is running. Alert via Telegram if down." ;;
    # payment) run "Check if payment is due soon (see memory). Remind via Telegram." ;;
    # backup)  run "SSH to myserver, check last backup age. Alert if older than 24h." ;;
    help)
        echo "Usage: $0 <task>"
        echo "Edit this script to add your health check tasks."
        ;;
    *)
        run "$1"
        ;;
esac
CEOF
    chmod +x "$CRON_SCRIPT"
    ok "Cron script: $CRON_SCRIPT (edit to add your checks)"
}

# If HEARTBEAT.md has content, remind user to set up cron
[ -f "$WORKSPACE/HEARTBEAT.md" ] && {
    info "Found HEARTBEAT.md — review it and add cron entries:"
    echo "    crontab -e"
    echo "    # Example: */30 * * * * $CRON_SCRIPT health"
}

# ============================================================================
# START
# ============================================================================
echo ""
echo "--- Starting ---"

dry "start service" || {
    tmux kill-session -t claude-tg 2>/dev/null || true
    sleep 1
    systemctl start "$SERVICE_NAME"
    info "Waiting..."
    sleep 14

    if tmux has-session -t claude-tg 2>/dev/null; then
        ok "Claude Code is RUNNING"
        [ -n "${TG_TOKEN:-}" ] && {
            BOT=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getMe" | \
                  python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('username','?'))" 2>/dev/null)
            ok "Telegram: @$BOT"
        }
    else
        err "Failed to start. Debug: tmux attach -t claude-tg"
    fi
}

echo ""
echo "  Done!"
echo ""
echo "  Status:    systemctl status $SERVICE_NAME"
echo "  Logs:      tmux capture-pane -t claude-tg -p"
echo "  Attach:    tmux attach -t claude-tg"
echo "  Restart:   systemctl restart $SERVICE_NAME"
echo ""
