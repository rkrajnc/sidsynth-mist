// sid-play: render a .sid (PSID/RSID) directly to a WAV file using
// libsidplayfp's full 6510 + replay + libresidfp emulation. Useful
// for A/B-comparing with sidraw-play's output (same underlying SID
// emulation, but via the register-write stream the .sidraw format
// captures).
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

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/builders/residfp.h>

namespace {

struct Args {
  std::string input;
  std::string output;
  int         subtune   = 0;     // 0 = tune's default
  int         seconds   = 180;
  int         sample_hz = 48000;
  bool        verbose   = false;
};

void usage(const char* prog) {
  std::fprintf(stderr,
    "usage: %s <input.sid> -o <output.wav>\n"
    "             [-s <subtune>]      subtune (1..N); default = tune's default\n"
    "             [-t <seconds>]      playback duration; default = 180\n"
    "             [-r <hz>]           output sample rate; default = 48000\n"
    "             [-v]                verbose stats\n",
    prog);
}

bool parse_args(int argc, char** argv, Args& out) {
  if (argc < 2) return false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](const char* flag) -> const char* {
      if (i + 1 >= argc) { std::fprintf(stderr, "error: %s requires a value\n", flag); return nullptr; }
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
    } else if (a == "-r") {
      const char* v = need("-r"); if (!v) return false;
      out.sample_hz = std::atoi(v);
      if (out.sample_hz < 8000) { std::fprintf(stderr, "error: -r must be >=8000\n"); return false; }
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
  write_le32(hdr + 16, 16);
  write_le16(hdr + 20, 1);
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

}  // namespace


int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) {
    usage(argv[0]);
    return 1;
  }

  SidTune tune(args.input.c_str());
  if (!tune.getStatus()) {
    std::fprintf(stderr, "error: failed to load %s: %s\n",
                 args.input.c_str(), tune.statusString());
    return 2;
  }
  unsigned int song = tune.selectSong(static_cast<unsigned int>(args.subtune));
  const SidTuneInfo* tinfo = tune.getInfo();
  if (!tinfo) {
    std::fprintf(stderr, "error: SidTuneInfo unavailable\n");
    return 2;
  }

  // configure the player
  sidplayfp player;
  ReSIDfpBuilder rs("residfp");

  SidConfig cfg = player.config();
  cfg.frequency      = static_cast<std::uint_least32_t>(args.sample_hz);
  cfg.samplingMethod = SidConfig::INTERPOLATE;
  cfg.sidEmulation   = &rs;
  // forceC64Model=false → respect the tune's native PAL/NTSC tag
  cfg.forceC64Model  = false;
  if (!player.config(cfg)) {
    std::fprintf(stderr, "error: player.config(): %s\n", player.error());
    return 3;
  }

  if (!player.load(&tune)) {
    std::fprintf(stderr, "error: player.load(): %s\n", player.error());
    return 3;
  }

  // initMixer must come after load() in libsidplayfp 3.x -- the mixer's
  // internal buffer sizing depends on the loaded tune's SID count.
  player.initMixer(false);   // mono

  if (args.verbose) {
    std::fprintf(stderr,
      "input    : %s (subtune %u of %u)\n"
      "output   : %s\n"
      "duration : %d s\n"
      "sample_hz: %d\n",
      args.input.c_str(), song, tinfo->songs(),
      args.output.c_str(),
      args.seconds, args.sample_hz);
  }

  // batch the play/mix loop. play(N) advances the emulator by N cycles
  // and stores produced per-SID samples internally; mix() then combines
  // them into the output buffer. We use a generous fixed chunk size --
  // libsidplayfp 3.0's getBufSize() would give us the exact figure but
  // a 16k-short scratch covers a comfortable 0.3 s of audio at 48 kHz.
  constexpr unsigned int CYCLES_PER_BATCH = 20000;   // ~1 PAL frame
  short scratch[16384];

  std::vector<short> samples;
  samples.reserve(static_cast<std::size_t>(args.sample_hz) * args.seconds);

  const std::uint64_t target_samples =
      static_cast<std::uint64_t>(args.sample_hz) * args.seconds;

  while (samples.size() < target_samples) {
    int produced = player.play(CYCLES_PER_BATCH);
    if (produced < 0) {
      std::fprintf(stderr, "error: player.play(): %s\n", player.error());
      return 4;
    }
    if (produced == 0) continue;
    // produced is the number of samples (per-SID); cap at scratch size
    int to_mix = produced;
    if (to_mix > static_cast<int>(sizeof(scratch) / sizeof(short))) {
      to_mix = static_cast<int>(sizeof(scratch) / sizeof(short));
    }
    unsigned int mixed = player.mix(scratch, static_cast<unsigned int>(to_mix));
    samples.insert(samples.end(), scratch, scratch + mixed);
  }
  if (samples.size() > target_samples) samples.resize(static_cast<std::size_t>(target_samples));

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
    std::fprintf(stderr, "samples  : %zu (%.2f s)\n", samples.size(), secs);
  }
  return 0;
}
