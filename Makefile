VERILATOR ?= verilator
BUILD_DIR := build
TOP := tb_wavetable_render_core
NUM_VOICES ?= 256
VERILATOR_JOBS ?= -j 0
MAKE_JOBS ?= -j
RTL_DEFINES := -DSYNTH_NUM_VOICES=$(NUM_VOICES)
CXX_DEFINES := -DRENDER_NUM_VOICES=$(NUM_VOICES)
HARNESS_INCLUDE_FLAGS := \
	-I$(abspath sim/harness) \
	-I$(abspath sim/harness/common) \
	-I$(abspath sim/harness/formats) \
	-I$(abspath sim/harness/render) \
	-I$(abspath sim/harness/control) \
	-I$(abspath sim/harness/dut) \
	-I$(abspath sim/harness/board_loader)
CXX_STD_FLAGS := -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) $(HARNESS_INCLUDE_FLAGS)
HARNESS_CXXFLAGS := -std=c++17 $(CXX_DEFINES) $(HARNESS_INCLUDE_FLAGS)

# Defaults for the SoundFont render flow. Users can override any of these on the
# make command line, for example: make render-instrument INSTRUMENT=10 KEY=64.
SF2 ?= assets/soundfonts/MT6276.sf2
INSTRUMENT ?=
KEY ?= 60
START_SECONDS ?= 0
SECONDS ?= 2
SAMPLE_RATE ?= 48000
CONTROL_TICK_MS ?= 5
SAMPLE_ACCURATE_CONTROL ?= 0
DETAILED_DIAGNOSTICS ?= 0
COMPRESSOR_ENABLE ?= 1
COMPRESSOR_THRESHOLD_CB ?= 20
COMPRESSOR_RATIO ?= 4
COMPRESSOR_ATTACK_MS ?= 0
COMPRESSOR_RELEASE_MS ?= 5000
MASTER_VOLUME ?= 1
EFFECTS_PRESET ?= off
CHORUS_ENABLE ?= auto
REVERB_ENABLE ?= auto
EFFECTS_TAIL_SECONDS ?= 0
MIDI ?=
MEMORY_PROFILE ?= ddr
RENDER_MEMORY_OUT_DIR ?= $(BUILD_DIR)/render_memory
RENDER_REFERENCE_OUT_DIR ?= $(BUILD_DIR)/render_reference
RENDER_RTL_CORE_OUT_DIR ?= $(BUILD_DIR)/render_rtl_core
RENDER_BOARD_LOADER_OUT_DIR ?= $(BUILD_DIR)/render_board_loader
WTSF_IMAGE ?= $(BUILD_DIR)/assets/wavetable.wtsf.img
WTSF_SF2_START_LBA ?= 1
WTSF_CRC ?=
SD_DEVICE ?=
RENDER_OPT_FAST ?= -O3
RENDER_OPT_GLOBAL ?= $(RENDER_OPT_FAST)

RTL_FILELIST := rtl/filelist.f
RTL_SOURCES := $(addprefix rtl/,$(shell sed -e '/^[[:space:]]*\#/d' -e '/^[[:space:]]*$$/d' $(RTL_FILELIST)))

FPGA_COMMON_RTL_SOURCES := \
	fpga/common/rtl/fractional_tick_gen.sv \
	fpga/common/rtl/spi_register_bridge.sv \
	fpga/common/rtl/wavetable_register_fabric.sv \
	fpga/common/rtl/wavetable_common_status_regs.sv \
	fpga/common/rtl/i2s_tx.sv \
	fpga/common/rtl/sd_native_pkg.sv \
	fpga/common/rtl/sd_native_block_reader.sv \
	fpga/common/rtl/sd_native_pin_phy.sv \
	fpga/common/rtl/wavetable_system_core.sv \
	fpga/common/rtl/wavetable_i2s_output.sv \
	fpga/common/rtl/wavetable_demo_system.sv

SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wavetable_render_core.sv

SPI_SIM_SOURCES := \
	sim/tb/tb_spi_register_bridge.sv

MEMORY_SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wave_memory_subsystem.sv

VOICE_LINE_CACHE_SIM_SOURCES := \
	sim/tb/tb_voice_line_cache.sv

CACHED_RENDER_COUNTER_SIM_SOURCES := \
	sim/tb/tb_wavetable_cached_render_core_counters.sv

I2S_SIM_SOURCES := \
	sim/tb/tb_i2s_tx.sv

I2S_OUTPUT_SIM_SOURCES := \
	sim/tb/tb_wavetable_i2s_output.sv

COMPRESSOR_SIM_SOURCES := \
	sim/tb/tb_lookahead_compressor.sv

CHORUS_SIM_SOURCES := \
	sim/tb/tb_stereo_chorus.sv

REVERB_SIM_SOURCES := \
	sim/tb/tb_fdn_reverb.sv

EFFECT_MIXER_SIM_SOURCES := \
	sim/tb/tb_effect_return_mixer.sv

GLOBAL_EFFECTS_SIM_SOURCES := \
	sim/tb/tb_global_effects_chain.sv

GLOBAL_AUDIO_EFFECTS_SIM_SOURCES := \
	sim/tb/tb_global_audio_effects_chain.sv

RENDER_SCHEDULER_SIM_SOURCES := \
	sim/tb/tb_render_credit_scheduler.sv

COMMON_STATUS_SIM_SOURCES := \
	sim/tb/tb_wavetable_demo_common_status.sv

VOICE_PHASE_SIM_SOURCES := \
	sim/tb/tb_voice_phase_frame.sv

CONTROL_CMD_SIM_SOURCES := \
	sim/tb/tb_control_cmd_parser.sv

CONTROL_WORD_FIFO_SIM_SOURCES := \
	sim/tb/tb_control_word_fifo.sv

TRANSACTIONAL_CONTROL_SIM_SOURCES := \
	sim/tb/tb_transactional_control_plane.sv

HARNESS_RENDER_COMMON_SRCS := \
	$(abspath sim/harness/render/render_support.cpp) \
	$(abspath sim/harness/render/render_args.cpp) \
	$(abspath sim/harness/render/render_report.cpp) \
	$(abspath sim/harness/render/render_session.cpp) \
	$(abspath sim/harness/control/command_control.cpp) \
	$(abspath sim/harness/formats/midi_parser.cpp) \
	$(abspath sim/harness/formats/sf2_loader.cpp)

HARNESS_WAV_SRC := \
	$(abspath sim/harness/common/wav_writer.cpp)

HARNESS_INTERRUPT_SRC := \
	$(abspath sim/harness/common/render_interrupt.cpp)

HARNESS_MEMORY_PROFILE_SRC := \
	$(abspath sim/harness/common/memory_profile.cpp)

HARNESS_BOARD_LOADER_SRCS := \
	$(abspath sim/harness/board_loader/board_loader_render_harness.cpp) \
	$(abspath sim/harness/board_loader/board_loader_render_utils.cpp)

SMART_ARTIX_RTL_SOURCES := \
	rtl/pkg/synth_register_pkg.sv \
	fpga/common/rtl/sd_native_pkg.sv \
	fpga/common/rtl/sd_native_block_reader.sv \
	fpga/common/rtl/sd_native_pin_phy.sv \
	fpga/smart_artix/rtl/smart_artix_pkg.sv \
	fpga/smart_artix/rtl/smart_artix_sd_card_detect.sv \
	fpga/smart_artix/rtl/smart_artix_asset_loader.sv \
	fpga/smart_artix/rtl/smart_artix_ddr3_asset_writer.sv \
	fpga/smart_artix/rtl/smart_artix_sd_native_asset_loader.sv \
	fpga/smart_artix/rtl/smart_artix_mig_stub.sv \
	fpga/smart_artix/rtl/smart_artix_ddr3_reg_access_master.sv \
	fpga/smart_artix/rtl/smart_artix_ddr3_line_reader.sv \
	fpga/smart_artix/rtl/smart_artix_ddr3_rw_arbiter.sv \
	fpga/smart_artix/rtl/smart_artix_ddr3_subsystem.sv \
	fpga/smart_artix/rtl/smart_artix_platform_regs.sv

SMART_ARTIX_SIM_MODELS := \
	fpga/common/sim/fake_sd_native_phy_model.sv \
	fpga/common/sim/fake_sd_native_pin_model.sv

SMART_ARTIX_WITH_CORE_RTL_SOURCES := \
	$(filter-out rtl/pkg/synth_register_pkg.sv,$(SMART_ARTIX_RTL_SOURCES))

SMART_ARTIX_TESTBENCHES := \
	tb_smart_artix_asset_loader \
	tb_smart_artix_ddr3_asset_writer \
	tb_smart_artix_ddr3_reg_access_master \
	tb_smart_artix_ddr3_line_reader \
	tb_smart_artix_ddr3_rw_arbiter \
	tb_smart_artix_mig_stub \
	tb_smart_artix_platform_regs \
	tb_smart_artix_sd_card_detect \
	tb_smart_artix_sd_native_asset_loader \
	tb_sd_native_block_reader \
	tb_sd_native_block_reader_fake \
	tb_sd_native_pin_phy \
	tb_sd_native_pin_phy_fake

.PHONY: all generate-register-map generate-dsp-lut check-register-map check-dsp-lut lint test test-cpp-unit test-rtl-core test-rtl-peripheral smart-artix-test $(SMART_ARTIX_TESTBENCHES) host-ch347 host-smart-artix-bringup list-instruments wtsf-image verify-wtsf-image flash-wtsf-sd render-instrument render-reference render-rtl-core render-memory render-board-loader vivado-summary clean

all: test

generate-register-map:
	python3 tools/gen_register_map.py
	python3 tools/gen_dsp_lut.py

generate-dsp-lut:
	python3 tools/gen_dsp_lut.py

check-register-map:
	python3 tools/gen_register_map.py --check
	python3 tools/gen_dsp_lut.py --check

check-dsp-lut:
	python3 tools/gen_dsp_lut.py --check

lint:
	# Lint only synthesizable RTL; simulation models and testbenches are excluded.
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module stereo_chorus \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv rtl/audio/stereo_chorus.sv
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module fdn_reverb \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv rtl/audio/fdn_reverb.sv
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module effect_return_mixer \
		rtl/pkg/synth_pkg.sv rtl/audio/effect_return_mixer.sv
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module global_effects_chain \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/stereo_chorus.sv rtl/audio/fdn_reverb.sv \
		rtl/audio/effect_return_mixer.sv rtl/audio/global_effects_chain.sv
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module global_audio_effects_chain \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/stereo_chorus.sv rtl/audio/fdn_reverb.sv \
		rtl/audio/effect_return_mixer.sv rtl/audio/global_effects_chain.sv \
		rtl/audio/lookahead_compressor.sv rtl/audio/global_audio_effects_chain.sv
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_render_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_cached_render_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wave_memory_subsystem $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_system_core $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_i2s_output $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_demo_system $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module i2s_tx rtl/pkg/synth_pkg.sv fpga/common/rtl/fractional_tick_gen.sv fpga/common/rtl/i2s_tx.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module sd_native_block_reader \
		fpga/common/rtl/sd_native_pkg.sv fpga/common/rtl/sd_native_block_reader.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module sd_native_pin_phy \
		fpga/common/rtl/sd_native_pkg.sv fpga/common/rtl/sd_native_pin_phy.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module smart_artix_ddr3_subsystem \
		$(SMART_ARTIX_RTL_SOURCES)

test: test-cpp-unit test-rtl-core test-rtl-peripheral

test-cpp-unit:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/formats/midi_parser.cpp sim/harness/formats/midi_parser_test.cpp \
		-o $(BUILD_DIR)/midi_parser_test
	$(BUILD_DIR)/midi_parser_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/control/command_control.cpp sim/harness/control/command_control_test.cpp \
		-o $(BUILD_DIR)/command_control_test
	$(BUILD_DIR)/command_control_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/control/command_control.cpp \
		sim/harness/render/lookahead_compressor_model.cpp \
		sim/harness/render/lookahead_compressor_model_test.cpp \
		-o $(BUILD_DIR)/lookahead_compressor_model_test
	$(BUILD_DIR)/lookahead_compressor_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/stereo_chorus_model.cpp \
		sim/harness/render/stereo_chorus_model_test.cpp \
		-o $(BUILD_DIR)/stereo_chorus_model_test
	$(BUILD_DIR)/stereo_chorus_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/fdn_reverb_model.cpp \
		sim/harness/render/fdn_reverb_model_test.cpp \
		-o $(BUILD_DIR)/fdn_reverb_model_test
	$(BUILD_DIR)/fdn_reverb_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/effect_return_mixer_model.cpp \
		sim/harness/render/effect_return_mixer_model_test.cpp \
		-o $(BUILD_DIR)/effect_return_mixer_model_test
	$(BUILD_DIR)/effect_return_mixer_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/control/command_control.cpp \
		sim/harness/render/stereo_chorus_model.cpp \
		sim/harness/render/fdn_reverb_model.cpp \
		sim/harness/render/effect_return_mixer_model.cpp \
		sim/harness/render/global_effects_model.cpp \
		sim/harness/render/global_effects_model_test.cpp \
		-o $(BUILD_DIR)/global_effects_model_test
	$(BUILD_DIR)/global_effects_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/formats/sf2_loader.cpp sim/harness/formats/sf2_loader_test.cpp \
		-o $(BUILD_DIR)/sf2_loader_test
	$(BUILD_DIR)/sf2_loader_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/render_support.cpp sim/harness/control/command_control.cpp \
		sim/harness/formats/sf2_loader.cpp \
		sim/harness/render/reference_synth.cpp \
		sim/harness/formats/midi_parser.cpp sim/harness/render/render_args.cpp \
		sim/harness/render/render_report.cpp sim/harness/render/render_session.cpp \
		sim/harness/render/render_support_test.cpp \
		-o $(BUILD_DIR)/render_support_test
	$(BUILD_DIR)/render_support_test
	python3 tools/compare_reference_fluidsynth_test.py

test-rtl-core:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/control_word_fifo_obj_dir --top-module tb_control_word_fifo \
		$(RTL_SOURCES) $(CONTROL_WORD_FIFO_SIM_SOURCES)
	$(BUILD_DIR)/control_word_fifo_obj_dir/Vtb_control_word_fifo
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_phase_obj_dir --top-module tb_voice_phase_frame \
		$(RTL_SOURCES) $(VOICE_PHASE_SIM_SOURCES)
	$(BUILD_DIR)/voice_phase_obj_dir/Vtb_voice_phase_frame
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/control_cmd_obj_dir --top-module tb_control_cmd_parser \
		$(RTL_SOURCES) $(CONTROL_CMD_SIM_SOURCES)
	$(BUILD_DIR)/control_cmd_obj_dir/Vtb_control_cmd_parser
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/transactional_control_obj_dir --top-module tb_transactional_control_plane \
		$(RTL_SOURCES) $(TRANSACTIONAL_CONTROL_SIM_SOURCES)
	$(BUILD_DIR)/transactional_control_obj_dir/Vtb_transactional_control_plane
	# Build and run the self-checking synthetic-data regression.
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/memory_obj_dir --top-module tb_wave_memory_subsystem \
		$(RTL_SOURCES) $(MEMORY_SIM_SOURCES)
	$(BUILD_DIR)/memory_obj_dir/Vtb_wave_memory_subsystem
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_line_cache_obj_dir --top-module tb_voice_line_cache \
		$(RTL_SOURCES) $(VOICE_LINE_CACHE_SIM_SOURCES)
	$(BUILD_DIR)/voice_line_cache_obj_dir/Vtb_voice_line_cache
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/cached_render_counter_obj_dir --top-module tb_wavetable_cached_render_core_counters \
		$(RTL_SOURCES) $(CACHED_RENDER_COUNTER_SIM_SOURCES)
	$(BUILD_DIR)/cached_render_counter_obj_dir/Vtb_wavetable_cached_render_core_counters

test-rtl-peripheral:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/chorus_obj_dir --top-module tb_stereo_chorus \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/stereo_chorus.sv $(CHORUS_SIM_SOURCES)
	$(BUILD_DIR)/chorus_obj_dir/Vtb_stereo_chorus
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/reverb_obj_dir --top-module tb_fdn_reverb \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/fdn_reverb.sv $(REVERB_SIM_SOURCES)
	$(BUILD_DIR)/reverb_obj_dir/Vtb_fdn_reverb
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/effect_mixer_obj_dir --top-module tb_effect_return_mixer \
		rtl/pkg/synth_pkg.sv rtl/audio/effect_return_mixer.sv $(EFFECT_MIXER_SIM_SOURCES)
	$(BUILD_DIR)/effect_mixer_obj_dir/Vtb_effect_return_mixer
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/global_effects_obj_dir --top-module tb_global_effects_chain \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/stereo_chorus.sv rtl/audio/fdn_reverb.sv \
		rtl/audio/effect_return_mixer.sv rtl/audio/global_effects_chain.sv \
		$(GLOBAL_EFFECTS_SIM_SOURCES)
	$(BUILD_DIR)/global_effects_obj_dir/Vtb_global_effects_chain
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/global_audio_effects_obj_dir \
		--top-module tb_global_audio_effects_chain \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/stereo_chorus.sv rtl/audio/fdn_reverb.sv \
		rtl/audio/effect_return_mixer.sv rtl/audio/global_effects_chain.sv \
		rtl/audio/lookahead_compressor.sv rtl/audio/global_audio_effects_chain.sv \
		$(GLOBAL_AUDIO_EFFECTS_SIM_SOURCES)
	$(BUILD_DIR)/global_audio_effects_obj_dir/Vtb_global_audio_effects_chain
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/compressor_obj_dir --top-module tb_lookahead_compressor \
		rtl/pkg/synth_pkg.sv rtl/generated/synth_dsp_lut_pkg.sv \
		rtl/audio/lookahead_compressor.sv $(COMPRESSOR_SIM_SOURCES)
	$(BUILD_DIR)/compressor_obj_dir/Vtb_lookahead_compressor
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_scheduler_obj_dir --top-module tb_render_credit_scheduler \
		rtl/audio/render_credit_scheduler.sv $(RENDER_SCHEDULER_SIM_SOURCES)
	$(BUILD_DIR)/render_scheduler_obj_dir/Vtb_render_credit_scheduler
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/i2s_output_obj_dir --top-module tb_wavetable_i2s_output \
		rtl/pkg/synth_pkg.sv rtl/audio/output_sample_fifo.sv \
		fpga/common/rtl/fractional_tick_gen.sv fpga/common/rtl/i2s_tx.sv \
		fpga/common/rtl/wavetable_i2s_output.sv $(I2S_OUTPUT_SIM_SOURCES)
	$(BUILD_DIR)/i2s_output_obj_dir/Vtb_wavetable_i2s_output
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/spi_obj_dir --top-module tb_spi_register_bridge \
		$(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES) $(SPI_SIM_SOURCES)
	$(BUILD_DIR)/spi_obj_dir/Vtb_spi_register_bridge
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/i2s_obj_dir --top-module tb_i2s_tx \
		rtl/pkg/synth_pkg.sv fpga/common/rtl/fractional_tick_gen.sv fpga/common/rtl/i2s_tx.sv $(I2S_SIM_SOURCES)
	$(BUILD_DIR)/i2s_obj_dir/Vtb_i2s_tx
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/common_status_obj_dir --top-module tb_wavetable_demo_common_status \
		$(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES) $(COMMON_STATUS_SIM_SOURCES)
	$(BUILD_DIR)/common_status_obj_dir/Vtb_wavetable_demo_common_status

smart-artix-test: $(SMART_ARTIX_TESTBENCHES)

$(SMART_ARTIX_TESTBENCHES):
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary -j 1 --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/$@_obj_dir --top-module $@ \
		$(SMART_ARTIX_RTL_SOURCES) $(SMART_ARTIX_SIM_MODELS) \
		$(if $(wildcard fpga/smart_artix/sim/$@.sv),fpga/smart_artix/sim/$@.sv,fpga/common/sim/$@.sv)
	$(BUILD_DIR)/$@_obj_dir/V$@

host-ch347:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) -I. \
		host/ch347_control_main.cpp host/ch347_transport.cpp \
		sim/harness/control/command_control.cpp \
		-o $(BUILD_DIR)/ch347_control -ldl

host-smart-artix-bringup:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) -I. \
		host/smart_artix_bringup_main.cpp host/ch347_transport.cpp \
		sim/harness/control/command_control.cpp \
		-o $(BUILD_DIR)/smart_artix_bringup -ldl

list-instruments:
	# Inspect instrument names from the configured SF2 without running RTL.
	python3 tools/sf2_extract.py --sf2 "$(SF2)" --list-instruments

wtsf-image:
	python3 tools/make_wtsf_image.py build --sf2 "$(SF2)" --out "$(WTSF_IMAGE)" \
		--sf2-start-lba $(WTSF_SF2_START_LBA) $(if $(WTSF_CRC),--crc,)

verify-wtsf-image:
	python3 tools/make_wtsf_image.py verify "$(WTSF_IMAGE)"

flash-wtsf-sd: verify-wtsf-image
	@if [ -z "$(SD_DEVICE)" ]; then \
		echo "Set SD_DEVICE=/dev/sdX or /dev/mmcblkX" >&2; \
		exit 2; \
	fi
	tools/flash_wtsf_sd.sh --image "$(WTSF_IMAGE)" --device "$(SD_DEVICE)" --yes

render-instrument:
	# 1. Extract one instrument zone to wave.memh plus render_config.svh.
	python3 tools/sf2_extract.py --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(BUILD_DIR)/render
	# 2. Build and execute the render testbench against the generated memory.
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		-I$(BUILD_DIR)/render --Mdir $(BUILD_DIR)/render_obj_dir \
		--top-module tb_wavetable_render_core_asset \
		$(RTL_SOURCES) sim/models/line_memory_model.sv sim/tb/tb_wavetable_render_core_asset.sv
	$(BUILD_DIR)/render_obj_dir/Vtb_wavetable_render_core_asset
	# 3. Convert the raw stereo PCM stream into a playable WAV file.
	python3 tools/pcm_to_wav.py --pcm $(BUILD_DIR)/render/out.pcm \
		--wav $(BUILD_DIR)/render/out.wav --sample-rate $(SAMPLE_RATE)

render-reference:
	# Build and run the pure C++ SF2/MIDI reference synthesizer.
	mkdir -p $(RENDER_REFERENCE_OUT_DIR)
	$(CXX) $(CXX_STD_FLAGS) $(RENDER_OPT_GLOBAL) \
		$(abspath sim/harness/apps/render_reference_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_WAV_SRC) \
		$(HARNESS_INTERRUPT_SRC) \
		$(abspath sim/harness/render/reference_synth.cpp) \
		$(abspath sim/harness/render/lookahead_compressor_model.cpp) \
		$(abspath sim/harness/render/stereo_chorus_model.cpp) \
		$(abspath sim/harness/render/fdn_reverb_model.cpp) \
		$(abspath sim/harness/render/effect_return_mixer_model.cpp) \
		$(abspath sim/harness/render/global_effects_model.cpp) \
		-o $(BUILD_DIR)/render_reference_cpp
	$(BUILD_DIR)/render_reference_cpp --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--start-seconds $(START_SECONDS) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--control-tick-ms $(CONTROL_TICK_MS) \
		$(if $(filter 1 true yes,$(SAMPLE_ACCURATE_CONTROL)),--sample-accurate-control,) \
		$(if $(filter 1 true yes,$(DETAILED_DIAGNOSTICS)),--detailed-diagnostics,) \
		$(if $(filter 1 true yes,$(COMPRESSOR_ENABLE)),--compressor-enable,) \
		--compressor-threshold-cb $(COMPRESSOR_THRESHOLD_CB) \
		--compressor-ratio $(COMPRESSOR_RATIO) \
		--compressor-attack-ms $(COMPRESSOR_ATTACK_MS) \
		--compressor-release-ms $(COMPRESSOR_RELEASE_MS) \
		--master-volume $(MASTER_VOLUME) \
		--effects-preset $(EFFECTS_PRESET) \
		--chorus-enable $(CHORUS_ENABLE) \
		--reverb-enable $(REVERB_ENABLE) \
		--effects-tail-seconds $(EFFECTS_TAIL_SECONDS) \
		--out-dir $(RENDER_REFERENCE_OUT_DIR)

render-rtl-core:
	# Build and run the C++ reference-vs-RTL harness against wavetable_render_core.
	mkdir -p $(RENDER_RTL_CORE_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_rtl_core_cpp_obj_dir --top-module wavetable_render_core \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/apps/render_rtl_core_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_WAV_SRC) \
		$(HARNESS_INTERRUPT_SRC) \
		$(abspath sim/harness/render/reference_synth.cpp) \
		$(abspath sim/harness/dut/core_rtl_harness.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_rtl_core_cpp_obj_dir -f Vwavetable_render_core.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_rtl_core_cpp_obj_dir/Vwavetable_render_core --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--start-seconds $(START_SECONDS) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--control-tick-ms $(CONTROL_TICK_MS) \
		$(if $(filter 1 true yes,$(SAMPLE_ACCURATE_CONTROL)),--sample-accurate-control,) \
		$(if $(filter 1 true yes,$(DETAILED_DIAGNOSTICS)),--detailed-diagnostics,) \
		--out-dir $(RENDER_RTL_CORE_OUT_DIR)

render-memory:
	# Build and run the C++ MIDI/SF2 memory-profile harness against wavetable_cached_render_core.
	mkdir -p $(RENDER_MEMORY_OUT_DIR)
	rm -f $(RENDER_MEMORY_OUT_DIR)/out.pcm
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_memory_cpp_obj_dir --top-module wavetable_cached_render_core \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/apps/render_memory_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_MEMORY_PROFILE_SRC) \
		$(HARNESS_WAV_SRC) \
		$(HARNESS_INTERRUPT_SRC) \
		$(abspath sim/harness/dut/rtl_harness.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_memory_cpp_obj_dir -f Vwavetable_cached_render_core.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_memory_cpp_obj_dir/Vwavetable_cached_render_core --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--start-seconds $(START_SECONDS) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--control-tick-ms $(CONTROL_TICK_MS) \
		$(if $(filter 1 true yes,$(SAMPLE_ACCURATE_CONTROL)),--sample-accurate-control,) \
		$(if $(filter 1 true yes,$(DETAILED_DIAGNOSTICS)),--detailed-diagnostics,) \
		--out-dir $(RENDER_MEMORY_OUT_DIR)

render-board-loader:
	# Build and run SD-native-loader-to-DDR plus RTL/reference wavetable render.
	mkdir -p $(RENDER_BOARD_LOADER_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_board_loader_cpp_obj_dir \
		--top-module board_loader_render_tops \
		$(RTL_SOURCES) $(SMART_ARTIX_WITH_CORE_RTL_SOURCES) sim/tb/board_loader_render_tops.sv --exe \
		$(abspath sim/harness/apps/board_loader_render_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_MEMORY_PROFILE_SRC) \
		$(HARNESS_WAV_SRC) \
		$(HARNESS_INTERRUPT_SRC) \
		$(HARNESS_BOARD_LOADER_SRCS) \
		$(abspath sim/harness/render/reference_synth.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_board_loader_cpp_obj_dir -f Vboard_loader_render_tops.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_board_loader_cpp_obj_dir/Vboard_loader_render_tops --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--start-seconds $(START_SECONDS) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--control-tick-ms $(CONTROL_TICK_MS) \
		$(if $(filter 1 true yes,$(SAMPLE_ACCURATE_CONTROL)),--sample-accurate-control,) \
		$(if $(filter 1 true yes,$(DETAILED_DIAGNOSTICS)),--detailed-diagnostics,) \
		--out-dir $(RENDER_BOARD_LOADER_OUT_DIR)

vivado-summary:
	python3 tools/vivado_report_summary.py show

clean:
	rm -rf $(BUILD_DIR)
