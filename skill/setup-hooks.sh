#!/bin/bash
# Claude Watch — Install global hooks so ALL Claude Code sessions stream to the bridge.
#
# Usage: ./setup-hooks.sh [port]
#   port: bridge server port (default: 7860)
#
# This writes HTTP hooks to ~/.claude/settings.json (global, all projects).
# To remove: ./setup-hooks.sh --remove

set -e

PORT="${1:-7860}"
BRIDGE_URL="http://127.0.0.1:${PORT}"
SETTINGS="$HOME/.claude/settings.json"

# ── Remove mode ──────────────────────────────────────────────────────────────
if [ "$1" = "--remove" ]; then
  if [ ! -f "$SETTINGS" ]; then
    echo "No settings file found at $SETTINGS"
    exit 0
  fi

  # Remove the hooks we added (identified by claude-watch URLs)
  python3 -c "
import json, sys

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
changed = False
for event in list(hooks.keys()):
    filtered = [
        entry for entry in hooks[event]
        if not any(
            h.get('url', '').startswith('http://127.0.0.1:') and '/hooks/' in h.get('url', '')
            for h in entry.get('hooks', [])
        )
    ]
    if len(filtered) != len(hooks[event]):
        changed = True
        if filtered:
            hooks[event] = filtered
        else:
            del hooks[event]

if changed:
    if not hooks:
        del settings['hooks']
    with open('$SETTINGS', 'w') as f:
        json.dump(settings, f, indent=2)
    print('Claude Watch hooks removed from $SETTINGS')
else:
    print('No Claude Watch hooks found.')
"
  exit 0
fi

# ── Install mode ─────────────────────────────────────────────────────────────

echo "Installing Claude Watch hooks..."
echo "  Bridge URL: ${BRIDGE_URL}"
echo "  Settings:   ${SETTINGS}"
echo ""

# Verify bridge is reachable
if curl -s --connect-timeout 2 "${BRIDGE_URL}/status" > /dev/null 2>&1; then
  echo "  Bridge status: RUNNING"
else
  echo "  Bridge status: NOT RUNNING (hooks will work once you start the bridge)"
fi

# Create settings file if it doesn't exist
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

# Merge hooks into existing settings using Python (preserves existing config)
python3 -c "
import json

BRIDGE = '${BRIDGE_URL}'

# The hooks we want to install
new_hooks = {
    'PostToolUse': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/tool-output',
            'timeout': 5
        }]
    }],
    'PreToolUse': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/tool-output',
            'timeout': 5
        }]
    }],
    'PermissionRequest': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/permission',
            'timeout': 600
        }]
    }],
    'Stop': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/stop',
            'timeout': 5
        }]
    }],
    'PostToolUseFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'timeout': 5
        }]
    }],
    'StopFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'timeout': 5
        }]
    }],
    'Notification': [{
        'matcher': 'idle_prompt|permission_prompt',
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/stop',
            'timeout': 5
        }]
    }]
}

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

existing_hooks = settings.get('hooks', {})

# Merge: add our hooks without removing user's existing hooks
for event, entries in new_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = []

    # Remove any old claude-watch hooks for this event
    existing_hooks[event] = [
        entry for entry in existing_hooks[event]
        if not any(
            h.get('url', '').startswith('http://127.0.0.1:') and '/hooks/' in h.get('url', '')
            for h in entry.get('hooks', [])
        )
    ]

    # Add our new hooks
    existing_hooks[event].extend(entries)

settings['hooks'] = existing_hooks

with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)

print('Hooks installed successfully!')
print()
print('Events hooked:')
for event in new_hooks:
    print(f'  • {event}')
"

echo ""
echo "Done! Every Claude Code session will now stream events to the bridge."
echo ""
echo "To start using:"
echo "  1. Run the bridge:  cd skill/bridge && node server.js"
echo "  2. Start any Claude Code session normally"
echo "  3. Watch events flow into the Claude Watch app"
echo ""
echo "To remove hooks:  ./setup-hooks.sh --remove"
