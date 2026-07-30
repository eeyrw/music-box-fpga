#ifndef RENDER_RTL_EFFECTS_ENABLE
#define RENDER_RTL_EFFECTS_ENABLE 0
#endif

#if RENDER_RTL_EFFECTS_ENABLE
#include "Vvoice_major_render_effects_harness.h"
using RenderDut = Vvoice_major_render_effects_harness;
#else
#include "Vvoice_major_render_harness.h"
using RenderDut = Vvoice_major_render_harness;
#endif
#include "verilated.h"

#include "command_control.h"
#include "global_effects_model.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "wav_writer.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace {

int32_t signed24(uint32_t value) {
  value &= 0x00ffffffu;
  return (value & 0x00800000u) ? int32_t(value | 0xff000000u)
                                : int32_t(value);
}

int16_t saturate16(int32_t value) {
  return int16_t(std::clamp(value, int32_t(-32768), int32_t(32767)));
}

class WindowPrefetchAnalyzer {
 public:
  static constexpr std::array<uint32_t, 5> kWindowWords = {8, 16, 32, 64, 128};

  void observe(uint16_t voice, bool first, bool last, uint32_t addr_0,
               uint32_t addr_1) {
    if (voice >= render::kNumVoices) return;
    Block& block = blocks_.at(voice);
    if (first) {
      if (block.active) finish_block(voice);
      block = {};
      block.active = true;
    }
    if (!block.active) return;
    block.addresses.push_back(addr_0);
    block.addresses.push_back(addr_1);
    if (last) finish_block(voice);
  }

  void finish() {
    for (uint32_t voice = 0; voice < blocks_.size(); ++voice) {
      if (blocks_[voice].active) finish_block(voice);
    }
  }

  void print(std::ostream& out) const {
    out << "WINDOW_PREFETCH_TRACE blocks=" << total_blocks_
        << " endpoints=" << total_endpoints_
        << " ideal_demand_lines=" << ideal_demand_lines_ << '\n';
    out << std::fixed << std::setprecision(3);
    for (size_t index = 0; index < kWindowWords.size(); ++index) {
      const Result& result = results_[index];
      const double endpoint_pct = total_endpoints_ == 0 ? 0.0 :
          100.0 * double(result.block_endpoint_hits) / double(total_endpoints_);
      const double block_pct = total_blocks_ == 0 ? 0.0 :
          100.0 * double(result.block_full_hits) / double(total_blocks_);
      // A RAMB36 configured as an 18-bit sample memory stores 2048 words.
      const uint64_t sample_words = uint64_t(kWindowWords[index]) *
                                    uint64_t(render::kNumVoices);
      const uint64_t bram36 = (sample_words + 2047u) / 2048u;
      out << "WINDOW_PREFETCH words=" << kWindowWords[index]
          << " bram36=" << bram36
          << " block_endpoint_coverage_pct=" << endpoint_pct
          << " block_full_coverage_pct=" << block_pct
          << " block_reload_lines=" << result.block_reload_lines
          << " persistent_lines=" << result.persistent_lines
          << " adaptive_lines=" << result.adaptive_lines << '\n';
    }
    out.unsetf(std::ios::floatfield);
  }

 private:
  static constexpr uint32_t kLineWords = 8;

  struct Block {
    bool active = false;
    std::vector<uint32_t> addresses;
  };

  struct Window {
    bool valid = false;
    uint32_t base = 0;
  };

  struct Result {
    uint64_t block_endpoint_hits = 0;
    uint64_t block_full_hits = 0;
    uint64_t block_reload_lines = 0;
    uint64_t persistent_lines = 0;
    uint64_t adaptive_lines = 0;
  };

  static uint32_t align_line(uint32_t addr) {
    return addr & ~(kLineWords - 1u);
  }

  static bool contains(uint32_t base, uint32_t words, uint32_t addr) {
    return addr >= base && uint64_t(addr) < uint64_t(base) + words;
  }

  static uint64_t unique_lines(const std::vector<uint32_t>& addresses) {
    std::set<uint32_t> lines;
    for (uint32_t addr : addresses) lines.insert(align_line(addr));
    return lines.size();
  }

  void finish_block(uint32_t voice) {
    Block& block = blocks_.at(voice);
    if (!block.active || block.addresses.empty()) {
      block = {};
      return;
    }
    ++total_blocks_;
    total_endpoints_ += block.addresses.size();
    ideal_demand_lines_ += unique_lines(block.addresses);

    for (size_t index = 0; index < kWindowWords.size(); ++index) {
      const uint32_t words = kWindowWords[index];
      const uint64_t refill_lines = words / kLineWords;
      Result& result = results_[index];

      const uint32_t block_base = align_line(block.addresses.front());
      std::vector<uint32_t> block_fallback;
      bool block_full = true;
      for (uint32_t addr : block.addresses) {
        const bool hit = contains(block_base, words, addr);
        result.block_endpoint_hits += hit;
        block_full &= hit;
        if (!hit) block_fallback.push_back(addr);
      }
      result.block_full_hits += block_full;
      result.block_reload_lines += refill_lines + unique_lines(block_fallback);

      Window& persistent = persistent_windows_[index][voice];
      if (!persistent.valid ||
          !contains(persistent.base, words, block.addresses.front())) {
        persistent.valid = true;
        persistent.base = block_base;
        result.persistent_lines += refill_lines;
      }
      std::vector<uint32_t> persistent_fallback;
      for (uint32_t addr : block.addresses) {
        if (!contains(persistent.base, words, addr))
          persistent_fallback.push_back(addr);
      }
      result.persistent_lines += unique_lines(persistent_fallback);

      Window& adaptive = adaptive_windows_[index][voice];
      for (uint32_t addr : block.addresses) {
        if (!adaptive.valid || !contains(adaptive.base, words, addr)) {
          adaptive.valid = true;
          adaptive.base = align_line(addr);
          result.adaptive_lines += refill_lines;
        }
      }
    }
    block = {};
  }

  std::array<Block, render::kNumVoices> blocks_{};
  std::array<std::array<Window, render::kNumVoices>, kWindowWords.size()>
      persistent_windows_{};
  std::array<std::array<Window, render::kNumVoices>, kWindowWords.size()>
      adaptive_windows_{};
  std::array<Result, kWindowWords.size()> results_{};
  uint64_t total_blocks_ = 0;
  uint64_t total_endpoints_ = 0;
  uint64_t ideal_demand_lines_ = 0;
};

class RtlDriver : public render::CommandWordSink {
 public:
  RtlDriver(VerilatedContext& context, int sample_rate)
      : context_(context), dut_(&context), sample_rate_(sample_rate) {
    clear_inputs();
    dut_.rst = 1;
    for (int cycle = 0; cycle < 6; ++cycle) step();
    dut_.rst = 0;
    for (int cycle = 0; cycle < 4; ++cycle) step();
  }

  ~RtlDriver() { dut_.final(); }

  void write_command_words(const std::vector<uint32_t>& words) override {
    for (uint32_t word : words) {
      dut_.cmd_stream_data = word;
      pulse_until_ready(dut_.cmd_stream_valid, dut_.cmd_stream_ready,
                        "command word");
    }
  }

  std::vector<std::pair<int16_t, int16_t>> render_block(uint32_t start_frame,
                                                        uint32_t frame_count) {
    if (frame_count == 0 || frame_count > configured_max_block_frames()) {
      throw std::runtime_error("block length exceeds configured RTL maximum");
    }
    dut_.block_start_frame = start_frame;
    dut_.block_frame_count = uint8_t(frame_count);
    const uint16_t block_active_voices = active_voice_count();
    const uint64_t start_cycle = cycles_;
#if RENDER_RTL_EFFECTS_ENABLE
    if (!first_output_frame_seen_ && !first_effect_block_seen_ &&
        block_active_voices != 0) {
      first_effect_block_seen_ = true;
      first_effect_block_start_cycle_ = start_cycle;
      first_output_frame_index_ = start_frame;
      first_output_active_voices_ = block_active_voices;
    }
#endif
    pulse_until_ready(dut_.block_req_valid, dut_.block_req_ready, "block request");
#if RENDER_RTL_EFFECTS_ENABLE
    wait_valid(dut_.renderer_complete_valid, "renderer completion");
#else
    wait_valid(dut_.block_complete_valid, "block completion");
#endif
    const uint64_t render_cycles = cycles_ - start_cycle;
    ++render_blocks_;
    ++block_frame_count_histogram_[frame_count];
    max_requested_block_frames_ =
        std::max(max_requested_block_frames_, frame_count);
    render_frames_ += frame_count;
    total_render_cycles_ += render_cycles;
    max_render_cycles_ = std::max(max_render_cycles_, render_cycles);
    const uint64_t deadline_cycles =
        uint64_t(frame_count) * 100000000u / uint64_t(sample_rate_);
    if (render_cycles > deadline_cycles) ++deadline_misses_;
    const uint64_t utilization_ppm =
        render_cycles * uint64_t(sample_rate_) * 1000000u /
        (uint64_t(frame_count) * 100000000u);
    max_deadline_utilization_ppm_ =
        std::max(max_deadline_utilization_ppm_, utilization_ppm);
#if RENDER_RTL_EFFECTS_ENABLE
    wait_valid(dut_.block_complete_valid, "effects block completion");
    const uint64_t end_to_end_cycles = cycles_ - start_cycle;
    total_end_to_end_cycles_ += end_to_end_cycles;
    max_end_to_end_cycles_ = std::max(max_end_to_end_cycles_, end_to_end_cycles);
    const uint64_t end_to_end_utilization_ppm =
        end_to_end_cycles * uint64_t(sample_rate_) * 1000000u /
        (uint64_t(frame_count) * 100000000u);
    max_end_to_end_utilization_ppm_ = std::max(
        max_end_to_end_utilization_ppm_, end_to_end_utilization_ppm);
    if (end_to_end_cycles > deadline_cycles) ++end_to_end_deadline_misses_;
#endif
    const uint8_t buffer = dut_.block_complete_buffer;
    if (dut_.block_complete_start_frame != start_frame ||
        dut_.block_complete_frame_count != frame_count) {
      throw std::runtime_error("RTL block completion metadata mismatch");
    }
    dut_.block_complete_ready = 1;
    step();
    dut_.block_complete_ready = 0;

    std::vector<std::pair<int16_t, int16_t>> samples;
#if RENDER_RTL_EFFECTS_ENABLE
    samples.swap(effect_samples_);
#else
    samples.reserve(frame_count);
    for (uint32_t index = 0; index < frame_count; ++index) {
      dut_.block_read_buffer = buffer;
      dut_.block_read_index = uint8_t(index);
      pulse_until_ready(dut_.block_read_req_valid, dut_.block_read_req_ready,
                        "block read request");
      wait_valid(dut_.block_read_rsp_valid, "block read response");
      if (!first_output_frame_seen_ && block_active_voices != 0) {
        first_output_frame_seen_ = true;
        first_output_frame_core_cycle_ = cycles_;
        first_output_frame_latency_cycles_ = cycles_ - start_cycle;
        first_output_frame_index_ = start_frame + index;
        first_output_active_voices_ = block_active_voices;
      }
      samples.emplace_back(saturate16(signed24(dut_.block_read_sample_l)),
                           saturate16(signed24(dut_.block_read_sample_r)));
      dut_.block_read_rsp_ready = 1;
      step();
      dut_.block_read_rsp_ready = 0;
    }

    dut_.block_release_buffer = buffer;
    pulse_until_ready(dut_.block_release_valid, dut_.block_release_ready,
                      "block release");
#endif
    return samples;
  }

#if RENDER_RTL_EFFECTS_ENABLE
  std::vector<std::pair<int16_t, int16_t>> finish_effects(
      uint32_t silent_frames, uint64_t expected_output_frames) {
    for (uint32_t frame = 0; frame < silent_frames; ++frame) {
      pulse_until_ready(dut_.effect_flush_valid, dut_.effect_flush_ready,
                        "effect flush frame");
    }
    uint64_t waited = 0;
    while (effect_output_frames_ < expected_output_frames) {
      step();
      if (++waited > 1000000)
        throw std::runtime_error("effect output drain timeout");
    }
    std::vector<std::pair<int16_t, int16_t>> samples;
    samples.swap(effect_samples_);
    return samples;
  }
#endif

  uint64_t cycles() const { return cycles_; }
  uint64_t render_blocks() const { return render_blocks_; }
  uint64_t render_frames() const { return render_frames_; }
  uint64_t total_render_cycles() const { return total_render_cycles_; }
  uint64_t max_render_cycles() const { return max_render_cycles_; }
  uint64_t max_deadline_utilization_ppm() const {
    return max_deadline_utilization_ppm_;
  }
  uint64_t deadline_misses() const { return deadline_misses_; }
  uint64_t total_end_to_end_cycles() const { return total_end_to_end_cycles_; }
  uint64_t max_end_to_end_cycles() const { return max_end_to_end_cycles_; }
  uint64_t max_end_to_end_utilization_ppm() const {
    return max_end_to_end_utilization_ppm_;
  }
  uint64_t end_to_end_deadline_misses() const {
    return end_to_end_deadline_misses_;
  }
  uint32_t configured_max_block_frames() const {
    return dut_.configured_max_block_frames;
  }
  uint32_t max_requested_block_frames() const {
    return max_requested_block_frames_;
  }
  std::string block_frame_count_histogram_json() const {
    std::ostringstream out;
    out << '{';
    bool first = true;
    for (const auto& [frames, count] : block_frame_count_histogram_) {
      if (!first) out << ',';
      first = false;
      out << '\"' << frames << "\":" << count;
    }
    out << '}';
    return out.str();
  }
  uint64_t first_output_frame_core_cycle() const {
    return first_output_frame_core_cycle_;
  }
  uint64_t first_output_frame_latency_cycles() const {
    return first_output_frame_latency_cycles_;
  }
  uint32_t first_output_frame_index() const {
    return first_output_frame_index_;
  }
  uint16_t first_output_active_voices() const {
    return first_output_active_voices_;
  }
  uint64_t ddr_accepted() const { return dut_.ddr_accepted; }
  uint64_t ddr_returned() const { return dut_.ddr_returned; }
  uint64_t ddr_row_hits() const { return dut_.ddr_row_hits; }
  uint64_t ddr_row_misses() const { return dut_.ddr_row_misses; }
  uint64_t ddr_activates() const { return dut_.ddr_activates; }
  uint64_t ddr_precharges() const { return dut_.ddr_precharges; }
  uint64_t ddr_refreshes() const { return dut_.ddr_refreshes; }
  uint64_t window_client_requests() const {
    return dut_.window_client_requests;
  }
  uint64_t window_hits() const { return dut_.window_hits; }
  uint64_t window_memory_reads() const { return dut_.window_memory_reads; }
  uint64_t window_evictions() const { return dut_.window_evictions; }
  uint64_t window_stall_cycles() const {
    return dut_.window_stall_cycles;
  }
  uint64_t window_refills() const { return dut_.window_refills; }
  uint64_t window_fallback_reads() const {
    return dut_.window_fallback_reads;
  }
  uint32_t configured_window_bytes() const {
    return dut_.configured_window_bytes;
  }
  uint32_t configured_window_words() const {
    return dut_.configured_window_words;
  }
  uint64_t stale_parameter_updates() const {
    return dut_.stale_generation_count;
  }
  uint16_t active_voice_count() const { return dut_.active_voice_count; }
#if RENDER_RTL_EFFECTS_ENABLE
  uint16_t effects_max_processing_cycles() const {
    return dut_.effects_max_processing_cycles;
  }
  uint32_t effects_input_frame_count() const {
    return dut_.effects_input_frame_count;
  }
  uint32_t effects_output_frame_count() const {
    return dut_.effects_output_frame_count;
  }
#endif

  void print_window_prefetch_analysis(std::ostream& out) {
    window_analyzer_.finish();
    window_analyzer_.print(out);
  }

 private:
  void clear_inputs() {
    dut_.core_clk = 0;
    dut_.ddr_clk = 0;
    dut_.rst = 0;
    dut_.cmd_stream_valid = 0;
    dut_.block_req_valid = 0;
    dut_.block_complete_ready = 0;
#if RENDER_RTL_EFFECTS_ENABLE
    dut_.effect_flush_valid = 0;
    dut_.effect_output_ready = 1;
#else
    dut_.block_read_req_valid = 0;
    dut_.block_read_rsp_ready = 0;
    dut_.block_release_valid = 0;
#endif
  }

  void step() {
    dut_.core_clk = 0;
    for (int ddr_cycle = 0; ddr_cycle < 4; ++ddr_cycle) {
      dut_.ddr_clk = 0;
      dut_.eval();
      context_.timeInc(1);
      if (ddr_cycle == 2) {
#if RENDER_RTL_EFFECTS_ENABLE
        if (dut_.effect_output_valid && dut_.effect_output_ready) {
          effect_samples_.emplace_back(int16_t(dut_.effect_output_l),
                                       int16_t(dut_.effect_output_r));
          ++effect_output_frames_;
          if (!first_output_frame_seen_ && first_effect_block_seen_) {
            first_output_frame_seen_ = true;
            first_output_frame_core_cycle_ = cycles_;
            first_output_frame_latency_cycles_ =
                cycles_ - first_effect_block_start_cycle_;
          }
        }
#endif
        dut_.core_clk = 1;
      }
      dut_.ddr_clk = 1;
      dut_.eval();
      if (ddr_cycle == 2 && dut_.debug_plan_valid) {
        window_analyzer_.observe(dut_.debug_plan_voice,
                                 dut_.debug_plan_first,
                                 dut_.debug_plan_last,
                                 dut_.debug_plan_addr_0,
                                 dut_.debug_plan_addr_1);
      }
      context_.timeInc(1);
    }
    dut_.ddr_clk = 0;
    dut_.core_clk = 0;
    dut_.eval();
    ++cycles_;
  }

  template <typename Valid, typename Ready>
  void pulse_until_ready(Valid& valid, const Ready& ready, const char* operation) {
    valid = 1;
    dut_.eval();
    uint64_t waited = 0;
    while (!ready) {
      step();
      if (++waited > 200000) throw std::runtime_error(std::string(operation) + " timeout");
    }
    step();
    valid = 0;
    dut_.eval();
  }

  template <typename Valid>
  void wait_valid(const Valid& valid, const char* operation) {
    uint64_t waited = 0;
    dut_.eval();
    while (!valid) {
      step();
      if (++waited > 1000000) throw std::runtime_error(std::string(operation) + " timeout");
    }
  }

  VerilatedContext& context_;
  RenderDut dut_;
  int sample_rate_;
  uint64_t cycles_ = 0;
  uint64_t render_blocks_ = 0;
  uint64_t render_frames_ = 0;
  uint64_t total_render_cycles_ = 0;
  uint64_t max_render_cycles_ = 0;
  uint64_t max_deadline_utilization_ppm_ = 0;
  uint64_t deadline_misses_ = 0;
  uint64_t total_end_to_end_cycles_ = 0;
  uint64_t max_end_to_end_cycles_ = 0;
  uint64_t max_end_to_end_utilization_ppm_ = 0;
  uint64_t end_to_end_deadline_misses_ = 0;
  uint32_t max_requested_block_frames_ = 0;
  std::map<uint32_t, uint64_t> block_frame_count_histogram_;
  bool first_output_frame_seen_ = false;
  uint64_t first_output_frame_core_cycle_ = 0;
  uint64_t first_output_frame_latency_cycles_ = 0;
  uint32_t first_output_frame_index_ = 0;
  uint16_t first_output_active_voices_ = 0;
  WindowPrefetchAnalyzer window_analyzer_;
#if RENDER_RTL_EFFECTS_ENABLE
  std::vector<std::pair<int16_t, int16_t>> effect_samples_;
  uint64_t effect_output_frames_ = 0;
  bool first_effect_block_seen_ = false;
  uint64_t first_effect_block_start_cycle_ = 0;
#endif
};

uint32_t next_boundary(uint32_t frame, uint32_t end_frame,
                       int control_tick_samples,
                       const std::vector<render::NoteEvent>& events,
                       uint32_t max_block_frames) {
  uint32_t result = std::min<uint32_t>(end_frame, frame + max_block_frames);
  const uint32_t tick = uint32_t(std::max(1, control_tick_samples));
  const uint64_t next_tick = (uint64_t(frame) / tick + 1u) * tick;
  if (next_tick < result) result = uint32_t(next_tick);
  for (const auto& event : events) {
    const uint32_t event_frame = uint32_t(std::max(0, event.sample));
    if (event_frame > frame) {
      result = std::min(result, event_frame);
      break;
    }
  }
  return std::max(frame + 1u, result);
}

}  // namespace

int main(int argc, char** argv) {
  try {
    render::install_interrupt_handler();
    VerilatedContext context;
    context.commandArgs(argc, argv);
    std::vector<char*> render_argv;
    render_argv.push_back(argv[0]);
    for (int index = 1; index < argc; ++index) {
      if (argv[index][0] != '+') render_argv.push_back(argv[index]);
    }
    render::Args args = render::parse_args(int(render_argv.size()),
                                           render_argv.data());
    using Clock = std::chrono::steady_clock;
    const auto total_start = Clock::now();
    render::RenderPreparationTiming timing;
    render::RenderInputs inputs = render::load_render_inputs(args, &timing);
    std::vector<int16_t> wave_memory = render::take_sf2_wave_memory(inputs);
    std::vector<render::Region> regions;
    render::prepare_render_regions(args, inputs, wave_memory, regions, &timing);

    std::filesystem::create_directories(args.out_dir);
    RtlDriver driver(context, args.sample_rate);
    render::CommandVoiceControl sink(driver);
#if RENDER_RTL_EFFECTS_ENABLE
    if (args.compressor_threshold_cb < 0.0 ||
        args.compressor_threshold_cb > 1000.0 ||
        args.compressor_ratio < 1.0 || args.compressor_attack_ms < 0.0 ||
        args.compressor_release_ms < 0.0 || args.master_volume < 0.0 ||
        args.master_volume > 1.0 || args.effects_tail_seconds < 0.0) {
      throw std::runtime_error("invalid RTL effect-chain argument");
    }
    render::GlobalEffectsPreset effects_preset =
        render::make_global_effects_preset(args.effects_preset,
                                           args.sample_rate);
    render::apply_global_effect_enable_overrides(
        effects_preset, args.chorus_enable, args.reverb_enable);
    render::CommandAudioControl audio_control(driver);
    auto cb_q12_20 = [](double cb) {
      return uint32_t(std::llround(cb * double(uint32_t{1} << 20)));
    };
    auto step_for_ms = [&](double milliseconds) {
      if (milliseconds == 0.0) return uint32_t{0};
      const uint64_t frames = std::max<uint64_t>(
          1, uint64_t(std::llround(
                 milliseconds * args.sample_rate / 1000.0)));
      const uint64_t distance = uint64_t{1000} << 20;
      return uint32_t((distance + frames - 1) / frames);
    };
    render::CompressorCommandConfig compressor_config;
    compressor_config.enable = args.compressor_enable;
    compressor_config.threshold_cb_q12_20 =
        cb_q12_20(args.compressor_threshold_cb);
    compressor_config.ratio_slope_q0_16 = uint16_t(std::clamp<int64_t>(
        std::llround((1.0 - 1.0 / args.compressor_ratio) * 65536.0),
        0, 65535));
    compressor_config.attack_step_cb_q12_20 =
        step_for_ms(args.compressor_attack_ms);
    compressor_config.release_step_cb_q12_20 =
        step_for_ms(args.compressor_release_ms);
    audio_control.configure_compressor(compressor_config);
    audio_control.set_master_volume(
        int(std::llround(args.master_volume * 32767.0)));
    audio_control.configure_chorus(effects_preset.chorus);
    audio_control.configure_reverb(effects_preset.reverb);
    const bool spatial_effects_enabled =
        effects_preset.chorus.enable || effects_preset.reverb.enable;
    const uint32_t effect_tail_frames = spatial_effects_enabled ?
        uint32_t(std::llround(args.effects_tail_seconds * args.sample_rate)) :
        0u;
#endif
    render::RenderDiagnostics diagnostics;
    diagnostics.detailed_enabled = args.detailed_diagnostics;
    render::McuModel mcu(sink, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);
    const std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    uint32_t frame = 0;
    uint64_t nonzero_words = 0;
    uint16_t peak_active_voices = 0;
    const uint32_t end_frame = uint32_t(inputs.sample_count);
    const auto render_start = Clock::now();
    while (frame < end_frame && !render::interrupt_requested()) {
      timeline.advance_to(int(frame));
      peak_active_voices = std::max(peak_active_voices,
                                   driver.active_voice_count());
      const uint32_t boundary = next_boundary(frame, end_frame,
                                              inputs.control_tick_samples,
                                              inputs.events,
                                              driver.configured_max_block_frames());
      auto samples = driver.render_block(frame, boundary - frame);
      for (const auto& sample : samples) {
        wav.write_stereo(sample.first, sample.second);
        nonzero_words += sample.first != 0;
        nonzero_words += sample.second != 0;
      }
      frame = boundary;
    }
#if RENDER_RTL_EFFECTS_ENABLE
    if (!render::interrupt_requested()) {
      constexpr uint32_t kCompressorLookaheadFrames = 48;
      auto tail_samples = driver.finish_effects(
          kCompressorLookaheadFrames + effect_tail_frames,
          uint64_t(end_frame) + effect_tail_frames);
      for (const auto& sample : tail_samples) {
        wav.write_stereo(sample.first, sample.second);
        nonzero_words += sample.first != 0;
        nonzero_words += sample.second != 0;
      }
    }
#endif
    const auto render_end = Clock::now();

    if (!render::interrupt_requested() && nonzero_words == 0) {
      throw std::runtime_error("RTL render produced all-zero PCM");
    }
    if (driver.ddr_accepted() != driver.ddr_returned()) {
      throw std::runtime_error("DDR request/response accounting mismatch");
    }
    if (!render::interrupt_requested()) {
      if (driver.window_client_requests() < driver.window_hits() ||
          driver.window_client_requests() - driver.window_hits() !=
              driver.window_refills() + driver.window_fallback_reads()) {
        throw std::runtime_error("sample-window client accounting mismatch");
      }
      const uint64_t refill_lines =
          driver.configured_window_words() / 8u;
      if (driver.window_memory_reads() !=
          refill_lines * driver.window_refills() +
              driver.window_fallback_reads()) {
        throw std::runtime_error("sample-window memory accounting mismatch");
      }
      if (driver.window_memory_reads() != driver.ddr_accepted()) {
        throw std::runtime_error("sample-window/DDR accounting mismatch");
      }
    }

    auto elapsed_ms = [](Clock::time_point start, Clock::time_point end) {
      return std::chrono::duration<double, std::milli>(end - start).count();
    };
    std::ostringstream stats;
    stats << "  \"render_target\": \"render-rtl-ddr3\""
          << ",\n  \"algorithm\": \"rtl_voice_major_window_ddr3"
#if RENDER_RTL_EFFECTS_ENABLE
          << "_global_audio_effects"
#endif
          << "\""
          << ",\n  \"rtl_effects_loaded\": "
          << (RENDER_RTL_EFFECTS_ENABLE ? "true" : "false")
          << ",\n" << render::render_input_json_fields(
                 args, inputs.control_tick_samples)
          << ",\n" << render::diagnostics_json_fields(diagnostics)
          << ",\n  \"timing_sf2_load_ms\": " << timing.sf2_load_ms
          << ",\n  \"timing_event_parse_ms\": " << timing.event_parse_ms
          << ",\n  \"timing_prepare_ms\": " << timing.region_prepare_ms
          << ",\n  \"timing_render_ms\": " << elapsed_ms(render_start, render_end)
          << ",\n  \"timing_total_ms\": " << elapsed_ms(total_start, render_end)
          << ",\n  \"interrupted\": "
          << (render::interrupt_requested() ? "true" : "false")
          << ",\n  \"nonzero_output_words\": " << nonzero_words
          << ",\n  \"rtl_core_cycles\": " << driver.cycles()
          << ",\n  \"rtl_render_blocks\": " << driver.render_blocks()
          << ",\n  \"rtl_render_frames\": " << driver.render_frames()
          << ",\n  \"rtl_configured_max_block_frames\": "
          << driver.configured_max_block_frames()
          << ",\n  \"rtl_max_requested_block_frames\": "
          << driver.max_requested_block_frames()
          << ",\n  \"rtl_block_frame_count_histogram\": "
          << driver.block_frame_count_histogram_json()
          << ",\n  \"rtl_total_render_cycles\": " << driver.total_render_cycles()
          << ",\n  \"rtl_max_render_cycles\": " << driver.max_render_cycles()
          << ",\n  \"rtl_max_deadline_utilization_ppm\": "
          << driver.max_deadline_utilization_ppm()
          << ",\n  \"rtl_deadline_misses\": " << driver.deadline_misses()
          << ",\n  \"rtl_total_end_to_end_cycles\": "
          << driver.total_end_to_end_cycles()
          << ",\n  \"rtl_max_end_to_end_cycles\": "
          << driver.max_end_to_end_cycles()
          << ",\n  \"rtl_max_end_to_end_utilization_ppm\": "
          << driver.max_end_to_end_utilization_ppm()
          << ",\n  \"rtl_end_to_end_deadline_misses\": "
          << driver.end_to_end_deadline_misses()
#if RENDER_RTL_EFFECTS_ENABLE
          << ",\n  \"rtl_effects_max_processing_cycles\": "
          << driver.effects_max_processing_cycles()
          << ",\n  \"rtl_effects_input_frame_count\": "
          << driver.effects_input_frame_count()
          << ",\n  \"rtl_effects_output_frame_count\": "
          << driver.effects_output_frame_count()
#endif
          << ",\n  \"rtl_window_words\": " << driver.configured_window_words()
          << ",\n  \"rtl_window_bytes\": " << driver.configured_window_bytes()
          << ",\n  \"rtl_window_client_requests\": "
          << driver.window_client_requests()
          << ",\n  \"rtl_window_hits\": " << driver.window_hits()
          << ",\n  \"rtl_window_memory_reads\": "
          << driver.window_memory_reads()
          << ",\n  \"rtl_window_evictions\": " << driver.window_evictions()
          << ",\n  \"rtl_window_stall_cycles\": "
          << driver.window_stall_cycles()
          << ",\n  \"rtl_window_refills\": " << driver.window_refills()
          << ",\n  \"rtl_window_fallback_reads\": "
          << driver.window_fallback_reads()
          << ",\n  \"rtl_stale_parameter_updates\": "
          << driver.stale_parameter_updates()
          << ",\n  \"rtl_peak_active_voices\": " << peak_active_voices
          << ",\n  \"ddr_reads\": " << driver.ddr_accepted()
          << ",\n  \"ddr_row_hits\": " << driver.ddr_row_hits()
          << ",\n  \"ddr_row_misses\": " << driver.ddr_row_misses()
          << ",\n  \"ddr_activates\": " << driver.ddr_activates()
          << ",\n  \"ddr_precharges\": " << driver.ddr_precharges()
          << ",\n  \"ddr_refreshes\": " << driver.ddr_refreshes()
          << ",\n  \"wav_path\": " << render::json_string(wav_path);
    render::write_summary(args.out_dir + "/rtl_ddr3_render_config.json",
                          regions, args.sample_rate, int(frame),
                          int(inputs.events.size()), stats.str());

    driver.print_window_prefetch_analysis(std::cout);
    std::cout << "PASS: RTL DDR3 render frames=" << frame
              << " regions=" << regions.size()
              << " nonzero_words=" << nonzero_words
              << " core_cycles=" << driver.cycles()
              << " render_blocks=" << driver.render_blocks()
              << " render_frames=" << driver.render_frames()
              << " total_render_cycles=" << driver.total_render_cycles()
              << " max_render_cycles=" << driver.max_render_cycles()
              << " max_deadline_utilization_ppm="
              << driver.max_deadline_utilization_ppm()
              << " deadline_misses=" << driver.deadline_misses()
              << " effects_loaded=" << RENDER_RTL_EFFECTS_ENABLE
              << " total_end_to_end_cycles="
              << driver.total_end_to_end_cycles()
              << " max_end_to_end_cycles="
              << driver.max_end_to_end_cycles()
              << " max_end_to_end_utilization_ppm="
              << driver.max_end_to_end_utilization_ppm()
              << " end_to_end_deadline_misses="
              << driver.end_to_end_deadline_misses()
#if RENDER_RTL_EFFECTS_ENABLE
              << " effects_max_processing_cycles="
              << driver.effects_max_processing_cycles()
              << " effects_input_frames="
              << driver.effects_input_frame_count()
              << " effects_output_frames="
              << driver.effects_output_frame_count()
#endif
              << " first_output_frame_index="
              << driver.first_output_frame_index()
              << " first_output_active_voices="
              << driver.first_output_active_voices()
              << " first_output_frame_core_cycle="
              << driver.first_output_frame_core_cycle()
              << " first_output_frame_latency_cycles="
              << driver.first_output_frame_latency_cycles()
              << " first_output_frame_latency_ns="
              << driver.first_output_frame_latency_cycles() * 10u
              << " window_words=" << driver.configured_window_words()
              << " window_bytes=" << driver.configured_window_bytes()
              << " window_client_requests="
              << driver.window_client_requests()
              << " window_hits=" << driver.window_hits()
              << " window_memory_reads=" << driver.window_memory_reads()
              << " window_evictions=" << driver.window_evictions()
              << " window_stall_cycles=" << driver.window_stall_cycles()
              << " window_refills=" << driver.window_refills()
              << " window_fallback_reads="
              << driver.window_fallback_reads()
              << " stale_parameter_updates="
              << driver.stale_parameter_updates()
              << " peak_active_voices=" << peak_active_voices
              << " active_voices_at_end=" << driver.active_voice_count()
              << " ddr_reads=" << driver.ddr_accepted()
              << " row_hits=" << driver.ddr_row_hits()
              << " row_misses=" << driver.ddr_row_misses()
              << " activates=" << driver.ddr_activates()
              << " precharges=" << driver.ddr_precharges()
              << " refreshes=" << driver.ddr_refreshes()
              << " wav=" << wav_path << "\n";
    return render::interrupt_requested() ? 130 : 0;
  } catch (const std::exception& error) {
    std::cerr << "render-rtl-ddr3 failed: " << error.what() << "\n";
    return 1;
  }
}
