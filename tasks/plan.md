# okorec roadmap

GPU screen recorder with an instant-replay buffer, in Zig 0.16.
Target machine: GNOME 48 Wayland, RTX 3080 (driver 595), 1080p @ 240 Hz, HDR on.

Pipeline: portal ScreenCast (own D-Bus client) -> PipeWire stream -> GL texture
-> CUDA -> NVENC HEVC -> in-RAM replay ring -> own MKV muxer.

## M1 - headless core (done 2026-11-12)
- [x] Vendored headers (pipewire, spa, ffnvcodec), build.zig linking runtime .so
- [x] Pure-Zig D-Bus client + portal session with restore token (dialog once)
- [x] Pure-Zig SPA POD builder/reader, format negotiation incl. modifier fixation
- [x] Headless EGL + desktop GL on the NVIDIA device platform
- [x] CUDA bridge, NVENC HEVC (constant quality, no B-frames, time-forced IDR <= 2 s)
- [x] NVENC bitfield structs hand-written, offsets asserted (tools/abi_check.c)
- [x] Replay ring (GOP-aligned, refcounted snapshots so saving doesn't stall capture)
- [x] MKV muxer (cluster per GOP, Cues, duration)
- [x] `okorec`, `okorec save` (SIGUSR1 via pidfile), `okorec probe`
- [x] Verified: clip decodes with ffmpeg, frame matches the screen

## M2 - KMS capture (chosen 2026-11-12; in progress)
- [x] Raw DRM ioctls in Zig (src/kms.zig), no libdrm
- [x] Privileged helper okorec-kms (probe + serve over socketpair, fd passing),
      installed in ~/.local/bin with cap_sys_admin (pkexec setcap; redo if the helper changes)
- [x] KMS capture loop (default source): primary plane, timer-paced, skips unchanged frames
- [x] HDR scanout (8-bit XR24, BT.2020 PQ) -> sRGB shader; matches a screenshot within ~2/255
- [x] HDR auto-detection from the connector's HDR_OUTPUT_METADATA (re-checked every second)
- [x] Hardware cursor composited (cursor buffer mmap'd and uploaded; EGL import of it fails)
- [x] Portal path kept as `--portal [--zero-copy]`
- [x] Game test on the KMS path (2026-11-12): Deadlock menu and Valheim menu correct
      picture + cursor; Valheim clip 60.0 fps, every gap 16.7 ms, okorec ~4% of one core
- [x] Every tick is encoded (fb ids can't detect change: a 120 fps game sampled at 60
      shows the same id each time); frames stamped with their scheduled time
- [ ] Deadlock pacing under KMS was measured with the terminal in front, not the game;
      re-measure in a real match, and check 10-bit / FP16 scanout if a game uses it
- [ ] Idle desktop now costs a constant 60 encodes/s; consider a cheap change detector
- [ ] Verify RGB->YUV matrix NVENC really uses matches the BT.709 tag (colour bars)
- [ ] Highlights above SDR white are clipped; consider tone mapping or true HDR10 output

## M3 - raylib UI (done 2026-11-12)
- [x] raylib 6.0 dependency + X11 headers the nvrm-probe way (third_party/x11, `zig build fetch-x11`)
- [x] Window (src/ui.zig): state, buffer fill, fps, video/audio bitrate, audio meter,
      bitrate graph, Save replay / Start-Stop recording buttons, last event
- [x] Capture and audio on their own threads; UI + signals on the main thread; `--headless`
- [ ] Buttons were only exercised through the equivalent `okorec save` / `okorec record`, not clicked
- [ ] UI costs ~5% of a core on top of ~4% headless; look at raylib's frame wait / MSAA

## M4 - recording + hotkeys (done 2026-11-12)
- [x] Start/stop recording to disk (src/record.zig): writer thread follows the ring, GOP by GOP
- [x] `okorec record` (SIGUSR2) toggles; file finalised on stop and on quit
- [x] `zig build install-app`: ~/.local/bin/okorec, launcher, GNOME shortcuts
      Super+F10 = save replay, Super+F9 = record (Alt+F10 is GNOME's maximize)
- [x] Capture rate selectable in the window (30/60/120/144/240), live, remembered in ~/.local/state/okorec/fps; `okorec fps N` does the same from the CLI (SIGHUP)
- [x] Sound cues through pw-play (saved / recording started / failed), `--no-sound`
- [ ] Rate chips clicked by a human (only driven through `okorec fps` so far)
- [ ] Encoder still budgets for the start-up rate after a live change (harmless in constant-quality mode; reconfigure if a bitrate cap is ever added)
- [ ] Sound cue lands in the replay buffer (desktop audio monitor), so a second save within 30 s contains it
- [x] Desktop notification on save / record start / stop (own D-Bus client)
- [ ] Shortcuts not yet pressed by a human, in a game or otherwise

## M5 - audio (desktop audio done 2026-11-12)
- [x] Desktop audio via PipeWire sink monitor -> Opus 160 kb/s (libopus) -> MKV track 2
- [x] Verified: 5.0 s recording = 300 video frames + 250 Opus packets, decodes cleanly
- [ ] A/V sync not measured (audio is stamped by arrival time)
- [ ] Optional microphone track; choice of output device / per-app audio

## Later / ideas
- [ ] Handle resolution change mid-session (currently stops with an error)
- [ ] Pacing can drop the last damage frame before the screen goes static
- [ ] Clean teardown instead of exit_group (NVIDIA libs hang in exit handlers)
- [ ] Pure-Zig PipeWire client behind capture.zig; own RGB->NV12 shader; H.264/AV1
- [ ] systemd user unit / autostart

## M6: distribution

- [x] No hard-coded library path: searched, `-Dlibdir`, or `-Dsystem-libs` (pkg-config; tested with stub .pc files only)
- [x] Helper found next to the executable (then ~/.local/bin), actionable message when it lacks its capability, non-zero exit when capture dies
- [x] Second instance refused (pidfile + liveness check)
- [x] Font and sound fallbacks for Arch/Fedora paths (untested on those distros)
- [x] `zig build --prefix` installs bin/okorec, bin/okorec-kms, share/applications/okorec.desktop; `--version`
- [x] README.md, THIRD_PARTY.md, .gitignore
- [x] Renamed zrec -> OkoRec (`okorec`, `okorec-kms`); installed files, shortcuts, state and clips folder migrated
- [x] MIT LICENSE, local git repository
- [x] AUR draft in packaging/aur (okorec-git, pins Zig 0.16.0 because Arch ships 0.17 and raylib 6.0's build script needs 0.16); build steps pass in an Arch container, makepkg itself not run
- [x] GitHub: https://github.com/OkoThings/OkoRec (public; commits use the GitHub noreply address)
- [x] raylib compiled from a vendored 58-file subset by our own build.zig; no dependency, no download at build time
- [x] LIMITATIONS.md and TODO.md (public, deliberately exhaustive)
- [x] GPU init retried after one intermittent EglMakeCurrentFailed at start
- [ ] Publish the AUR package (needs the owner's AUR account and SSH key)
- [ ] Port to Zig 0.17: first errors are `@cImport` removed, `@typeInfo` struct field layout, `std.fmt.bufPrintZ` gone, build API (`pathFromRoot`, `b.args`); more will follow
- [ ] RUNPATH pointing at third_party/x11/lib when built with `fetch-x11` (build with system -dev packages for release binaries)
- [ ] Build against a system raylib (`-fsys=raylib`) for distros that forbid network fetches / bundled sources
- [ ] Try a build on Arch and Fedora (container), and on a second NVIDIA machine
- [ ] Encoder back ends other than NVENC (VAAPI) if this is to be useful beyond NVIDIA
- [ ] Multi-monitor, resolution change, 10-bit scanout formats
