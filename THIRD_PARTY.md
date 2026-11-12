# Third-party code

Headers shipped in this repository (unmodified):

| Path | From | Licence |
|---|---|---|
| `vendor/include/pipewire`, `vendor/include/spa` | PipeWire 1.4.2 | MIT |
| `vendor/include/ffnvcodec/nvEncodeAPI.h` | NVIDIA Video Codec SDK 12.1, via nv-codec-headers | MIT |
| `vendor/include/ffnvcodec/dynlink_cuda.h` | nv-codec-headers | MIT |

The NVENC header is pinned on purpose: `src/nvenc_abi.zig` lays out several of
its structures by hand (Zig cannot translate their bitfields) and asserts their
sizes and offsets against this exact version. `tools/abi_check.c` prints the
reference values.

Compiled into the program (`vendor/raylib`, a 58-file subset of raylib 6.0,
unmodified, built from our own `build.zig`):

| Part | Licence |
|---|---|
| raylib (`rcore`, `rshapes`, `rtextures`, `rtext`, `rlgl`) | zlib |
| GLFW 3.4 (`src/external/glfw`) | zlib |
| stb_image, stb_image_resize2, stb_image_write, stb_truetype, stb_rect_pack, stb_perlin | MIT or public domain |
| glad (generated OpenGL loader) | MIT / Apache-2.0 (Khronos specifications) |
| qoi | MIT |
| sinfl, sdefl | MIT or public domain |
| rprand, rltexgpu | zlib |

Loaded at run time, not distributed: libpipewire (MIT), libopus (BSD-3-Clause),
X11/GL client libraries, and NVIDIA's proprietary `libnvidia-encode` and
`libcuda`.
