#!/usr/bin/env bash
set -euo pipefail

DOTFILES_PATH="$HOME/dotfiles"

echo "=== Claude Workspace Setup ==="

# 1. Symlink dotfiles (preserve original behavior)
find "$DOTFILES_PATH" -type f -path "$DOTFILES_PATH/.*" | while read df; do
  link=${df/$DOTFILES_PATH/$HOME}
  mkdir -p "$(dirname "$link")"
  ln -sf "$df" "$link"
done

# 2. Install core tools + headless display stack
# Note: firefox-esr is NOT available on Ubuntu 22.04 via apt.
# Playwright installs its own bundled Firefox, which is all we need.
sudo apt-get update -qq
sudo apt-get install -y -qq mosh tmux jq sqlite3 xvfb x11vnc ruby

# 3. Install dev tools for local WFA stack
# overmind: process manager for running Procfiles (used by tools/dev/Procfile)
if ! command -v overmind &>/dev/null; then
  gem install --user-install overmind 2>/dev/null || true
fi

# temporal CLI: interact with Temporal server (list/describe/show workflows)
if ! command -v temporal &>/dev/null; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
  curl -fsSL "https://temporal.download/cli/archive/latest?platform=linux&arch=${ARCH}" | tar xz -C "$HOME/.local/bin" temporal 2>/dev/null || true
fi

# grpcurl: gRPC debugging tool
if ! command -v grpcurl &>/dev/null; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
  GRPCURL_VER=$(curl -fsSL https://api.github.com/repos/fullstorydev/grpcurl/releases/latest 2>/dev/null | jq -r .tag_name | tr -d v)
  if [ -n "$GRPCURL_VER" ]; then
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VER}/grpcurl_${GRPCURL_VER}_linux_${ARCH}.tar.gz" | tar xz -C "$HOME/.local/bin" grpcurl 2>/dev/null || true
  fi
fi

# Fix bzl OIDC auth prompts that block service startup
if command -v ddtool &>/dev/null; then
  ddtool auth helpers install 2>/dev/null || true
fi

# 4. Install Node.js tools (Playwright MCP)
# Volta is pre-installed by the claude-code devcontainer feature
if command -v volta &>/dev/null; then
  volta install node@lts
fi
# Pre-install Playwright MCP and its Firefox browser
npx -y @anthropic-ai/mcp-playwright --version 2>/dev/null || true
npx -y playwright install firefox 2>/dev/null || true

# 5. Install Claude Code via native installer (takes PATH precedence over Volta version)
if [ ! -f "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# 6. Configure tmux
cp "$DOTFILES_PATH/.tmux.conf" "$HOME/.tmux.conf" 2>/dev/null || cat > "$HOME/.tmux.conf" << 'TMUX'
# Session persistence config for Claude workspaces
set -g mouse on
set -g history-limit 100000
set -g default-terminal "screen-256color"
set -g status-bg colour24
set -g status-fg white
set -g status-left '[#S] '
set -g status-right '%H:%M'

# Better prefix for nested sessions (local tmux uses C-b, remote uses C-a)
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Fix SSH agent on reattach
set -g update-environment "SSH_AUTH_SOCK SSH_CONNECTION DISPLAY"

# F12 toggle for nested tmux (send keys to inner vs outer)
bind -T root F12 \
  set prefix None \;\
  set key-table off \;\
  set status-style "bg=colour238" \;\
  refresh-client -S

bind -T off F12 \
  set -u prefix \;\
  set -u key-table \;\
  set -u status-style \;\
  refresh-client -S
TMUX

# 7. Create helper scripts
mkdir -p "$HOME/.local/bin"

# start-vnc: launches Xvfb + VNC for Playwright browser automation
cat > "$HOME/.local/bin/start-vnc" << 'VNC'
#!/bin/bash
# Start virtual display + VNC server for Playwright browser automation
# Connect from laptop: ssh -L 5900:localhost:5900 workspace-<name>
# Then open VNC viewer to localhost:5900
export DISPLAY=:99
Xvfb :99 -screen 0 1280x1024x24 &
sleep 1
x11vnc -display :99 -forever -nopw -listen localhost -rfbport 5900 &
echo "VNC server running on localhost:5900"
echo "Forward with: ssh -L 5900:localhost:5900 workspace-<name>"
echo "DISPLAY=:99 is set for Playwright"
VNC
chmod +x "$HOME/.local/bin/start-vnc"

# start-claude: launches Claude in a tmux session with VNC ready
cat > "$HOME/.local/bin/start-claude" << 'CLAUDE'
#!/bin/bash
# Start a Claude session with browser automation support
SESSION="${1:-claude}"
REPO_DIR="$HOME/dd/dd-source"

# Start VNC if not running
if ! pgrep -x Xvfb > /dev/null; then
  start-vnc
fi

export DISPLAY=:99

# Create or attach to tmux session
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux attach -t "$SESSION"
else
  tmux new-session -d -s "$SESSION" -c "$REPO_DIR"
  tmux send-keys -t "$SESSION" "export DISPLAY=:99 && claude" Enter
  tmux attach -t "$SESSION"
fi
CLAUDE
chmod +x "$HOME/.local/bin/start-claude"

# fixssh: fix SSH agent forwarding after tmux reattach
cat > "$HOME/.local/bin/fixssh" << 'FIXSSH'
#!/bin/bash
eval $(tmux show-env -s | grep '^SSH_')
echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
FIXSSH
chmod +x "$HOME/.local/bin/fixssh"

# 8. Add ~/.local/bin to PATH if not already
if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

# 9. Add credential status check to bashrc
if ! grep -q "_check_creds" "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" << 'CREDS'

# Credential status on shell start
_check_creds() {
  if ! ddtool auth github token >/dev/null 2>&1; then
    echo "Warning: GitHub auth may be expired. Run: ddtool auth github login --org DataDog"
  fi
}
_check_creds
CREDS
fi

# 10. Pre-configure Claude MCP servers
mkdir -p "$HOME/.claude"
# Only add MCP config if not already present (don't overwrite existing)
if [ ! -f "$HOME/.claude/mcp.json" ]; then
  cat > "$HOME/.claude/mcp.json" << 'MCP'
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@anthropic-ai/mcp-playwright", "--browser", "firefox"],
      "env": {
        "DISPLAY": ":99"
      }
    },
    "atlassian": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp"
    }
  }
}
MCP
fi

echo "=== Claude Workspace Setup Complete ==="
echo "Run 'start-claude' to begin a Claude session"
echo "Run 'start-vnc' for headless browser (then VNC in for SSO login)"
