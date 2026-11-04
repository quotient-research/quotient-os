# QuotientOS

A bootable ISO that turns a spare PC into a Quotient™ Mainframe. Write it to a USB stick, boot, answer four questions, claim from the Terminal app.

Plan and decisions: `docs/plans/2026-11-04-quotient-os.md` in the ecosystem repo (issue ecosystem#441).

## What it is

- **Base:** Ubuntu 26.04 LTS, minimal, built with `debootstrap`. Ubuntu's signed shim, GRUB and kernel, so Secure Boot works unchanged.
- **Installer:** Calamares, full screen in `cage`. The Quotient-specific work (`build/rootfs/usr/lib/quotient-os/postinstall.sh`) is one script shared with the unattended install the harness uses.
- **Installed system:** headless. NetworkManager, Avahi, SSH (owner account), ufw on, the MicroK8s snap seeded, `quotient-server-tools` bundled and installed on first boot with `/etc/quotient/install.conf` already written. A status console on tty1 shows the name, address, health and the setup link as a QR code.

## Build

On an Ubuntu 26.04 host with KVM (ep-ai):

```bash
sudo ./build/build-iso.sh --channel stable        # out/quotientos-<version>-stable-amd64.iso
sudo ./build/build-iso.sh --channel dev           # what we test
```

`--remaster --answers FILE --iso-out X` rebuilds only the ISO from the last build tree with an unattended answers file on the medium; GRUB then boots straight into the install.

## Test

```bash
./harness/run-remote.sh --channel dev --scenarios O1,O3            # full build + O1, O3 on ep-ai, detached
./harness/run-remote.sh --build keep-chroot --scenarios O2         # package/overlay change, then the GUI run
./harness/run-remote.sh --build none --scenarios O1                # the last ISO again
./harness/run-remote.sh --attach <stamp>                           # follow
./harness/run-remote.sh --collect <stamp>                          # logs and O2 screenshots → harness/logs/<stamp>/
```

`--build keep-chroot` reuses the debootstrap chroot (about 8 minutes); `from-boot` reuses the squashfs images (GRUB, EFI and answers only, about 2 minutes).

| | Scenario | Pass means |
|---|---|---|
| O1 | Unattended install into an empty LXD VM (3 vCPU / 4 GiB / 30 GiB, UEFI), reboot into the disk | Hostname set, owner can SSH, MicroK8s came from the seed, first boot installed the bundled package, `/api/health` 200, Setup code present, ufw on with 80 and SSH, console on tty1 and no getty, no telemetry packages, no live-layer files on disk, healthy again after a reboot |
| O3 | O1 with `security.secureboot=true` | The same, and the firmware reports Secure Boot on |
| O2 | The graphical installer in host QEMU (KVM, OVMF, virtio-vga, VNC on `127.0.0.1:5`), driven by keyboard with `vncdo`, a `vncsnapshot` screenshot of every page in the run's log directory | The install finishes through Calamares, the disk boots, and the O1 checks pass over SSH on `127.0.0.1:2222` |

Only one harness VM runs at a time on ep-ai (shared rule with the quotient-server install harness). O2 uses the host's own QEMU because LXD's build has no VNC; it needs `qemu-system-x86 ovmf vncsnapshot sshpass` and `pipx install vncdotool` on the host.

Pull requests run `lint.yml` (ShellCheck, YAML, package lists, unit files). The ISO itself is built on ep-ai, not in CI.

## Layout

```
build/build-iso.sh          the build
build/packages-base.txt     the installed system
build/packages-live.txt     the live layer (never installed)
build/rootfs/               overlay for the installed system (first boot, console, postinstall)
build/live/                 overlay for the live layer (installer service, engine, Calamares config + branding)
build/grub/                 ISO menu, its theme, and the EFI stub
console/                    the tty1 status console (Go, built into the image)
harness/                    os-harness.sh (on the LXD host), run-remote.sh, results/ (kept run logs)
```
