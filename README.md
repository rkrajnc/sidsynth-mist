# SIDsynth-MiST


A standalone MOS 6581/8580 (SID) synthesizer for the
[MiST](https://github.com/mist-devel) FPGA board. The SID sound chip is
borrowed from the [C64-MiSTer](https://github.com/MiSTer-devel/C64_MiSTer)
project and driven two ways at once:

- **MIDI synth** — MIDI notes arrive on the board's serial input (via
  opto-isolator), are parsed and voice-allocated in hardware, and play
  through a SID core in real time.
- **`.sidraw` playback** — a second SID core plays a tune streamed from
  the SD card as a `.sidraw` register dump, picked from an on-screen OSD
  menu, in parallel with the live MIDI synth.


## Status

This build is an early bring-up. What works today:

- `.sidraw` tunes streamed from the SD card, selected via an OSD menu;
- a **monophonic** MIDI synth — one SID voice, last-note priority;
- no MIDI CC handling (note on/off and pitch only).

Short-term goals:

- **polyphonic** voice allocation across the SID's voices;
- MIDI CC controls (filter, envelope, and other SID parameters).


## Layout

```
rtl/    SID core, MIDI front-end, .sidraw player + SD reader, OSD/video,
        DC blocker, SDM DAC, top
fpga/   Quartus project (device, pins, PLLs, SDC) + build.sh
hex/    legacy .sidraw BRAM init (unused in this build; SD streaming only)
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


## Play tunes from the SD card

Tunes are loaded at runtime from the SD card — no rebuild needed. Convert a
`.sid` to the `.sidraw` register-dump format with the host tools and copy it
to a `SIDSYNTH` directory on the card:

```sh
sidraw-dump your_tune.sid -o your_tune.sidraw
cp your_tune.sidraw /path/to/sdcard/SIDSYNTH/
```

With the card inserted, press **F12** on the MiST to open the OSD menu and
pick a `.sidraw` file. `user_io` mounts the selection and `sidraw_sd_reader`
streams it on demand through a small FIFO into the `.sidraw` player — so tune
length is bounded by the SD card, not on-chip BRAM. Stock MiST firmware is
used; no custom firmware is required.


## Blog

Read more about what I'm working on my [blog](https://somuch.guru/category/fpga/sidsynth/).

## License

The RTL in `rtl/` is licensed under the
[CERN-OHL-S v2](rtl/LICENSE.txt) (Strongly Reciprocal). The vendored
libsidplayfp and libresidfp sources under `sw/sidraw-dump/external/` are
GPL v2 and remain under their own licenses.

