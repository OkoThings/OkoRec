# Third-party code

Shipped in this repository (headers only, unmodified):

| Path | From | Licence |
|---|---|---|
| `vendor/include/pipewire`, `vendor/include/spa` | PipeWire 1.4.2 | MIT |
| `vendor/include/ffnvcodec/nvEncodeAPI.h` | NVIDIA Video Codec SDK 12.1, via nv-codec-headers | MIT |
| `vendor/include/ffnvcodec/dynlink_cuda.h` | nv-codec-headers | MIT |

The NVENC header is pinned on purpose: `src/nvenc_abi.zig` lays out several of
its structures by hand (Zig cannot translate their bitfields) and asserts their
sizes and offsets against this exact version. `tools/abi_check.c` prints the
reference values.

Fetched at build time by the Zig package manager:

| Package | Licence |
|---|---|
| raylib 6.0 | zlib |

Loaded at run time, not distributed: libpipewire (MIT), libopus (BSD-3-Clause),
X11/GL client libraries, and NVIDIA's proprietary `libnvidia-encode` and
`libcuda`.
