#!/usr/bin/env bash
# Decides what the live system shows: the unattended install when the kernel
# command line says so (harness), otherwise the installer full screen in cage.
set -u
if grep -q 'quotient.unattended' /proc/cmdline; then
  ANS=$(sed -n 's/.*quotient\.unattended=\([^ ]*\).*/\1/p' /proc/cmdline)
  [ "$ANS" = 1 ] || [ -z "$ANS" ] && ANS=/run/live/medium/quotient/answers.conf
  for _ in $(seq 1 30); do [ -r "$ANS" ] && break; sleep 1; done
  exec /usr/lib/quotient-os/quotient-os-install.sh "$ANS"
fi
export XDG_RUNTIME_DIR=/run/user/0; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 QT_QPA_PLATFORM=wayland QT_WAYLAND_DISABLE_WINDOWDECORATION=1
# Software rendering everywhere: the live layer carries no Mesa/LLVM (saves
# ~190 MB), and an installer window needs no GPU. Same path on every machine.
export WLR_RENDERER=pixman QT_QUICK_BACKEND=software
exec cage -- calamares -D6
