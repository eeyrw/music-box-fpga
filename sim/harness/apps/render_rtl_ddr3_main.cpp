#include "Vvoice_major_render_harness.h"
#include "verilated.h"

#include "command_control.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "wav_writer.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

namespace {

constexpr uint32_t kSilenceCbQ12_20 = 1000u << 20;

uint32_t ceil_step(uint64_t distance, uint32_t duration) {
  if (duration == 0) return 0;
  return uint32_t(std::min<uint64_t>(0xffffffffu,
                                     (distance + duration - 1u) / duration));
}

int32_t signed24(uint32_t value) {
  value &= 0x00ffffffu;
  return (value & 0x00800000u) ? int32_t(value | 0xff000000u)
                                : int32_t(value);
}

int16_t saturate16(int32_t value) {
  return int16_t(std::clamp(value, int32_t(-32768), int32_t(32767)));
}

class RtlDriver {
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

  void install(int voice, uint16_t generation, const render::Region& region,
               uint32_t phase_inc, bool active) {
    dut_.install_voice = uint8_t(voice);
    dut_.install_base_addr = region.base_addr;
    dut_.install_length = region.length;
    dut_.install_loop_start = region.loop_start;
    dut_.install_loop_end = region.loop_end;
    dut_.install_loop_mode = uint8_t(region.loop_mode & 3);
    dut_.install_phase_inc = phase_inc;
    dut_.install_gain_l = uint16_t(region.gain_l);
    dut_.install_gain_r = uint16_t(region.gain_r);
    dut_.install_filter_enable = region.filter_enable;
    dut_.install_filter_b0 = uint16_t(region.filter_b0);
    dut_.install_filter_b1 = uint16_t(region.filter_b1);
    dut_.install_filter_b2 = uint16_t(region.filter_b2);
    dut_.install_filter_a1 = uint16_t(region.filter_a1);
    dut_.install_filter_a2 = uint16_t(region.filter_a2);
    drive_install_envelope(region);
    dut_.install_active = active;
    dut_.install_generation = generation;
    pulse_until_ready(dut_.install_valid, dut_.install_ready, "voice install");
  }

  bool update(int voice, uint16_t generation, const render::Region& region,
              uint32_t phase_inc, int gain_l, int gain_r, bool released,
              const render::FilterConfig& filter, uint32_t release_step) {
    dut_.params_voice = uint8_t(voice);
    dut_.params_generation = generation;
    dut_.params_phase_inc = phase_inc;
    dut_.params_gain_l = uint16_t(gain_l);
    dut_.params_gain_r = uint16_t(gain_r);
    dut_.params_released = released;
    dut_.params_filter_enable = filter.enable;
    dut_.params_filter_b0 = uint16_t(filter.b0);
    dut_.params_filter_b1 = uint16_t(filter.b1);
    dut_.params_filter_b2 = uint16_t(filter.b2);
    dut_.params_filter_a1 = uint16_t(filter.a1);
    dut_.params_filter_a2 = uint16_t(filter.a2);
    const auto& env = region.volume_envelope;
    dut_.params_env_delay_samples = env.delay_samples;
    dut_.params_env_attack_step = ceil_step(0xffffffffu, env.attack_samples);
    dut_.params_env_hold_samples = env.hold_samples;
    dut_.params_env_decay_step = ceil_step(env.sustain_cb_q12_20,
                                           env.decay_samples);
    dut_.params_env_sustain_cb = env.sustain_cb_q12_20;
    dut_.params_env_release_step = release_step;
    pulse_until_ready(dut_.params_valid, dut_.params_ready, "parameter update");
    if (dut_.stale_params_write) {
      ++stale_parameter_updates_;
      return false;
    }
    return true;
  }

  std::vector<std::pair<int16_t, int16_t>> render_block(uint32_t start_frame,
                                                        uint32_t frame_count) {
    dut_.block_start_frame = start_frame;
    dut_.block_frame_count = uint8_t(frame_count);
    const uint64_t start_cycle = cycles_;
    pulse_until_ready(dut_.block_req_valid, dut_.block_req_ready, "block request");
    wait_valid(dut_.block_complete_valid, "block completion");
    const uint64_t render_cycles = cycles_ - start_cycle;
    ++render_blocks_;
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
    const uint8_t buffer = dut_.block_complete_buffer;
    if (dut_.block_complete_start_frame != start_frame ||
        dut_.block_complete_frame_count != frame_count) {
      throw std::runtime_error("RTL block completion metadata mismatch");
    }
    dut_.block_complete_ready = 1;
    step();
    dut_.block_complete_ready = 0;

    std::vector<std::pair<int16_t, int16_t>> samples;
    samples.reserve(frame_count);
    for (uint32_t index = 0; index < frame_count; ++index) {
      dut_.block_read_buffer = buffer;
      dut_.block_read_index = uint8_t(index);
      pulse_until_ready(dut_.block_read_req_valid, dut_.block_read_req_ready,
                        "block read request");
      wait_valid(dut_.block_read_rsp_valid, "block read response");
      samples.emplace_back(saturate16(signed24(dut_.block_read_sample_l)),
                           saturate16(signed24(dut_.block_read_sample_r)));
      dut_.block_read_rsp_ready = 1;
      step();
      dut_.block_read_rsp_ready = 0;
    }

    dut_.block_release_buffer = buffer;
    pulse_until_ready(dut_.block_release_valid, dut_.block_release_ready,
                      "block release");
    return samples;
  }

  uint64_t cycles() const { return cycles_; }
  uint64_t render_blocks() const { return render_blocks_; }
  uint64_t render_frames() const { return render_frames_; }
  uint64_t total_render_cycles() const { return total_render_cycles_; }
  uint64_t max_render_cycles() const { return max_render_cycles_; }
  uint64_t max_deadline_utilization_ppm() const {
    return max_deadline_utilization_ppm_;
  }
  uint64_t deadline_misses() const { return deadline_misses_; }
  uint64_t ddr_accepted() const { return dut_.ddr_accepted; }
  uint64_t ddr_returned() const { return dut_.ddr_returned; }
  uint64_t ddr_row_hits() const { return dut_.ddr_row_hits; }
  uint64_t ddr_row_misses() const { return dut_.ddr_row_misses; }
  uint64_t ddr_activates() const { return dut_.ddr_activates; }
  uint64_t ddr_precharges() const { return dut_.ddr_precharges; }
  uint64_t ddr_refreshes() const { return dut_.ddr_refreshes; }
  uint64_t cache_requests() const { return dut_.cache_requests; }
  uint64_t cache_hits() const { return dut_.cache_hits; }
  uint64_t cache_mshr_merges() const { return dut_.cache_mshr_merges; }
  uint64_t cache_misses() const { return dut_.cache_misses; }
  uint64_t cache_evictions() const { return dut_.cache_evictions; }
  uint64_t cache_miss_stall_cycles() const {
    return dut_.cache_miss_stall_cycles;
  }
  uint32_t configured_cache_sets() const { return dut_.configured_cache_sets; }
  uint32_t configured_cache_bytes() const {
    return dut_.configured_cache_bytes;
  }
  uint64_t stale_parameter_updates() const { return stale_parameter_updates_; }
  uint16_t active_voice_count() const { return dut_.active_voice_count; }

 private:
  void clear_inputs() {
    dut_.core_clk = 0;
    dut_.ddr_clk = 0;
    dut_.rst = 0;
    dut_.install_valid = 0;
    dut_.params_valid = 0;
    dut_.block_req_valid = 0;
    dut_.block_complete_ready = 0;
    dut_.block_read_req_valid = 0;
    dut_.block_read_rsp_ready = 0;
    dut_.block_release_valid = 0;
  }

  void drive_install_envelope(const render::Region& region) {
    const auto& env = region.volume_envelope;
    dut_.install_env_delay_samples = env.delay_samples;
    dut_.install_env_attack_step = ceil_step(0xffffffffu, env.attack_samples);
    dut_.install_env_hold_samples = env.hold_samples;
    dut_.install_env_decay_step = ceil_step(env.sustain_cb_q12_20,
                                            env.decay_samples);
    dut_.install_env_sustain_cb = env.sustain_cb_q12_20;
    dut_.install_env_release_step =
        ceil_step(kSilenceCbQ12_20, env.release_samples);
  }

  void step() {
    dut_.core_clk = 0;
    for (int ddr_cycle = 0; ddr_cycle < 4; ++ddr_cycle) {
      dut_.ddr_clk = 0;
      dut_.eval();
      context_.timeInc(1);
      if (ddr_cycle == 2) dut_.core_clk = 1;
      dut_.ddr_clk = 1;
      dut_.eval();
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
  Vvoice_major_render_harness dut_;
  int sample_rate_;
  uint64_t cycles_ = 0;
  uint64_t render_blocks_ = 0;
  uint64_t render_frames_ = 0;
  uint64_t total_render_cycles_ = 0;
  uint64_t max_render_cycles_ = 0;
  uint64_t max_deadline_utilization_ppm_ = 0;
  uint64_t deadline_misses_ = 0;
  uint64_t stale_parameter_updates_ = 0;
};

class RtlVoiceSink : public render::VoiceCommandSink {
 public:
  explicit RtlVoiceSink(RtlDriver& driver) : driver_(driver) {}

  void start_voice(int voice, uint32_t phase_inc,
                   const render::Region& region) override {
    Mirror& mirror = mirrors_.at(voice);
    mirror.generation = uint16_t(mirror.generation + 1u);
    if (mirror.generation == 0) mirror.generation = 1;
    mirror.region = region;
    mirror.phase_inc = phase_inc;
    mirror.gain_l = region.gain_l;
    mirror.gain_r = region.gain_r;
    mirror.filter = {region.filter_enable, region.filter_b0, region.filter_b1,
                     region.filter_b2, region.filter_a1, region.filter_a2};
    mirror.released = false;
    mirror.active = true;
    driver_.install(voice, mirror.generation, region, phase_inc, true);
  }

  void update_gain_phase(int voice, int gain_l, int gain_r,
                         uint32_t phase_inc) override {
    Mirror& mirror = mirrors_.at(voice);
    if (!mirror.active) return;
    mirror.gain_l = render::clamp_q15(gain_l);
    mirror.gain_r = render::clamp_q15(gain_r);
    mirror.phase_inc = phase_inc;
    if (!apply_update(voice, mirror)) mirror.active = false;
  }

  void update_filter(int voice, const render::FilterConfig& filter) override {
    Mirror& mirror = mirrors_.at(voice);
    if (!mirror.active) return;
    mirror.filter = filter;
    if (!apply_update(voice, mirror)) mirror.active = false;
  }

  void release_voice(int voice, uint32_t release_step_cb_q12_20) override {
    Mirror& mirror = mirrors_.at(voice);
    if (!mirror.active) return;
    mirror.released = true;
    mirror.release_step = release_step_cb_q12_20;
    if (!apply_update(voice, mirror)) mirror.active = false;
  }

  void stop_voice(int voice) override {
    Mirror& mirror = mirrors_.at(voice);
    if (!mirror.active) return;
    mirror.active = false;
    driver_.install(voice, mirror.generation, mirror.region, mirror.phase_inc, false);
  }

 private:
  struct Mirror {
    render::Region region;
    render::FilterConfig filter;
    uint16_t generation = 0;
    uint32_t phase_inc = 1;
    uint32_t release_step = 0;
    int gain_l = 0;
    int gain_r = 0;
    bool released = false;
    bool active = false;
  };

  bool apply_update(int voice, const Mirror& mirror) {
    return driver_.update(
        voice, mirror.generation, mirror.region, mirror.phase_inc,
        mirror.gain_l, mirror.gain_r, mirror.released, mirror.filter,
        mirror.release_step != 0
            ? mirror.release_step
            : render::envelope_release_step(mirror.region));
  }

  RtlDriver& driver_;
  std::array<Mirror, render::kNumVoices> mirrors_{};
};

uint32_t next_boundary(uint32_t frame, uint32_t end_frame,
                       int control_tick_samples,
                       const std::vector<render::NoteEvent>& events) {
  uint32_t result = std::min<uint32_t>(end_frame, frame + 8u);
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
    render::RenderPreparationTiming timing;
    render::RenderInputs inputs = render::load_render_inputs(args, &timing);
    std::vector<int16_t> wave_memory = render::take_sf2_wave_memory(inputs);
    std::vector<render::Region> regions;
    render::prepare_render_regions(args, inputs, wave_memory, regions, &timing);

    std::filesystem::create_directories(args.out_dir);
    RtlDriver driver(context, args.sample_rate);
    RtlVoiceSink sink(driver);
    render::RenderDiagnostics diagnostics;
    diagnostics.detailed_enabled = args.detailed_diagnostics;
    render::McuModel mcu(sink, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);
    const std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    uint32_t frame = 0;
    uint64_t nonzero_words = 0;
    const uint32_t end_frame = uint32_t(inputs.sample_count);
    while (frame < end_frame && !render::interrupt_requested()) {
      timeline.advance_to(int(frame));
      const uint32_t boundary = next_boundary(frame, end_frame,
                                              inputs.control_tick_samples,
                                              inputs.events);
      auto samples = driver.render_block(frame, boundary - frame);
      for (const auto& sample : samples) {
        wav.write_stereo(sample.first, sample.second);
        nonzero_words += sample.first != 0;
        nonzero_words += sample.second != 0;
      }
      frame = boundary;
    }

    if (!render::interrupt_requested() && nonzero_words == 0) {
      throw std::runtime_error("RTL render produced all-zero PCM");
    }
    if (driver.ddr_accepted() != driver.ddr_returned()) {
      throw std::runtime_error("DDR request/response accounting mismatch");
    }

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
              << " cache_sets=" << driver.configured_cache_sets()
              << " cache_bytes=" << driver.configured_cache_bytes()
              << " cache_requests=" << driver.cache_requests()
              << " cache_hits=" << driver.cache_hits()
              << " cache_mshr_merges=" << driver.cache_mshr_merges()
              << " cache_misses=" << driver.cache_misses()
              << " cache_evictions=" << driver.cache_evictions()
              << " cache_miss_stall_cycles="
              << driver.cache_miss_stall_cycles()
              << " stale_parameter_updates="
              << driver.stale_parameter_updates()
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
