# openclaw-to-claude

Migrate from [OpenClaw](https://openclaw.io) to [Claude Code](https://claude.ai/code) in one command.

## What it does

| From (OpenClaw)              | To (Claude Code)                          |
|------------------------------|-------------------------------------------|
| `openclaw.json` env vars     | `~/.claude/settings.json`                 |
| `workspace/IDENTITY.md` etc  | `~/CLAUDE.md` (system prompt)             |
| `workspace/MEMORY.md`        | `~/.claude/projects/-root/memory/`        |
| `workspace/memory/*.md`      | `~/.claude/projects/-root/memory/daily/`  |
| Telegram bot config          | `~/.claude/channels/telegram/`            |
| Telegram channel plugin      | MCP server + systemd service              |
| `HEARTBEAT.md`               | Cron script template                      |

The script also:
- Stops and disables OpenClaw (systemd user/system services + process)
- Installs dependencies (tmux, expect, bun)
- Sets full permissions (no confirmation prompts)
- Creates a systemd service with auto-restart
- Disables the Telegram permission relay (no lock emoji in chat)

## Quick start

```bash
git clone [https://github.com/YOUR_USER/openclaw-to-claude.git](https://github.com/wolfhound1995/openclaw-to-claude-code-migration)
cd openclaw-to-claude
chmod +x migrate.sh
./migrate.sh
```

Custom OpenClaw path:
```bash
./migrate.sh /path/to/.openclaw
```

Preview without making changes:
```bash
./migrate.sh --dry-run
```

## Requirements

- [Claude Code CLI](https://claude.ai/code) installed and authenticated
- Python 3
- Root access (for systemd service)
- OpenClaw installation with `openclaw.json`

## After migration

```bash
# Check status
systemctl status claude-telegram

# View the Claude Code session
tmux attach -t claude-tg
# (detach: Ctrl+B, then D)

# Restart
systemctl restart claude-telegram

# View what Claude sees
cat ~/CLAUDE.md
```

## Cron health checks

The script creates `~/claude-healthcheck.sh` as a template. Edit it to add your own checks:

```bash
# Edit the script
nano ~/claude-healthcheck.sh

# Add to crontab
crontab -e
# Example: run health check every 30 minutes
# */30 * * * * /root/claude-healthcheck.sh "SSH to myserver, check nginx status"
```

## How the Telegram service works

```
systemd (claude-telegram.service)
  └─ tmux session (claude-tg)
      └─ expect (auto-accepts bypass warning)
          └─ claude --channels plugin:telegram --dangerously-skip-permissions
              └─ MCP: bun server.ts (Telegram bot long-polling)
```

- `IS_SANDBOX=1` allows `--dangerously-skip-permissions` from root
- `expect` auto-selects "Yes" on the one-time bypass warning
- `tmux` provides the TTY that Claude Code requires for channel mode
- systemd handles auto-start on boot and restart on failure

## File structure after migration

```
~/
├── CLAUDE.md                              # System prompt + embedded memory
├── claude-healthcheck.sh                  # Cron task runner (template)
└── .claude/
    ├── settings.json                      # Env vars, MCP servers, theme
    ├── settings.local.json                # Permissions (full access)
    ├── channels/telegram/
    │   ├── .env                           # Bot token
    │   ├── access.json                    # Allowlist + DM policy
    │   ├── inbox/                         # Downloaded attachments
    │   └── approved/                      # Pairing confirmations
    └── projects/-root/memory/
        ├── MEMORY.md                      # Index
        ├── openclaw_longterm.md           # Full OpenClaw memory
        ├── *.md                           # Individual memory files
        └── daily/                         # Daily logs
```

## Troubleshooting

**Bot doesn't respond:**
```bash
tmux capture-pane -t claude-tg -p    # see what Claude is doing
tmux attach -t claude-tg             # interactive debug
```

**Permission prompts in Telegram chat:**
The migration disables permission relay in the plugin. If it reappears after a plugin update:
```bash
sed -i "s|'claude/channel/permission': {},|// disabled|" \
  ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
systemctl restart claude-telegram
```

**OpenClaw keeps restarting:**
```bash
systemctl --user disable openclaw-gateway
systemctl disable openclaw-gateway
pkill -9 -f openclaw
```

## License

MIT
