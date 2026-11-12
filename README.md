# OkoRec

A small GPU screen recorder for Linux with an instant-replay buffer
(ShadowPlay style), written in Zig.

OkoRec keeps the last N seconds of your screen and desktop audio in memory.
Press a key and they are written to an MKV file; press another to record
continuously until stopped. Frames stay on the GPU from scanout to encoder.

**Status: personal project, 0.1.** It has been developed and tested on one
machine: Debian 13, GNOME 48 (Wayland), one NVIDIA RTX 3080, one 1080p monitor.

## Requirements

- Linux on x86-64, an **NVIDIA GPU with the proprietary driver** (NVENC and
  CUDA are loaded at run time: `libnvidia-encode.so.1`, `libcuda.so.1`)
- PipeWire (`libpipewire-0.3.so.0`, and `pw-play` for the feedback sounds)
- libopus (`libopus.so.0`)
- X11 client libraries and libGL for the window (it runs through XWayland)
- Optional: the freedesktop sound theme, DejaVu or Liberation fonts

There is no AMD/Intel (VAAPI) encoder and no software fallback.

## Building

Zig 0.16 is required.

    zig build -Doptimize=ReleaseSafe

The PipeWire and NVENC headers are vendored, so no `-dev` packages are needed
for those. raylib (the window) is fetched by the Zig package manager and built
from source; it needs the X11 and GL development headers:

    sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl-dev

or, on Debian/Ubuntu without root, `zig build fetch-x11` unpacks them into
`third_party/x11`.

Build options:

| Option | Meaning |
|---|---|
| `-Dsystem-libs` | link libpipewire and libopus through pkg-config |
| `-Dlibdir=DIR` | where `libpipewire-0.3.so.0` and `libopus.so.0` are (default: searched) |
| `--prefix DIR` | install `bin/okorec`, `bin/okorec-kms`, `share/applications/okorec.desktop` |

## Installing

    zig build -Doptimize=ReleaseSafe --prefix ~/.local
    sudo setcap cap_sys_admin+ep ~/.local/bin/okorec-kms

`zig build install-app` installs `okorec` only (not the helper) and additionally
registers two GNOME shortcuts: Super+F10 saves the replay, Super+F9 starts and
stops recording. On other desktops, bind `okorec save` and `okorec record` yourself.

### The privileged helper

By default okorec reads the framebuffer the display is scanning out, straight
from the kernel (KMS). That is the only way to see the real HDR signal and it
costs nothing in the compositor, but the kernel only hands out framebuffer
handles to a process with `CAP_SYS_ADMIN`.

That privilege lives in `okorec-kms`, a separate small program (about 450 lines including its DRM code) with no libc
and no GPU libraries. It does one thing: export what the display planes are
showing, as DMA-BUFs, to the process that started it.

What this means for security: **any process that can open the DRM device
(the user at the seat, or members of the `video` group) can read the screen
through `okorec-kms`, without the portal's consent dialog.** If that is not
acceptable, do not grant the capability and run `okorec --portal`, which
captures through xdg-desktop-portal like any other Wayland recorder.

## Usage

    okorec                 run with the window
    okorec --headless      run without it
    okorec save            save the replay buffer of the running instance
    okorec record          start/stop recording in the running instance
    okorec fps 120         change the capture rate, live, and remember it
    okorec probe           check the GPU encode path
    okorec --help          all options

Clips go to `~/Videos/okorec`. Video is HEVC (constant quality), audio is Opus.

## Known limitations

- NVIDIA only; one monitor; the resolution must not change while running
- HDR displays are tone-mapped to SDR by clipping (no HDR10 output)
- Desktop audio only, no microphone track
- Portal capture with `--zero-copy` is too dark in HDR mode on GNOME 48

## Third-party code

See [THIRD_PARTY.md](THIRD_PARTY.md).

## Licence

MIT, see [LICENSE](LICENSE).
