VERILATOR ?= verilator
VIVADO ?= vivado
BUILD_DIR := build
NUM_VOICES ?= 512
BLOCK_WORK_ENTRIES ?= 8
VERILATOR_JOBS ?= -j 0
MAKE_JOBS ?= -j
RTL_DEFINES := -DSYNTH_NUM_VOICES=$(NUM_VOICES) \
	-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES)
CXX_DEFINES := -DRENDER_NUM_VOICES=$(NUM_VOICES)
VIVADO_BUILD_DIR := $(BUILD_DIR)/fpga/smart_artix/vivado
VIVADO_SCRIPT_DIR := $(abspath fpga/smart_artix/vivado/scripts)
VIVADO_CONFIG_ENV := SYNTH_NUM_VOICES=$(NUM_VOICES) \
	SYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES)
HARNESS_INCLUDE_FLAGS := \
	-I$(abspath sim/harness) \
	-I$(abspath sim/harness/common) \
	-I$(abspath sim/harness/formats) \
	-I$(abspath sim/harness/render) \
	-I$(abspath sim/harness/control)
CXX_STD_FLAGS := -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) $(HARNESS_INCLUDE_FLAGS)
HARNESS_CXXFLAGS := -std=c++17 $(CXX_DEFINES) $(HARNESS_INCLUDE_FLAGS)

# Defaults for the C++ SoundFont reference-render flow.
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
RENDER_REFERENCE_OUT_DIR ?= $(BUILD_DIR)/render_reference
RENDER_RTL_OUT_DIR ?= $(BUILD_DIR)/render_rtl_ddr3
RENDER_RTL_OBJ_DIR = $(BUILD_DIR)/render_rtl_ddr3_obj_dir
WTSF_IMAGE ?= $(BUILD_DIR)/assets/wavetable.wtsf.img
WTSF_SF2_START_LBA ?= 1
WTSF_CRC ?=
SD_DEVICE ?=
DDR3_IMAGE ?=
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
	fpga/common/rtl/wavetable_i2s_output.sv \
	fpga/common/rtl/voice_major_system.sv

SPI_SIM_SOURCES := \
	sim/tb/tb_spi_register_bridge.sv

I2S_SIM_SOURCES := \
	sim/tb/tb_i2s_tx.sv

I2S_OUTPUT_SIM_SOURCES := \
	sim/tb/tb_wavetable_i2s_output.sv

COMMON_STATUS_SIM_SOURCES := \
	sim/tb/tb_wavetable_common_status_regs.sv

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

BLOCK_MIX_BUFFER_SIM_SOURCES := \
	sim/tb/tb_block_mix_buffer.sv

BLOCK_INTERLEAVED_DSP_SIM_SOURCES := \
	sim/tb/tb_block_interleaved_voice_dsp.sv

BLOCK_INTERLEAVED_RENDERER_SIM_SOURCES := \
	sim/tb/tb_block_interleaved_voice_renderer.sv

BLOCK_INTERLEAVED_ENVELOPE_SIM_SOURCES := \
	sim/tb/tb_block_interleaved_envelope_frontend.sv

BLOCK_MONO_ENGINE_SIM_SOURCES := \
	sim/tb/tb_block_mono_voice_engine.sv

VOICE_MAJOR_CONTROLLER_SIM_SOURCES := \
	sim/tb/tb_voice_major_block_controller.sv

BLOCK_VOICE_STATE_STORE_SIM_SOURCES := \
	sim/tb/tb_block_voice_state_store.sv

VOICE_MAJOR_RENDER_CORE_SIM_SOURCES := \
	sim/tb/tb_voice_major_render_core.sv

VOICE_MAJOR_THROUGHPUT_SIM_SOURCES := \
	sim/tb/tb_voice_major_throughput.sv

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

.PHONY: all generate-register-map generate-dsp-lut check-register-map check-dsp-lut lint test test-cpp-unit test-rtl-core test-rtl-peripheral test-sample-window test-ddr3-model test-voice-major-512 measure-voice-compute-pipeline measure-voice-major-throughput measure-voice-major-throughput-filtered measure-voice-major-throughput-ddr3 measure-voice-major-throughput-512 measure-voice-major-throughput-512-filtered measure-voice-major-throughput-512-ddr3 measure-voice-major-throughput-512-ddr3-filtered smart-artix-test $(SMART_ARTIX_TESTBENCHES) host-ch347 host-smart-artix-bringup list-instruments wtsf-image verify-wtsf-image flash-wtsf-sd render-reference render-rtl-ddr3 vivado-project vivado-synth vivado-impl vivado-bitstream vivado-summary clean

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
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module voice_major_render_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module voice_major_system $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_i2s_output $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module i2s_tx rtl/pkg/synth_pkg.sv fpga/common/rtl/fractional_tick_gen.sv fpga/common/rtl/i2s_tx.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module sd_native_block_reader \
		fpga/common/rtl/sd_native_pkg.sv fpga/common/rtl/sd_native_block_reader.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module sd_native_pin_phy \
		fpga/common/rtl/sd_native_pkg.sv fpga/common/rtl/sd_native_pin_phy.sv
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module smart_artix_ddr3_subsystem \
		$(SMART_ARTIX_RTL_SOURCES)

test: test-cpp-unit test-rtl-core test-rtl-peripheral test-sample-window test-ddr3-model

test-sample-window:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_sample_window_obj_dir \
		--top-module tb_voice_sample_window \
		rtl/pkg/synth_pkg.sv rtl/memory/voice_sample_window.sv \
		sim/tb/tb_voice_sample_window.sv
	$(BUILD_DIR)/voice_sample_window_obj_dir/Vtb_voice_sample_window

test-ddr3-model:
	mkdir -p $(BUILD_DIR)/ddr3_test_image
	printf '\000\020\001\020\002\020\003\020\004\020\005\020\006\020\007\020' > $(BUILD_DIR)/ddr3_test_image/00000000.bin
	printf '\000\040\001\040\002\040\003\040\004\040\005\040\006\040\007\040' > $(BUILD_DIR)/ddr3_test_image/00000008.bin
	printf '\000\060\001\060\002\060\003\060\004\060\005\060\006\060\007\060' > $(BUILD_DIR)/ddr3_test_image/00000010.bin
	printf '\000\100\001\100\002\100\003\100\004\100\005\100\006\100\007\100' > $(BUILD_DIR)/ddr3_test_image/00000020.bin
	$(VERILATOR) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/ddr3_timing_model_obj_dir --top-module tb_ddr3_timing_model \
		sim/models/ddr3_timing_model.sv sim/tb/tb_ddr3_timing_model.sv \
		$(abspath sim/harness/memory/ddr3_bin_store.cpp)
	$(BUILD_DIR)/ddr3_timing_model_obj_dir/Vtb_ddr3_timing_model \
		+DDR3_IMAGE=$(abspath $(BUILD_DIR)/ddr3_test_image)

test-voice-major-512:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -DSYNTH_NUM_VOICES=512 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_render_core_512_obj_dir \
		--top-module tb_voice_major_render_core \
		$(RTL_SOURCES) $(VOICE_MAJOR_RENDER_CORE_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_render_core_512_obj_dir/Vtb_voice_major_render_core

measure-voice-major-throughput:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -DSYNTH_NUM_VOICES=256 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) $(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_throughput_obj_dir/Vtb_voice_major_throughput

measure-voice-major-throughput-filtered:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -DSYNTH_NUM_VOICES=256 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) -DSYNTH_FILTER_ENABLE \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_filtered_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) $(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_throughput_filtered_obj_dir/Vtb_voice_major_throughput

measure-voice-major-throughput-ddr3:
	mkdir -p $(BUILD_DIR)/ddr3_render_image
	printf '\144\000' > $(BUILD_DIR)/ddr3_render_image/00000060.bin
	$(VERILATOR) -DSYNTH_NUM_VOICES=256 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) -DSYNTH_DDR3_MODEL \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_ddr3_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) sim/models/ddr3_timing_model.sv \
		sim/models/ordered_line_ddr3_bridge_model.sv \
		$(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES) \
		$(abspath sim/harness/memory/ddr3_bin_store.cpp)
	$(BUILD_DIR)/voice_major_throughput_ddr3_obj_dir/Vtb_voice_major_throughput \
		+DDR3_IMAGE=$(if $(DDR3_IMAGE),$(abspath $(DDR3_IMAGE)),$(abspath $(BUILD_DIR)/ddr3_render_image))

measure-voice-major-throughput-512:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -DSYNTH_NUM_VOICES=512 -DSYNTH_ACTIVE_LANES=512 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_512_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) $(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_throughput_512_obj_dir/Vtb_voice_major_throughput

measure-voice-major-throughput-512-filtered:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) -DSYNTH_NUM_VOICES=512 -DSYNTH_ACTIVE_LANES=512 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) \
		-DSYNTH_FILTER_ENABLE --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_512_filtered_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) $(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_throughput_512_filtered_obj_dir/Vtb_voice_major_throughput

measure-voice-major-throughput-512-ddr3:
	mkdir -p $(BUILD_DIR)/ddr3_render_image
	printf '\144\000' > $(BUILD_DIR)/ddr3_render_image/00000060.bin
	$(VERILATOR) -DSYNTH_NUM_VOICES=512 -DSYNTH_ACTIVE_LANES=512 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) -DSYNTH_DDR3_MODEL \
		--binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_512_ddr3_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) sim/models/ddr3_timing_model.sv \
		sim/models/ordered_line_ddr3_bridge_model.sv \
		$(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES) \
		$(abspath sim/harness/memory/ddr3_bin_store.cpp)
	$(BUILD_DIR)/voice_major_throughput_512_ddr3_obj_dir/Vtb_voice_major_throughput \
		+DDR3_IMAGE=$(if $(DDR3_IMAGE),$(abspath $(DDR3_IMAGE)),$(abspath $(BUILD_DIR)/ddr3_render_image))

measure-voice-major-throughput-512-ddr3-filtered:
	mkdir -p $(BUILD_DIR)/ddr3_render_image
	printf '\144\000' > $(BUILD_DIR)/ddr3_render_image/00000060.bin
	$(VERILATOR) -DSYNTH_NUM_VOICES=512 -DSYNTH_ACTIVE_LANES=512 \
		-DSYNTH_BLOCK_WORK_ENTRY_COUNT=$(BLOCK_WORK_ENTRIES) -DSYNTH_DDR3_MODEL \
		-DSYNTH_FILTER_ENABLE --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_throughput_512_ddr3_filtered_obj_dir \
		--top-module tb_voice_major_throughput \
		$(RTL_SOURCES) sim/models/ddr3_timing_model.sv \
		sim/models/ordered_line_ddr3_bridge_model.sv \
		$(VOICE_MAJOR_THROUGHPUT_SIM_SOURCES) \
		$(abspath sim/harness/memory/ddr3_bin_store.cpp)
	$(BUILD_DIR)/voice_major_throughput_512_ddr3_filtered_obj_dir/Vtb_voice_major_throughput \
		+DDR3_IMAGE=$(if $(DDR3_IMAGE),$(abspath $(DDR3_IMAGE)),$(abspath $(BUILD_DIR)/ddr3_render_image))

measure-voice-compute-pipeline:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/voice_compute_pipeline_model.cpp \
		sim/harness/render/voice_compute_pipeline_model_test.cpp \
		-o $(BUILD_DIR)/voice_compute_pipeline_model_test
	$(BUILD_DIR)/voice_compute_pipeline_model_test

test-cpp-unit:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/voice_compute_pipeline_model.cpp \
		sim/harness/render/voice_compute_pipeline_model_test.cpp \
		-o $(BUILD_DIR)/voice_compute_pipeline_model_test
	$(BUILD_DIR)/voice_compute_pipeline_model_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/block_scheduler.cpp \
		sim/harness/render/block_scheduler_test.cpp \
		-o $(BUILD_DIR)/block_scheduler_test
	$(BUILD_DIR)/block_scheduler_test
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
		--Mdir $(BUILD_DIR)/voice_major_render_core_obj_dir --top-module tb_voice_major_render_core \
		$(RTL_SOURCES) $(VOICE_MAJOR_RENDER_CORE_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_render_core_obj_dir/Vtb_voice_major_render_core
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_voice_state_store_obj_dir --top-module tb_block_voice_state_store \
		$(RTL_SOURCES) $(BLOCK_VOICE_STATE_STORE_SIM_SOURCES)
	$(BUILD_DIR)/block_voice_state_store_obj_dir/Vtb_block_voice_state_store
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_major_controller_obj_dir --top-module tb_voice_major_block_controller \
		$(RTL_SOURCES) $(VOICE_MAJOR_CONTROLLER_SIM_SOURCES)
	$(BUILD_DIR)/voice_major_controller_obj_dir/Vtb_voice_major_block_controller
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_mono_engine_obj_dir --top-module tb_block_mono_voice_engine \
		$(RTL_SOURCES) $(BLOCK_MONO_ENGINE_SIM_SOURCES)
	$(BUILD_DIR)/block_mono_engine_obj_dir/Vtb_block_mono_voice_engine
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_interleaved_envelope_obj_dir \
		--top-module tb_block_interleaved_envelope_frontend \
		$(RTL_SOURCES) $(BLOCK_INTERLEAVED_ENVELOPE_SIM_SOURCES)
	$(BUILD_DIR)/block_interleaved_envelope_obj_dir/Vtb_block_interleaved_envelope_frontend
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_interleaved_renderer_obj_dir \
		--top-module tb_block_interleaved_voice_renderer \
		$(RTL_SOURCES) $(BLOCK_INTERLEAVED_RENDERER_SIM_SOURCES)
	$(BUILD_DIR)/block_interleaved_renderer_obj_dir/Vtb_block_interleaved_voice_renderer
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_interleaved_dsp_obj_dir --top-module tb_block_interleaved_voice_dsp \
		$(RTL_SOURCES) $(BLOCK_INTERLEAVED_DSP_SIM_SOURCES)
	$(BUILD_DIR)/block_interleaved_dsp_obj_dir/Vtb_block_interleaved_voice_dsp
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/block_mix_buffer_obj_dir --top-module tb_block_mix_buffer \
		$(RTL_SOURCES) $(BLOCK_MIX_BUFFER_SIM_SOURCES)
	$(BUILD_DIR)/block_mix_buffer_obj_dir/Vtb_block_mix_buffer

test-rtl-peripheral:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/common_status_obj_dir \
		--top-module tb_wavetable_common_status_regs \
		rtl/pkg/synth_pkg.sv rtl/pkg/synth_register_pkg.sv \
		fpga/common/rtl/wavetable_common_status_regs.sv $(COMMON_STATUS_SIM_SOURCES)
	$(BUILD_DIR)/common_status_obj_dir/Vtb_wavetable_common_status_regs
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

render-rtl-ddr3:
	# Build the RTL renderer with 200 MHz MIG input, DDR3-800 timing, and C++ SF2/MIDI policy.
	mkdir -p $(RENDER_RTL_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --exe --build $(VERILATOR_JOBS) --timing \
		--Wall -Wno-fatal --Mdir $(RENDER_RTL_OBJ_DIR) \
		--top-module voice_major_render_harness \
		-CFLAGS "$(HARNESS_CXXFLAGS)" \
		$(RTL_SOURCES) \
		sim/models/ddr3_timing_model.sv \
		sim/models/ordered_line_ddr3_bridge_model.sv \
		sim/models/voice_major_render_harness.sv \
		$(abspath sim/harness/apps/render_rtl_ddr3_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_WAV_SRC) \
		$(HARNESS_INTERRUPT_SRC) \
		$(abspath sim/harness/memory/ddr3_bin_store.cpp)
	$(RENDER_RTL_OBJ_DIR)/Vvoice_major_render_harness \
		--sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--start-seconds $(START_SECONDS) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--control-tick-ms $(CONTROL_TICK_MS) \
		$(if $(filter 1 true yes,$(SAMPLE_ACCURATE_CONTROL)),--sample-accurate-control,) \
		$(if $(filter 1 true yes,$(DETAILED_DIAGNOSTICS)),--detailed-diagnostics,) \
		--out-dir $(RENDER_RTL_OUT_DIR) \
		+DDR3_IMAGE=$(abspath $(SF2))

vivado-project:
	mkdir -p $(VIVADO_BUILD_DIR)/logs
	cd $(VIVADO_BUILD_DIR) && $(VIVADO_CONFIG_ENV) $(VIVADO) -mode batch \
		-source $(VIVADO_SCRIPT_DIR)/project.tcl \
		-journal logs/project.jou -log logs/project.log

vivado-synth:
	mkdir -p $(VIVADO_BUILD_DIR)/logs
	cd $(VIVADO_BUILD_DIR) && $(VIVADO_CONFIG_ENV) $(VIVADO) -mode batch \
		-source $(VIVADO_SCRIPT_DIR)/synth.tcl \
		-journal logs/synth.jou -log logs/synth.log

vivado-impl:
	mkdir -p $(VIVADO_BUILD_DIR)/logs
	cd $(VIVADO_BUILD_DIR) && $(VIVADO_CONFIG_ENV) $(VIVADO) -mode batch \
		-source $(VIVADO_SCRIPT_DIR)/impl.tcl \
		-journal logs/impl.jou -log logs/impl.log

vivado-bitstream:
	mkdir -p $(VIVADO_BUILD_DIR)/logs
	cd $(VIVADO_BUILD_DIR) && $(VIVADO_CONFIG_ENV) $(VIVADO) -mode batch \
		-source $(VIVADO_SCRIPT_DIR)/bitstream.tcl \
		-journal logs/bitstream.jou -log logs/bitstream.log

vivado-summary:
	python3 tools/vivado_report_summary.py show

clean:
	rm -rf $(BUILD_DIR)
