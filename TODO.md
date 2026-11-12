# To do

Roughly in order of importance. See [LIMITATIONS.md](LIMITATIONS.md) for the
problems these address. `tasks/plan.md` is the development log.

## Correctness

- [ ] Measure audio/video sync and correct the offset
- [ ] Verify the RGB to YUV matrix against the BT.709 tag (colour bars)
- [ ] Understand the EGL start-up race instead of retrying
- [ ] Find out why 2 % of frames are missing at 120/240 fps
- [ ] Survive a resolution or mode change (rebuild the pipeline)
- [ ] Test crash-interrupted recordings; make them recoverable
- [ ] Handle disk-full and write errors visibly
- [ ] Automated tests for the pure parts (MKV muxer, D-Bus, POD, HEVC parsing, ring)

## Capture

- [ ] Pace capture on vblank / page flips instead of a free-running timer
- [ ] Skip encoding when the picture did not change
- [ ] Monitor selection and multi-monitor
- [ ] 10-bit and floating-point scanout formats
- [ ] Overlay planes
- [ ] Proper HDR tone mapping, and optional HDR10 (10-bit, PQ) output
- [ ] Detect the compositor's SDR white level

## Audio

- [ ] Microphone as a second track
- [ ] Keep OkoRec's own feedback sounds out of the capture
- [ ] Follow default-device changes (test, then fix)

## Encoders and formats

- [ ] VAAPI back end (AMD, Intel)
- [ ] H.264 and AV1 options; MP4 output
- [ ] Reconfigure the encoder on a live frame-rate change

## Program

- [ ] Configuration file; buffer length, quality and folder in the window
- [ ] Byte limit on the replay buffer
- [ ] Shortcuts on KDE and other desktops (global shortcuts portal)
- [ ] Reduce the window's CPU cost; HiDPI
- [ ] Audit and harden `okorec-kms` (restrict to the active session, drop the
      capability between requests if possible)

## Packaging

- [ ] Port to Zig 0.17 (`@cImport` to translate-c build steps, std API changes)
- [ ] Option to link a system raylib
- [ ] Publish the AUR package; test on a real Arch installation
- [ ] Try on Fedora, on KDE, on a second NVIDIA machine
- [ ] Tagged release with a prebuilt binary
