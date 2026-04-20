#!/usr/bin/env bash
#
# configure-bash.sh — Configure bash environment for the given user.
# Idempotent (safe to re-run). Called from setup.sh or run standalone.
#
# Patches Ubuntu's default .bashrc (uncommenting useful defaults, fixing
# TERM detection for Ghostty) and creates ~/.bash_aliases with a
# git-branch prompt and a minimal set of aliases.
#

set -euo pipefail

TARGET_USER="${1:-$(whoami)}"
TARGET_HOME=$(eval echo "~$TARGET_USER")
BASHRC="$TARGET_HOME/.bashrc"
BASH_ALIASES="$TARGET_HOME/.bash_aliases"

if [[ ! -f "$BASHRC" ]]; then
  echo "Error: $BASHRC not found" >&2
  exit 1
fi

echo "==> Configuring bash for $TARGET_USER..."

# ---------------------------------------------------------------------------
# 1. Patch .bashrc — fix TERM detection for Ghostty
# ---------------------------------------------------------------------------
# Ubuntu's default only matches xterm-color|*-256color, so xterm-ghostty
# doesn't get a colored prompt.

if ! grep -q 'xterm-ghostty' "$BASHRC"; then
  sed -i 's/xterm-color|\*-256color) color_prompt=yes;;/xterm-color|*-256color|xterm-ghostty) color_prompt=yes;;/' "$BASHRC"
  echo "    Added xterm-ghostty to TERM detection"
fi

# ---------------------------------------------------------------------------
# 2. Uncomment useful defaults in .bashrc
# ---------------------------------------------------------------------------

sed -i 's/^    #alias grep=/    alias grep=/' "$BASHRC"
sed -i 's/^    #alias fgrep=/    alias fgrep=/' "$BASHRC"
sed -i 's/^    #alias egrep=/    alias egrep=/' "$BASHRC"

sed -i 's/^#alias ll=/alias ll=/' "$BASHRC"
sed -i 's/^#alias la=/alias la=/' "$BASHRC"
sed -i 's/^#alias l=/alias l=/' "$BASHRC"

echo "    Enabled default color and ls aliases"

# ---------------------------------------------------------------------------
# 3. Increase history size
# ---------------------------------------------------------------------------

sed -i 's/^HISTSIZE=1000$/HISTSIZE=10000/' "$BASHRC"
sed -i 's/^HISTFILESIZE=2000$/HISTFILESIZE=20000/' "$BASHRC"

echo "    History set to 10000/20000"

# ---------------------------------------------------------------------------
# 4. Create ~/.bash_aliases
# ---------------------------------------------------------------------------

cat > "$BASH_ALIASES" <<'ALIASEOF'
# Managed by danny-vps-infra/configure-bash.sh — re-run the script to update.

alias g='git'

# Git branch in prompt (requires git package)
if [ -f /usr/lib/git-core/git-sh-prompt ]; then
  . /usr/lib/git-core/git-sh-prompt
fi

# Colored prompt with git branch + terminal title
case "$TERM" in
  xterm-color|*-256color|xterm-ghostty)
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(__git_ps1 " (%s)" 2>/dev/null)\[\033[00m\]\$ '
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
esac
ALIASEOF

chown "$TARGET_USER:$TARGET_USER" "$BASH_ALIASES"
echo "    Created ~/.bash_aliases (git prompt + aliases)"

echo "    Done"
