// sidraw-play: decode a .sidraw register-write stream and render it
// through libresidfp to a WAV file. Companion to sidraw-dump -- used
// to ear-check that a .sidraw file roundtrips to the same sound as
// the original .sid (run sidplayfp on the .sid, sidraw-play on the
// .sidraw, A/B the two WAVs).
//
// Drives reSIDfp::residfp directly with register writes paced by the
// wait opcodes in the .sidraw stream. No 6510 CPU emulation needed.
//
// 2026, Rok Krajnc <rok.krajnc@gmail.com>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstddef>
#include <fstream>
#include <string>
#include <vector>

#include <residfp/residfp.h>
#include <residfp/residfp_defs.h>

namespace {

// .sidraw v1 constants (must match sidraw_dump.cpp)
constexpr std::size_t HEADER_BYTES = 16;
constexpr std::uint8_t MAGIC[4]    = { 'S', 'I', 'D', 'R' };
constexpr std::uint8_t FORMAT_VERSION = 1;

constexpr std::uint8_t OP_WRITE_HI = 0x18;
constexpr std::uint8_t OP_WAIT_8   = 0x20;
constexpr std::uint8_t OP_WAIT_16  = 0x21;
constexpr std::uint8_t OP_WAIT_32  = 0x22;
constexpr std::uint8_t OP_END      = 0xFF;

constexpr std::uint32_t CLOCK_PAL_HZ  = 985248;
constexpr std::uint32_t CLOCK_NTSC_HZ = 1022730;

enum class Chip { Mos6581, Csg8580 };

struct Args {
  std::string input;
  std::string output;
  Chip        chip       = Chip::Mos6581;
  int         sample_hz  = 48000;
  bool        verbose    = false;
};

void usage(const char* prog) {
  std::fprintf(stderr,
    "usage: %s <input.sidraw> -o <output.wav>\n"
    "             [-c 6581|8580]      SID chip model; default = 6581\n"
    "             [-s <hz>]           output sample rate; default = 48000\n"
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
    } else if (a == "-c") {
      const char* v = need("-c"); if (!v) return false;
      std::string s = v;
      if      (s == "6581") out.chip = Chip::Mos6581;
      else if (s == "8580") out.chip = Chip::Csg8580;
      else { std::fprintf(stderr, "error: -c must be 6581|8580, got %s\n", v); return false; }
    } else if (a == "-s") {
      const char* v = need("-s"); if (!v) return false;
      out.sample_hz = std::atoi(v);
      if (out.sample_hz < 8000) { std::fprintf(stderr, "error: -s must be >=8000\n"); return false; }
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

std::uint32_t read_le32(const std::uint8_t* p) {
  return static_cast<std::uint32_t>(p[0])
       | (static_cast<std::uint32_t>(p[1]) <<  8)
       | (static_cast<std::uint32_t>(p[2]) << 16)
       | (static_cast<std::uint32_t>(p[3]) << 24);
}

void write_le32(std::uint8_t* dst, std::uint32_t v) {
  dst[0] = static_cast<std::uint8_t>(v & 0xFF);
  dst[1] = static_cast<std::uint8_t>((v >> 8) & 0xFF);
  dst[2] = static_cast<std::uint8_t>((v >> 16) & 0xFF);
  dst[3] = static_cast<std::uint8_t>((v >> 24) & 0xFF);
}

void write_le16(std::uint8_t* dst, std::uint16_t v) {
  dst[0] = static_cast<std::uint8_t>(v & 0xFF);
  dst[1] = static_cast<std::uint8_t>((v >> 8) & 0xFF);
}

// minimal 44-byte RIFF/WAVE PCM header for 16-bit mono
void write_wav(std::ofstream& of, const std::vector<short>& samples, std::uint32_t sample_hz) {
  const std::uint32_t data_bytes  = static_cast<std::uint32_t>(samples.size()) * 2u;
  const std::uint32_t riff_size   = 36 + data_bytes;
  const std::uint16_t channels    = 1;
  const std::uint16_t bits        = 16;
  const std::uint32_t byte_rate   = sample_hz * channels * (bits / 8);
  const std::uint16_t block_align = channels * (bits / 8);

  std::uint8_t hdr[44];
  std::memcpy(hdr + 0,  "RIFF", 4);
  write_le32(hdr + 4,  riff_size);
  std::memcpy(hdr + 8,  "WAVE", 4);
  std::memcpy(hdr + 12, "fmt ", 4);
  write_le32(hdr + 16, 16);                      // PCM fmt chunk size
  write_le16(hdr + 20, 1);                       // PCM format
  write_le16(hdr + 22, channels);
  write_le32(hdr + 24, sample_hz);
  write_le32(hdr + 28, byte_rate);
  write_le16(hdr + 32, block_align);
  write_le16(hdr + 34, bits);
  std::memcpy(hdr + 36, "data", 4);
  write_le32(hdr + 40, data_bytes);

  of.write(reinterpret_cast<const char*>(hdr), 44);
  of.write(reinterpret_cast<const char*>(samples.data()),
           static_cast<std::streamsize>(data_bytes));
}

// clock the SID forward by `cycles`, append produced samples to `out`.
// libresidfp's clock(cycles, buf) requires a buffer big enough to hold
// the produced samples (rough formula: ceil(cycles * sample_hz /
// clock_hz)). We feed it in small chunks so a fixed-size scratch
// buffer suffices regardless of how long the wait is.
void clock_and_collect(reSIDfp::residfp& sid,
                       std::uint64_t cycles,
                       double clock_hz,
                       double sample_hz,
                       std::vector<short>& out) {
  // chunk size of 1024 cycles → ~50 samples at 48 kHz/985 kHz; with
  // headroom a 4-kilobyte scratch is plenty.
  constexpr unsigned int CHUNK = 1024;
  static constexpr int SCRATCH_N = 4096;
  short scratch[SCRATCH_N];

  while (cycles > 0) {
    const unsigned int c = cycles > CHUNK ? CHUNK : static_cast<unsigned int>(cycles);
    int produced = sid.clock(c, scratch);
    if (produced < 0 || produced > SCRATCH_N) {
      std::fprintf(stderr, "error: residfp::clock produced %d samples (>SCRATCH_N=%d)\n",
                   produced, SCRATCH_N);
      std::exit(6);
    }
    out.insert(out.end(), scratch, scratch + produced);
    cycles -= c;
    (void)clock_hz; (void)sample_hz;  // currently unused; kept for future ratio checks
  }
}

}  // namespace


int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) {
    usage(argv[0]);
    return 1;
  }

  // read the whole .sidraw file
  std::ifstream in(args.input, std::ios::binary | std::ios::ate);
  if (!in) {
    std::fprintf(stderr, "error: cannot open %s\n", args.input.c_str());
    return 2;
  }
  const std::streamsize file_bytes = in.tellg();
  in.seekg(0, std::ios::beg);
  std::vector<std::uint8_t> data(static_cast<std::size_t>(file_bytes));
  in.read(reinterpret_cast<char*>(data.data()), file_bytes);
  if (!in) {
    std::fprintf(stderr, "error: short read\n");
    return 2;
  }

  // parse header
  if (data.size() < HEADER_BYTES) {
    std::fprintf(stderr, "error: file shorter than %zu-byte header\n", HEADER_BYTES);
    return 2;
  }
  if (std::memcmp(data.data(), MAGIC, 4) != 0) {
    std::fprintf(stderr, "error: bad magic (expected 'SIDR')\n");
    return 2;
  }
  const std::uint8_t version  = data[0x04];
  const std::uint8_t flags    = data[0x05];
  const std::uint32_t tick_hz = read_le32(data.data() + 0x08);
  const std::uint32_t body_sz = read_le32(data.data() + 0x0C);
  const bool frame_tick = (flags & 0x01) != 0;
  const bool ntsc       = (flags & 0x02) != 0;
  if (version != FORMAT_VERSION) {
    std::fprintf(stderr, "error: unsupported format version %u\n", version);
    return 2;
  }
  const std::uint32_t cpu_clock = ntsc ? CLOCK_NTSC_HZ : CLOCK_PAL_HZ;
  const std::uint64_t cycles_per_tick =
      frame_tick ? (cpu_clock / tick_hz) : 1u;

  // sanity: cycle mode tick_hz should equal cpu_clock
  if (!frame_tick && tick_hz != cpu_clock) {
    std::fprintf(stderr,
      "warning: header tick_rate %u != native cpu_clock %u for %s "
      "cycle-accurate mode; using %u cycles/tick anyway\n",
      tick_hz, cpu_clock, ntsc ? "NTSC" : "PAL",
      static_cast<unsigned>(cycles_per_tick));
  }

  // set up libresidfp
  reSIDfp::residfp sid;
  sid.setChipModel(args.chip == Chip::Csg8580
                     ? reSIDfp::CSG8580
                     : reSIDfp::MOS6581);
  sid.enableFilter(true);
  // Match libsidplayfp's default samplingMethod=INTERPOLATE so this
  // tool's audio is filter-comparable with sid-play / system sidplayfp.
  // residfp's DECIMATE == libsidplayfp's INTERPOLATE (linear interp);
  // RESAMPLE is sinc resampling, which has pre-echo on transients.
  if (!sid.setSamplingParameters(static_cast<double>(cpu_clock),
                                  reSIDfp::DECIMATE,
                                  static_cast<double>(args.sample_hz))) {
    std::fprintf(stderr, "error: setSamplingParameters failed\n");
    return 3;
  }
  sid.reset();
  // libsidplayfp's c64sid::reset() always pokes master volume to 0xF
  // immediately after the SID reset (see c64sid.h reset(0xf)). That
  // write does NOT pass through poke()/lastpoke[], so getSidStatus()-
  // based capture in sidraw-dump misses it. Pre-program here to match
  // libsidplayfp's post-reset state so the first ~52 cycles of audio
  // have the right DC level (and so the SID's filter biases match
  // direct rendering).
  sid.write(0x18, 0x0F);

  if (args.verbose) {
    std::fprintf(stderr,
      "input    : %s (%zu B, body %u B)\n"
      "output   : %s\n"
      "header   : v%u flags=0x%02X (%s, %s) tick_rate=%u Hz\n"
      "clock    : %u Hz (%s) -> %llu cycles/tick\n"
      "chip     : %s, sample_hz=%d\n",
      args.input.c_str(), data.size(), body_sz,
      args.output.c_str(),
      version, flags,
      frame_tick ? "frame-tick" : "cycle-accurate",
      ntsc ? "NTSC" : "PAL",
      tick_hz, cpu_clock, ntsc ? "NTSC" : "PAL",
      static_cast<unsigned long long>(cycles_per_tick),
      args.chip == Chip::Csg8580 ? "8580" : "6581",
      args.sample_hz);
  }

  // decode opcodes
  std::vector<short> samples;
  samples.reserve(static_cast<std::size_t>(args.sample_hz) * 60u);  // ~60s reserve

  std::size_t pos = HEADER_BYTES;
  std::uint64_t pending_cycles = 0;
  std::uint64_t total_cycles   = 0;   // cumulative cycles passed to clock()
  std::uint64_t total_writes   = 0;
  bool clean_eof = false;

  while (pos < data.size()) {
    const std::uint8_t op = data[pos++];

    if (op == OP_END) {
      clean_eof = true;
      break;
    } else if (op <= OP_WRITE_HI) {
      if (pos >= data.size()) {
        std::fprintf(stderr, "error: write opcode truncated at offset %zu\n", pos - 1);
        return 4;
      }
      const std::uint8_t dd = data[pos++];
      // flush any pending wait before applying the write
      if (pending_cycles > 0) {
        clock_and_collect(sid, pending_cycles, cpu_clock, args.sample_hz, samples);
        total_cycles  += pending_cycles;
        pending_cycles = 0;
      }
      sid.write(op, dd);
      ++total_writes;
    } else if (op == OP_WAIT_8) {
      if (pos >= data.size()) {
        std::fprintf(stderr, "error: 0x20 truncated at offset %zu\n", pos - 1);
        return 4;
      }
      pending_cycles += static_cast<std::uint64_t>(data[pos]) * cycles_per_tick;
      pos += 1;
    } else if (op == OP_WAIT_16) {
      if (pos + 2 > data.size()) {
        std::fprintf(stderr, "error: 0x21 truncated at offset %zu\n", pos - 1);
        return 4;
      }
      const std::uint32_t n = data[pos] | (data[pos + 1] << 8);
      pending_cycles += static_cast<std::uint64_t>(n) * cycles_per_tick;
      pos += 2;
    } else if (op == OP_WAIT_32) {
      if (pos + 4 > data.size()) {
        std::fprintf(stderr, "error: 0x22 truncated at offset %zu\n", pos - 1);
        return 4;
      }
      const std::uint32_t n = read_le32(data.data() + pos);
      pending_cycles += static_cast<std::uint64_t>(n) * cycles_per_tick;
      pos += 4;
    } else {
      std::fprintf(stderr, "error: unknown/reserved opcode 0x%02X at offset %zu\n",
                   op, pos - 1);
      return 4;
    }
  }
  // flush trailing wait so the audio doesn't cut off mid-decay
  if (pending_cycles > 0) {
    clock_and_collect(sid, pending_cycles, cpu_clock, args.sample_hz, samples);
    total_cycles  += pending_cycles;
    pending_cycles = 0;
  }

  // libresidfp's clock(cycles, buf) returns an "approximate by excess"
  // sample count per call; over many chunked calls this accumulates a
  // small surplus (~10s of samples per 5 s playback). Trim the output
  // to the exact target so the file's tempo matches the source rate.
  const std::uint64_t target_samples =
      (total_cycles * static_cast<std::uint64_t>(args.sample_hz)) / cpu_clock;
  if (samples.size() > static_cast<std::size_t>(target_samples)) {
    samples.resize(static_cast<std::size_t>(target_samples));
  }

  if (!clean_eof) {
    std::fprintf(stderr, "warning: stream ended without 0xFF EOF marker\n");
  }

  // write WAV
  std::ofstream of(args.output, std::ios::binary | std::ios::trunc);
  if (!of) {
    std::fprintf(stderr, "error: cannot open %s for writing\n", args.output.c_str());
    return 5;
  }
  write_wav(of, samples, static_cast<std::uint32_t>(args.sample_hz));
  if (!of) {
    std::fprintf(stderr, "error: WAV write failed\n");
    return 5;
  }

  if (args.verbose) {
    const double secs = static_cast<double>(samples.size()) / args.sample_hz;
    std::fprintf(stderr,
      "writes   : %llu\n"
      "samples  : %zu (%.2f s)\n",
      static_cast<unsigned long long>(total_writes),
      samples.size(), secs);
  }
  return 0;
}
