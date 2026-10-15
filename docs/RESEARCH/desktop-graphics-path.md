# Getting a Linux desktop onto the iPad screen

_Learned 2026-10-15 (research session, Track B planning). Documented claims carry a source; the rest is
marked as inference. Nothing here has run on a device._

## Bottom line

No iOS project we could find documents an off-the-shelf "Linux desktop → shared buffer → native iOS
view" pipeline. iSH's documentation describes no supported X11/Wayland display path; UTM SE goes through
a *virtual graphics device* (SPICE/QXL, VirGL where the guest has a DRM device), which a non-jailbroken
iOS guest does not have. So the display path is ours to build, and the smallest version is:

**Xvfb for arm64 Linux → damage rectangles over a shared mapping → a Metal view**, with **XTest** for
input. [iSH README](https://github.com/ish-app/ish), [UTM display settings](https://docs.getutm.app/settings-qemu/devices/display/), [Xvfb manual](https://manpages.opensuse.org/Tumbleweed/xorg-x11-server/Xvfb.1.en.html)

## Why Xvfb and not the alternatives

| Option | Verdict | Source |
| --- | --- | --- |
| **Xvfb** | **Recommended first choice.** Its manual says it needs neither display hardware nor physical input devices; it can export its screen buffer as a shared-memory segment (`-shmem`) or as a memory-mapped file (`-fbdir`) in XWD layout. An arm64 build of the server target alone is the smallest thing that runs XFCE/LXQt unmodified. | [Xvfb manual](https://manpages.opensuse.org/Tumbleweed/xorg-x11-server/Xvfb.1.en.html), [Xorg server build notes](https://www.linuxfromscratch.org/blfs/view/stable/x/xorg-server.html) |
| Xorg + dummy driver | Works offscreen, but is more machinery for the same in-memory screen, and still needs a capture path ("dummy" does not mean pixels reach the app). | [dummy driver](https://github.com/ctaggart/xserver-xorg-video-dummy) |
| Xorg kdrive / Xfbdev | Xfbdev expects a real `/dev/fb`, which does not exist here; the KDrive notes call the family obsolete. | [KDrive notes](https://www.irif.fr/~jch/software/kdrive.html) |
| TinyX | Deliberately drops XKB and XInput — the two things a desktop needs. | [TinyX README](https://github.com/tinycorelinux/tinyx) |
| Xephyr | Nested server: needs a parent X display. | [Xorg build notes](https://www.linuxfromscratch.org/blfs/view/stable/x/xorg-server.html) |
| Xwayland | Not a server on its own; needs a compositor to live in. | [Weston manual](https://man.archlinux.org/man/weston.1.en) |
| Headless Weston / wlroots + Pixman | Software rendering works, but a headless output's buffers are **not displayed to anyone**: output capture/presentation is still ours to write, plus seat handling and Xwayland if X11 programs must run. More work, not less. | [wlroots headless API](https://wlroots.pages.freedesktop.org/wlroots/wlr/backend/headless.h.html), [Weston run guide](https://wayland.pages.freedesktop.org/weston/toc/running-weston.html) |

Desktop-environment note: LXQt documents Wayland sessions only from 2.1 and they need a chosen
compositor; XFCE's roadmap calls its Wayland support unfinished and notes `xfwm4` is X11-only. That is a
second reason the X11/Xvfb path is the low-risk one. [LXQt Wayland](https://lxqt-project.org/wiki/Wayland-Session.html), [XFCE Wayland roadmap](https://wiki.xfce.org/releng/wayland_roadmap)

## Cost: do not copy whole frames

At 2360×1640 with 32-bit pixels, one frame is 2360 × 1640 × 4 = **15,481,600 bytes ≈ 14.8 MiB**. Two
buffers ≈ 29.5 MiB; a full-frame copy at 30 fps is ≈ 443 MiB/s in one direction (double that if every
frame is read *and* written). Idle desktops are cheap; scrolling, animations, translucency and video are
not, and software rendering makes every redraw CPU work as well. (Arithmetic, not a measurement.)

So the bridge must be damage-driven: the X **Damage** extension reports changes to drawables, including
the root window and subwindows, and a bridge can coalesce the rectangles and update only those regions.
Two cautions: writes made directly into a shared-memory pixmap do not raise normal damage events (the
manual documents `DamageAdd` for that case), and `Xvfb -shmem` (screen export) is a different thing from
the **MIT-SHM** extension (moving image payloads between a client and the server) — neither one
publishes pixels to iOS by itself. [X Damage](https://manpages.ubuntu.com/manpages/noble/man3/X11%3A%3AProtocol%3A%3AExt%3ADAMAGE.3pm.html), [MIT-SHM](https://man.archlinux.org/man/extra/perl-x11-protocol-other/X11%3A%3AProtocol%3A%3AExt%3AMIT_SHM.3pm.en)

Practical mitigations (inference): start with a smaller scaler framebuffer than the panel and scale on
the Metal side; turn the XFCE compositor off; cap the update rate; never republish an unchanged region.

## Input without evdev or uinput

- **X11: XTest.** `XTestFakeKeyEvent`, `XTestFakeButtonEvent`, `XTestFakeMotionEvent` ask the X server to
  synthesise input — a protocol request, so it works with no device nodes at all. [XTest](https://man.archlinux.org/man/extra/libxtst/XTestFakeKeyEvent.3.en)
- **Wayland:** the virtual-keyboard protocol and wlroots' virtual-pointer protocol, if that path is ever
  taken. [virtual keyboard](https://wayland.app/protocols/virtual-keyboard-unstable-v1), [wlroots virtual pointer](https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1)
- **Do not plan on `/dev/uinput`**: it is a kernel device that our guest environment will not have.
  [Linux uinput](https://docs.kernel.org/input/uinput.html)

## The prerequisite that is easy to miss

Building arm64 Linux binaries is not the same as providing a Linux environment: Xvfb and every desktop
service need a working system-call surface — Unix sockets, shared memory, `poll`/`epoll`, signals,
mmap of files, `ioctl` on a terminal. The desktop is therefore gated on B5/B6 (rootfs, dynamic linking,
`/proc`, `/dev`, pty, sockets) and is planned after them, not before.
