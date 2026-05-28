// sidraw-dump: convert a PSID/RSID file to the SIDsynth .sidraw register-write
// stream format (see doc/PLANNING.md for the v1 spec).
//
// libsidplayfp drives the 6510 + replay; after every emulated chunk we
// snapshot the SID register state via sidplayfp::getSidStatus() and emit
// `.sidraw` opcodes for any registers that changed since the last
// snapshot. Two timing modes:
//
//   frame   poll once per PAL/NTSC video frame; tick rate = 50 or 60 Hz.
//   cycle   poll once per C64 CPU cycle; tick rate = ~985248 (PAL) or
//           ~1022730 (NTSC) Hz. Slow but cycle-precise.
//
// Output format (16-byte header, then opcode stream):
//   header  "SIDR" version=1 flags reserved tick_rate body_size
//   opcodes 0x00..0x18  = write to $D400+opcode
//           0x20 nn     = wait nn ticks (1..255)
//           0x21 lo hi  = wait nn nn ticks
//           0x22 ll lh hl hh = wait 32-bit ticks
//           0xFF        = end of stream
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstddef>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidInfo.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/builders/residfp.h>

namespace {

// .sidraw v1 constants
constexpr std::size_t HEADER_BYTES = 16;
constexpr std::uint8_t MAGIC[4]    = { 'S', 'I', 'D', 'R' };  // file order
constexpr std::uint8_t FORMAT_VERSION = 1;

constexpr std::uint8_t OP_WAIT_8   = 0x20;
constexpr std::uint8_t OP_WAIT_16  = 0x21;
constexpr std::uint8_t OP_WAIT_32  = 0x22;
constexpr std::uint8_t OP_END      = 0xFF;

// only registers $00..$18 are writable on the SID; readable-only oscillator
// outputs ($19..$1F) never need a write command. We skip those.
constexpr int SID_WRITABLE_REGS = 0x19;

// C64 master clock rates (Hz, integer cycles per second)
constexpr std::uint32_t CLOCK_PAL_HZ  = 985248;
constexpr std::uint32_t CLOCK_NTSC_HZ = 1022730;

// frame rates
constexpr std::uint32_t FRAME_PAL_HZ  = 50;
constexpr std::uint32_t FRAME_NTSC_HZ = 60;

enum class Mode  { Cycle, Frame, Custom };
enum class Clock { Pal, Ntsc, Native };

struct Args {
  std::string  input;
  std::string  output;
  int          subtune  = 0;       // 0 = use tune's default
  int          seconds  = 180;
  Mode         mode     = Mode::Cycle;
  std::uint32_t custom_hz = 0;     // used when mode == Custom
  Clock        clock     = Clock::Native;
  bool         verbose  = false;
};

void usage(const char* prog) {
  std::fprintf(stderr,
    "usage: %s <input.sid> -o <output.sidraw>\n"
    "             [-s <subtune>]      subtune number (1..N); default = tune's default\n"
    "             [-t <seconds>]      playback duration in seconds; default = 180\n"
    "             [-m cycle|frame|<hz>] mode; default = cycle. A numeric value\n"
    "                                 picks a custom tick rate in Hz (e.g. -m 5000\n"
    "                                 for 5 kHz sub-frame ticks: ~0.2 ms precision,\n"
    "                                 between frame-tick compactness and cycle\n"
    "                                 accuracy. Aliases: cycle = CPU clock,\n"
    "                                 frame = 50 (PAL) / 60 (NTSC)\n"
    "             [-r pal|ntsc]       clock; default = tune's native\n"
    "             [-v]                verbose stats\n",
    prog);
}

bool parse_args(int argc, char** argv, Args& out) {
  if (argc < 2) return false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](const char* flag) -> const char* {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "error: %s requires a value\n", flag);
        return nullptr;
      }
      return argv[++i];
    };
    if (a == "-o") {
      const char* v = need("-o"); if (!v) return false;
      out.output = v;
    } else if (a == "-s") {
      const char* v = need("-s"); if (!v) return false;
      out.subtune = std::atoi(v);
    } else if (a == "-t") {
      const char* v = need("-t"); if (!v) return false;
      out.seconds = std::atoi(v);
      if (out.seconds <= 0) { std::fprintf(stderr, "error: -t must be positive\n"); return false; }
    } else if (a == "-m") {
      const char* v = need("-m"); if (!v) return false;
      std::string s = v;
      if (s == "cycle") out.mode = Mode::Cycle;
      else if (s == "frame") out.mode = Mode::Frame;
      else if (!s.empty() && std::all_of(s.begin(), s.end(),
                  [](char c){ return c >= '0' && c <= '9'; })) {
        int hz = std::atoi(v);
        if (hz < 1) {
          std::fprintf(stderr, "error: -m <hz> must be positive, got %s\n", v); return false;
        }
        out.mode      = Mode::Custom;
        out.custom_hz = static_cast<std::uint32_t>(hz);
      }
      else { std::fprintf(stderr, "error: -m must be cycle|frame|<hz>, got %s\n", v); return false; }
    } else if (a == "-r") {
      const char* v = need("-r"); if (!v) return false;
      std::string s = v;
      if (s == "pal") out.clock = Clock::Pal;
      else if (s == "ntsc") out.clock = Clock::Ntsc;
      else { std::fprintf(stderr, "error: -r must be pal|ntsc, got %s\n", v); return false; }
    } else if (a == "-v") {
      out.verbose = true;
    } else if (a == "-h" || a == "--help") {
      return false;
    } else if (!a.empty() && a[0] == '-') {
      std::fprintf(stderr, "error: unknown flag %s\n", a.c_str());
      return false;
    } else if (out.input.empty()) {
      out.input = a;
    } else {
      std::fprintf(stderr, "error: unexpected positional arg %s\n", a.c_str());
      return false;
    }
  }
  return !out.input.empty() && !out.output.empty();
}

// emit one .sidraw `wait` command using the shortest opcode for the count
void emit_wait(std::vector<std::uint8_t>& body, std::uint64_t ticks) {
  while (ticks > 0) {
    if (ticks <= 0xFF) {
      body.push_back(OP_WAIT_8);
      body.push_back(static_cast<std::uint8_t>(ticks));
      ticks = 0;
    } else if (ticks <= 0xFFFF) {
      body.push_back(OP_WAIT_16);
      body.push_back(static_cast<std::uint8_t>(ticks & 0xFF));
      body.push_back(static_cast<std::uint8_t>((ticks >> 8) & 0xFF));
      ticks = 0;
    } else if (ticks <= 0xFFFFFFFFULL) {
      body.push_back(OP_WAIT_32);
      body.push_back(static_cast<std::uint8_t>(ticks & 0xFF));
      body.push_back(static_cast<std::uint8_t>((ticks >> 8) & 0xFF));
      body.push_back(static_cast<std::uint8_t>((ticks >> 16) & 0xFF));
      body.push_back(static_cast<std::uint8_t>((ticks >> 24) & 0xFF));
      ticks = 0;
    } else {
      // chain 32-bit waits for the (vanishingly rare) >4e9-tick case
      body.push_back(OP_WAIT_32);
      body.push_back(0xFF); body.push_back(0xFF); body.push_back(0xFF); body.push_back(0xFF);
      ticks -= 0xFFFFFFFFULL;
    }
  }
}

void emit_write(std::vector<std::uint8_t>& body, int reg, std::uint8_t value) {
  body.push_back(static_cast<std::uint8_t>(reg));
  body.push_back(value);
}

void write_le32(std::uint8_t* dst, std::uint32_t v) {
  dst[0] = static_cast<std::uint8_t>(v & 0xFF);
  dst[1] = static_cast<std::uint8_t>((v >> 8) & 0xFF);
  dst[2] = static_cast<std::uint8_t>((v >> 16) & 0xFF);
  dst[3] = static_cast<std::uint8_t>((v >> 24) & 0xFF);
}

}  // namespace


int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) {
    usage(argv[0]);
    return 1;
  }

  // load tune
  SidTune tune(args.input.c_str());
  if (!tune.getStatus()) {
    std::fprintf(stderr, "error: failed to load %s: %s\n",
                 args.input.c_str(), tune.statusString());
    return 2;
  }

  // pick subtune (0 = tune default, 1..N otherwise)
  unsigned int song = tune.selectSong(static_cast<unsigned int>(args.subtune));
  const SidTuneInfo* tinfo = tune.getInfo();
  if (!tinfo) {
    std::fprintf(stderr, "error: SidTuneInfo unavailable\n");
    return 2;
  }

  // resolve clock (PAL/NTSC) — either forced by -r or taken from the tune
  bool is_pal = true;
  if (args.clock == Clock::Pal) {
    is_pal = true;
  } else if (args.clock == Clock::Ntsc) {
    is_pal = false;
  } else {
    // tune's native: PAL_CLOCK or NTSC_CLOCK from SidTuneInfo::clockSpeed()
    is_pal = (tinfo->clockSpeed() != SidTuneInfo::CLOCK_NTSC);
  }
  const std::uint32_t cpu_clock = is_pal ? CLOCK_PAL_HZ : CLOCK_NTSC_HZ;
  const std::uint32_t frame_hz  = is_pal ? FRAME_PAL_HZ : FRAME_NTSC_HZ;

  // configure player
  sidplayfp player;
  ReSIDfpBuilder rs("residfp");

  SidConfig cfg = player.config();
  cfg.frequency        = 48000;
  cfg.samplingMethod   = SidConfig::INTERPOLATE;
  cfg.sidEmulation     = &rs;
  cfg.defaultC64Model  = is_pal ? SidConfig::PAL : SidConfig::NTSC;
  cfg.forceC64Model    = (args.clock != Clock::Native);
  if (!player.config(cfg)) {
    std::fprintf(stderr, "error: player.config(): %s\n", player.error());
    return 3;
  }

  // initMixer must be called before play() in 3.x; we never read the mixed
  // buffer but the call is required for the player to advance the SID emu.
  player.initMixer(false);

  if (!player.load(&tune)) {
    std::fprintf(stderr, "error: player.load(): %s\n", player.error());
    return 3;
  }

  // tick-rate setup
  std::uint32_t tick_rate_hz =
      (args.mode == Mode::Cycle) ? cpu_clock :
      (args.mode == Mode::Frame) ? frame_hz  :
      args.custom_hz;
  if (tick_rate_hz > cpu_clock) {
    std::fprintf(stderr, "error: -m %u Hz exceeds CPU clock %u Hz; pick <= CPU\n",
                 tick_rate_hz, cpu_clock);
    return 1;
  }
  const std::uint32_t cycles_per_tick = cpu_clock / tick_rate_hz;
  const std::uint64_t total_ticks     =
      static_cast<std::uint64_t>(args.seconds) * tick_rate_hz;

  // body buffer (the opcode stream). Heuristic reserve: 4 bytes/tick worst
  // case in cycle mode is too pessimistic — typical SID writes ~25 regs per
  // 50 Hz frame = 50 B/frame = ~3 KB/s. Reserve generously for frame mode,
  // grow on demand for cycle mode.
  std::vector<std::uint8_t> body;
  body.reserve(args.mode == Mode::Frame ? 64 * 1024 : 1024 * 1024);

  std::uint8_t prev_regs[32] = {0};
  std::uint8_t curr_regs[32] = {0};
  std::uint64_t last_write_cycle = 0;
  std::uint64_t total_writes     = 0;
  // start_cycle is captured after load() (libsidplayfp's reset has run)
  // so cycle 0 in our output stream corresponds to the first emulated
  // 6510 cycle. currentCycle() returns the EventScheduler PHI1 time
  // exposed by our libsidplayfp patch.
  // currentCycle() is non-const because libsidplayfp's underlying
  // EventScheduler getter isn't const; we hold `player` by value so a
  // local lambda capture by ref is fine.
  auto cycle = [&]() -> std::uint64_t { return player.currentCycle(); };
  const std::uint64_t start_cycle = cycle();

  if (args.verbose) {
    std::fprintf(stderr,
      "input    : %s\n"
      "output   : %s\n"
      "mode     : %s\n"
      "clock    : %s (%u Hz CPU, %u Hz frame)\n"
      "subtune  : %u of %u\n"
      "duration : %d s\n"
      "ticks    : %llu (%u Hz, %u cycles/tick)\n",
      args.input.c_str(), args.output.c_str(),
      args.mode == Mode::Cycle ? "cycle" :
      args.mode == Mode::Frame ? "frame" : "custom",
      is_pal ? "PAL" : "NTSC", cpu_clock, frame_hz,
      song, tinfo->songs(),
      args.seconds,
      static_cast<unsigned long long>(total_ticks), tick_rate_hz, cycles_per_tick);
  }

  // Drive the emulator with play(1) (one event at a time) but use
  // player.currentCycle() to read the actual PHI1 cycle counter from
  // libsidplayfp's EventScheduler. This decouples "event index" from
  // "wall-cycle index" -- multiple events at the same cycle (e.g. CPU
  // + CIA + VIC all firing on an IRQ entry cycle) no longer inflate
  // our tick count. Loop terminates when the cycle counter reaches
  // the target.
  const std::uint64_t target_cycles =
      static_cast<std::uint64_t>(args.seconds) * cpu_clock;
  const std::uint64_t target_cycle  = start_cycle + target_cycles;

  while (player.currentCycle() < target_cycle) {
    int produced = player.play(1);
    if (produced < 0) {
      std::fprintf(stderr, "error: player.play(): %s\n", player.error());
      return 4;
    }
    short* bufs[16] = {nullptr};
    player.buffers(bufs);

    if (!player.getSidStatus(0, curr_regs)) {
      std::fprintf(stderr, "error: getSidStatus failed\n");
      return 4;
    }

    bool any_change = false;
    for (int r = 0; r < SID_WRITABLE_REGS; ++r) {
      if (curr_regs[r] != prev_regs[r]) { any_change = true; break; }
    }
    if (any_change) {
      // quantize the write to the nearest tick boundary in the chosen
      // tick rate. cycle mode has cycles_per_tick = 1 → no quantization.
      const std::uint64_t now_cycle   = player.currentCycle() - start_cycle;
      const std::uint64_t now_tick    = now_cycle / cycles_per_tick;
      const std::uint64_t last_tick   = last_write_cycle / cycles_per_tick;
      const std::uint64_t wait_ticks  = now_tick - last_tick;
      if (wait_ticks > 0) emit_wait(body, wait_ticks);
      for (int r = 0; r < SID_WRITABLE_REGS; ++r) {
        if (curr_regs[r] != prev_regs[r]) {
          emit_write(body, r, curr_regs[r]);
          prev_regs[r] = curr_regs[r];
          ++total_writes;
        }
      }
      // store as "cycle position quantized down to a tick boundary" so
      // subsequent wait_ticks math stays consistent.
      last_write_cycle = now_tick * cycles_per_tick;
    }
  }

  // emit a trailing wait so receivers play out the final note's decay
  {
    const std::uint64_t end_cycle  = player.currentCycle() - start_cycle;
    const std::uint64_t end_tick   = end_cycle / cycles_per_tick;
    const std::uint64_t last_tick  = last_write_cycle / cycles_per_tick;
    if (end_tick > last_tick) emit_wait(body, end_tick - last_tick);
  }
  body.push_back(OP_END);

  // assemble header
  std::uint8_t header[HEADER_BYTES] = {0};
  std::memcpy(header + 0x00, MAGIC, 4);
  header[0x04] = FORMAT_VERSION;
  // flags: bit0 0=cycle-accurate, 1=frame-tick; bit1 0=PAL, 1=NTSC
  // flags byte: bit0 0=cycle-accurate (tick_rate == cpu_clock), 1=quantized
  // (custom or frame tick). bit1 0=PAL, 1=NTSC.
  header[0x05] =
      (tick_rate_hz == cpu_clock ? 0x00 : 0x01) |
      (is_pal ? 0x00 : 0x02);
  header[0x06] = 0;  // reserved
  header[0x07] = 0;
  write_le32(header + 0x08, tick_rate_hz);
  write_le32(header + 0x0C, static_cast<std::uint32_t>(body.size()));

  // write file
  std::ofstream of(args.output, std::ios::binary | std::ios::trunc);
  if (!of) {
    std::fprintf(stderr, "error: cannot open %s for writing\n", args.output.c_str());
    return 5;
  }
  of.write(reinterpret_cast<const char*>(header), HEADER_BYTES);
  of.write(reinterpret_cast<const char*>(body.data()), static_cast<std::streamsize>(body.size()));
  if (!of) {
    std::fprintf(stderr, "error: write failed\n");
    return 5;
  }

  if (args.verbose) {
    std::fprintf(stderr,
      "writes   : %llu\n"
      "body     : %llu B\n"
      "file     : %llu B (header+body)\n",
      static_cast<unsigned long long>(total_writes),
      static_cast<unsigned long long>(body.size()),
      static_cast<unsigned long long>(HEADER_BYTES + body.size()));
  }
  return 0;
}
