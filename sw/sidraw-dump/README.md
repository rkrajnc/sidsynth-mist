# sidraw-dump (and friends)

Three CLI tools that share one CMake build, all linked against the same
libsidplayfp + libresidfp:

| Tool          | Input         | Output       | Engine                                             |
|---------------|---------------|--------------|----------------------------------------------------|
| `sidraw-dump` | `.sid`        | `.sidraw`    | libsidplayfp (full 6510 + replay) + register snapshot |
| `sidraw-play` | `.sidraw`     | `.wav`       | libresidfp directly (drives `write()` + `clock()`) |
| `sid-play`    | `.sid`        | `.wav`       | libsidplayfp full render (reference A/B)           |

The triplet is for both producing and ear-checking `.sidraw` files:

- `sid-play` renders a `.sid` through the canonical libsidplayfp path
- `sidraw-dump` captures the register-write stream from the same playback
  into a `.sidraw`
- `sidraw-play` decodes that `.sidraw` through libresidfp into audio

If the `sid-play` and `sidraw-play` outputs sound identical, the `.sidraw`
encoding is lossless w.r.t. the audible behaviour of the original tune.

The `.sidraw` format spec is in `doc/PLANNING.md` § ".sidraw format". The
on-FPGA player is `modules/sidraw_player/`.


## Build

Two build modes, controlled by a CMake option:

### Monolithic (default, recommended)

Builds libresidfp and libsidplayfp from the vendored sources under
`external/libresidfp-main/` and `external/libsidplayfp-master/` (next to this
README) and links them statically into a single self-contained binary. No system libsidplayfp
is required at runtime — only libc/libm/libstdc++ (and libstdc++ is also
statically linked).

Build-time requirements:

- C++17 compiler (g++ 9+ or clang++ 10+)
- CMake 3.16+
- autotools (autoconf, automake, libtool, pkg-config)
- `xa` (6502 cross-assembler) — needed by libsidplayfp to assemble its
  PSID driver stubs. On openSUSE: `sudo zypper install xa`. On
  Debian/Ubuntu: `sudo apt install xa65`. On macOS: `brew install xa`.

```sh
cd sw/sidraw-dump
mkdir build && cd build
cmake ..
make -j
```

Output: `build/sidraw-dump` (one binary, ~14 MB, portable across Linux x86_64
systems). Verify with `ldd build/sidraw-dump` — only libc, libm, ld-linux.

First build takes ~30-60 s because libresidfp + libsidplayfp are compiled from
scratch. Subsequent rebuilds of `sidraw-dump` itself are fast (the external
projects are stamp-cached).

### Dynamic (development iteration)

Links against the system libsidplayfp via pkg-config. Faster builds (no
libsidplayfp recompile), but the binary needs `libsidplayfp.so.7` installed at
runtime.

```sh
cd sw/sidraw-dump
mkdir build && cd build
cmake -DSIDRAW_MONOLITHIC=OFF ..
make -j
```


## Usage

### `sidraw-dump` — `.sid` → `.sidraw`

```
sidraw-dump <input.sid> -o <output.sidraw>
            [-s <subtune>]        subtune (1..N); default = tune's default
            [-t <seconds>]        playback duration; default = 180
            [-m cycle|frame|<hz>] timing mode; default = cycle. A numeric
                                  value picks a custom tick rate in Hz.
                                  cycle = CPU clock (~985 kHz PAL); frame =
                                  50 (PAL) / 60 (NTSC); <hz> = arbitrary.
            [-r pal|ntsc]         clock; default = tune's native
            [-v]                  print stats
```

### Picking a tick rate

For 30 s of Commando.sid on PAL, sample numbers:

| `-m` value | File size | Audible quality |
|---|---|---|
| `frame` (50 Hz) | 24 KB | off-beat for some sounds; wandering ±20 ms |
| `1000` (1 kHz)  | 26 KB | indistinguishable for typical tunes |
| `5000` (5 kHz)  | 32 KB | rock-solid, +10 ms constant offset |
| `cycle`         | 45 KB | rock-solid, -2 ms constant offset |

`cycle` is the most accurate; numeric rates 1000-5000 Hz are a good
balance for size-constrained distribution; `frame` is the smallest
but has audible timing artefacts on tunes with mid-frame writes (digi
samples, tight rhythm parts).

### `sidraw-play` — `.sidraw` → `.wav`

```
sidraw-play <input.sidraw> -o <output.wav>
            [-c 6581|8580]      SID chip model; default = 6581
            [-s <hz>]           output sample rate; default = 48000
            [-v]                print stats
```

### `sid-play` — `.sid` → `.wav`

```
sid-play <input.sid> -o <output.wav>
         [-s <subtune>]      subtune (1..N); default = tune's default
         [-t <seconds>]      playback duration; default = 180
         [-r <hz>]           output sample rate; default = 48000
         [-v]                print stats
```

### Roundtrip ear-check

```sh
# canonical render of the original .sid
sid-play sid/Commando.sid -o commando_direct.wav -t 10

# round-trip via the .sidraw format
sidraw-dump sid/Commando.sid -o commando.sidraw -t 10 -m frame
sidraw-play commando.sidraw -o commando_roundtrip.wav
```

A/B `commando_direct.wav` vs `commando_roundtrip.wav` in your audio
editor. They won't be sample-identical (frame-tick mode loses sub-frame
timing; cycle-accurate gets closer) but should sound substantively the
same.

### Modes

- `frame` — poll the SID register state once per PAL/NTSC video frame
  (50 Hz or 60 Hz). Tick rate in the output header is the frame frequency.
  Each `wait N` opcode means "wait N frames". Compact (~2-3 KB / s) but
  loses any sub-frame register write timing. Right choice for tunes whose
  player routine runs once per frame (the vast majority).
- `cycle` — poll once per C64 CPU cycle (~985 kHz PAL, ~1023 kHz NTSC).
  Tick rate in the output header is the CPU clock. Cycle-precise output;
  ~5-10× larger than frame mode. Needed for tunes that do mid-frame
  register writes (digi samples, custom split-screen effects).

### Examples

```sh
# 60-second frame-tick dump of Commando's title music
sidraw-dump sid/Commando.sid -o commando.sidraw -t 60 -m frame -v

# Cycle-accurate dump of the second subtune
sidraw-dump sid/Commando.sid -o commando_s2.sidraw -s 2 -m cycle -t 30

# Force NTSC clock (overrides tune's native PAL flag)
sidraw-dump sid/Commando.sid -o commando_ntsc.sidraw -r ntsc -m frame
```


## How it works

1. `SidTune` parses the input file (PSID/RSID/MUS).
2. A `sidplayfp` engine is configured with the `ReSIDfpBuilder` SID emulation
   backend.
3. The selected subtune is loaded and the player init-routine runs.
4. The main loop calls `player.play(N)` to advance the emulator by N cycles,
   then `player.getSidStatus(0, regs)` to snapshot the 32 SID registers. Any
   register that changed from the previous snapshot is emitted as a `.sidraw`
   write opcode (`0x00..0x18 dd`). Wait counts between write events are
   coalesced into the shortest wait opcode (`0x20`, `0x21`, or `0x22`).
5. After the configured duration, an `0xFF` end-of-stream byte is emitted and
   the 16-byte header (`SIDR` magic + version + flags + tick rate + body size)
   is prepended.

The SID has 32 register slots but only `$D400..$D418` are writable — readable
oscillator/envelope outputs (`$D419..$D41F`) are skipped.

Register writes that happen during one polling step but are then overwritten
within the same step are lost (only the final value is captured). For frame
mode this is by design (one register write per frame is typical); for cycle
mode this is impossible (no two writes can happen on the same cycle).


## Limitations / TODO

- HVSC song-length database support (auto-pick `-t` from the tune)
- ROM image support (some tunes need a Kernal/BASIC ROM image; not loaded
  here, so PSIDs that depend on ROM code will misbehave)
- Roundtrip validation tool (decode `.sidraw` back into register writes,
  feed to a reference residfp, compare audio with original) — documented in
  `doc/PLANNING.md` § "Validation strategy"
