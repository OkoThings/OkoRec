# Limitations and known problems

This file is meant to be complete and blunt. If you find a problem that is not
listed here, that is a bug in this file too; please open an issue.

OkoRec is version 0.1, a personal project. **It has been developed and run on
exactly one machine**: Debian 13, GNOME 48 on Wayland, one NVIDIA RTX 3080
(driver 595), one 1920x1080 240 Hz monitor in HDR mode. Everything below
"works" means "works there".

## Provenance

- Most of the code was written by an AI coding assistant (Claude) under the
  author's direction, over a few days. It has not been reviewed by anyone else.
- There are no automated tests. Verification so far is manual: clips are
  checked with ffprobe/ffmpeg, pictures compared against screenshots.

## Hardware and platform

- **NVIDIA only**, with the proprietary driver (NVENC + CUDA). No AMD, no
  Intel, no software encoder.
- x86-64 Linux only.
- Not tried on KDE, wlroots compositors or X11 sessions. KMS capture does not
  depend on the compositor in principle; the global shortcuts installer and
  the HDR assumptions below are GNOME-specific.
- Not tried on laptops with two GPUs or any multi-GPU machine. The first DRM
  card with an active plane is used.
- **One monitor.** With several, only the first active primary plane is
  recorded; there is no way to choose.
- **A resolution or mode change stops capture** and the program exits.
- Only 8-bit XRGB/ARGB scanout buffers have been seen. Games that scan out
  10-bit or floating-point buffers directly are untested and probably fail.
- Overlay planes are ignored. Anything the compositor puts on an overlay plane
  (some video players) would be missing from the recording. Not observed yet.

## Security

- KMS capture needs `okorec-kms` to carry `CAP_SYS_ADMIN`. **Any process that
  can open the DRM device (the user at the seat, members of `video`) can then
  read the screen through it without any consent dialog**, which defeats part
  of Wayland's screen-capture isolation for that user. The helper is small and
  only exports plane framebuffers, but it has not been audited.
- The alternative, `--portal`, uses the normal xdg-desktop-portal consent flow
  and needs no privilege, with the picture problems listed below.

## Picture

- HDR is converted to SDR by **hard clipping** at SDR white; highlights above
  it are lost. There is no tone mapping and no HDR10 output.
- SDR white is assumed to be 203 nits (GNOME's default); change it with
  `--sdr-white` if your compositor uses another level. It is not detected.
- HEVC 8-bit 4:2:0 only. No H.264 or AV1, so clips do not play in every
  browser or chat application. MKV only, no MP4.
- Whether NVENC's RGB to YUV conversion matches the BT.709 tag written in the
  stream has not been verified; colours match a screenshot to within about
  4/255 on greys, saturated colours were not measured.
- The mouse cursor is always recorded.
- Portal capture with `--zero-copy` is about 40 times too dark when the
  monitor is in HDR mode on GNOME 48 (the compositor hands out unconverted
  values). The default portal path (shared memory) is correct but slower.

## Timing

- Frames are sampled on a timer, **not synchronised to the display**. A game
  running at a rate that is not a multiple of the capture rate will show
  duplicated or skipped frames (judder).
- Every tick is encoded, even when nothing on screen changed, so an idle
  desktop still costs GPU encoder time (a few percent of one CPU core).
- At 120 and 240 fps about 2 % fewer frames than requested were delivered in a
  short test (118 and 234). Not investigated.
- Changing the rate while running does not reconfigure the encoder. Harmless
  in the constant-quality mode used, but the stream metadata keeps the old rate.
- At 240 fps the file's nominal frame rate reads 243.9 (timestamps have a
  0.1 ms resolution). Per-frame timestamps are right.
- In-game performance impact has only been looked at in two game menus
  (Valheim, Deadlock), not during play.

## Audio

- Desktop audio is the default output's monitor; the microphone is the
  default input. No device choice, no per-application capture.
- The microphone is a **separate track, not mixed** into the desktop audio.
  Players and sites that play only the first audio track (Discord, browsers,
  many phone players) will not play it; mix it in an editor or with ffmpeg
  (`-filter_complex amix`).
- A recording only gets a microphone track if the mic is on when the file
  starts. Switching it on mid-recording does not add it to that file;
  switching it off mid-recording leaves silence (a gap) in the track.
- The microphone is mono, 64 kb/s Opus in speech mode; no noise suppression,
  gain control or push-to-talk.
- **Audio/video sync has not been measured.** Audio is stamped with its
  arrival time, so a small constant offset is likely.
- Behaviour when the default output device changes while running is untested.
- The feedback sounds OkoRec plays are themselves captured: a replay saved
  within the buffer length of a previous save contains the "saved" sound.

## Replay buffer and recording

- The buffer lives in RAM and is bounded by time, not size. Thirty seconds of
  a busy 240 fps picture can take several hundred megabytes.
- The buffer length is fixed at start (`--seconds`) and its content is lost on
  exit or crash.
- A recording is only finalised (index, duration) on a clean stop. What
  players make of a file left behind by a crash or a kill has not been tested.
- A full disk or an unwritable directory during a recording has not been tested.

## Window and controls

- The window is an X11 client (through XWayland), fixed size, without HiDPI
  scaling. Fonts are looked up in a short list of hard-coded paths.
- Only the frame rate can be changed in the window; everything else is a
  command-line flag. There is no configuration file and no tray icon.
- Global shortcuts are installed for GNOME only. Elsewhere, bind
  `okorec save` and `okorec record` by hand.
- The feedback sounds need `pw-play` and the freedesktop sound theme at fixed
  paths; they are silently skipped otherwise.
- With the window open OkoRec used about 9 % of one CPU core against about
  4 % headless.

## Robustness

- Starting with the window failed once in about twenty runs
  (`EglMakeCurrentFailed`, a race with the window's own GL context). A retry
  was added; the cause is not understood.
- The process ends with `exit_group`, skipping exit handlers, because NVIDIA's
  libraries can hang in theirs.
- One instance per session.
- With `--portal`, the frame rate cannot be raised above the starting rate.

## Building and packaging

- **Builds with Zig 0.16 only.** Zig 0.17 removes `@cImport` and changes other
  APIs the code uses; the port has not been done.
- Several NVENC structures are laid out by hand against one specific header
  version (SDK 12.1, vendored). A different header must not be substituted
  without re-checking the offsets (`tools/abi_check.c`).
- A subset of raylib 6.0 (with its bundled GLFW) is vendored and compiled in;
  a system raylib cannot be used yet.
- A binary built after `zig build fetch-x11` carries a RUNPATH into the build
  directory. Release binaries must be built with system `-dev` packages.
- The `-Dsystem-libs` mode and the AUR package have only been built in an
  Arch container, never installed and run on a real Arch system.
