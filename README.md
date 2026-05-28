# SIDsynth-MiST


A standalone MOS 6581/8580 (SID) synthesizer for the
[MiST](https://github.com/mist-devel) FPGA board. The SID sound chip is
borrowed from the [C64-MiSTer](https://github.com/MiSTer-devel/C64_MiSTer)
project and driven two ways at once:

- **MIDI synth** — MIDI notes arrive on the board's serial input (via
  opto-isolator), are parsed and voice-allocated in hardware, and play
  through a SID core in real time.
- **`.sidraw` playback** — a second SID core plays a tune baked into
  on-chip BRAM from a `.sidraw` register dump, in parallel with the live
  MIDI synth.


## Status

This build is an early bring-up. What works today:

- a baked-in SID melody played from BRAM by the `.sidraw` player;
- a **monophonic** MIDI synth — one SID voice, last-note priority;
- no MIDI CC handling (note on/off and pitch only).

Short-term goals:

- read `.sidraw` files from the SD card instead of baking one into BRAM;
- **polyphonic** voice allocation across the SID's voices;
- MIDI CC controls (filter, envelope, and other SID parameters).


## Layout

```
rtl/    SID core, MIDI front-end, .sidraw player, DC blocker, SDM DAC, top
fpga/   Quartus project (device, pins, PLL, SDC) + build.sh
hex/    baked .sidraw tune (BRAM init for the player)
sw/     sidraw-dump host tools (.sid -> .sidraw -> .wav)
```


## Build the FPGA core

Quartus II 13.1 is required; the build script runs it inside a Docker
image so no local install is needed:

```sh
cd fpga
./build.sh
```

Output lands in `fpga/build/`:

- `sidsynth_mist.rbf` — copy to your MiST SD card as `core.rbf` to run it.
- `sidsynth_mist.sof` — program over JTAG with
  `quartus_pgm -m jtag -o "p;build/sidsynth_mist.sof"`.


## Build the host tools

`sw/sidraw-dump/` builds a triplet of CLI tools (`sidraw-dump`,
`sidraw-play`, `sid-play`) that convert between `.sid`, the custom `.sidraw`
register-dump format, and `.wav`. They statically link vendored copies of
libsidplayfp + libresidfp, so the result is a self-contained binary:

```sh
cd sw/sidraw-dump
mkdir build && cd build
cmake ..
make -j
```


## Bake a different tune

The player reads its tune from `hex/test_tune.hex`. To swap it:

```sh
sidraw-dump your_tune.sid -o your_tune.sidraw
python sw/sidraw_to_hex.py your_tune.sidraw hex/test_tune.hex
```

then rebuild the FPGA core. Update `DEPTH`/`ADDR_WIDTH` on the `sidraw_rom`
instance in `rtl/sidsynth_top.sv` if the new dump exceeds the current ROM
size.


## License

The RTL in `rtl/` is licensed under the
[CERN-OHL-S v2](rtl/LICENSE.txt) (Strongly Reciprocal). The vendored
libsidplayfp and libresidfp sources under `sw/sidraw-dump/external/` are
GPL v2 and remain under their own licenses.

