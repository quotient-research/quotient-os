#!/usr/bin/env bash
# The Mainframe's screen: name, address, health and, until it is claimed, the
# setup link as a QR code. Any key opens a normal login. Replaces getty on tty1.
# Spike version in bash; the Go version comes with phase 2.
set -u
export TERM=linux
G=$'\033[1;32m'; D=$'\033[2m'; B=$'\033[1m'; R=$'\033[0m'

addresses() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}' | sed 's|/[0-9]*$||'
}

status_line() {
  if [ -x /usr/bin/quotient ]; then
    if quotient status >/tmp/.qstatus 2>/dev/null; then
      grep -i -m1 -E "healthy|running|ok" /tmp/.qstatus >/dev/null && echo "healthy" || echo "starting"
    else
      echo "starting"
    fi
  elif [ -e /var/lib/quotient-os/.firstboot-done ]; then
    echo "starting"
  else
    echo "first boot: installing the Mainframe package"
  fi
}

setup_link() {
  [ -x /usr/bin/quotient ] || return 0
  quotient setup-code 2>/dev/null | grep -o 'http://[^ ]*' | head -1
}

draw() {
  clear
  local name; name=$(hostname)
  printf '\n  %s%s%s\n' "$G" "Quotient Mainframe" "$R"
  printf '  %s%s%s\n\n' "$B" "$name" "$R"
  printf '  %sAddress%s\n' "$D" "$R"
  addresses | sed 's/^/    /'
  printf '\n  %sStatus%s\n    %s\n' "$D" "$R" "$(status_line)"
  local link; link=$(setup_link)
  if [ -n "$link" ]; then
    printf '\n  %sNot claimed yet.%s Open the Terminal app on your phone and scan this,\n  or open the link on a computer on the same network:\n\n' "$B" "$R"
    printf '    %s\n\n' "$link"
    command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$link" | sed 's/^/    /'
  else
    printf '\n  Open the Terminal app on your phone to use your Mainframe.\n'
  fi
  printf '\n  %s%s · press any key to sign in%s\n' "$D" "$(cat /etc/quotient-os-release 2>/dev/null)" "$R"
}

while true; do
  draw
  if read -r -s -n 1 -t 15 _; then
    clear
    exec /bin/login
  fi
done
