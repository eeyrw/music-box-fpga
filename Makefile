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
SECONDS ?= 2
SAMPLE_RATE ?= 48000
ADSR_TICK_MS ?= 5
MIDI ?=
MEMORY_PROFILE ?= ddr
RENDER_MEMORY_OUT_DIR ?= $(BUILD_DIR)/render_memory
RENDER_QUICK_OUT_DIR ?= $(BUILD_DIR)/render_quick
RENDER_FULL_SYSTEM_OUT_DIR ?= $(BUILD_DIR)/render_full_system
RENDER_BOARD_LOADER_OUT_DIR ?= $(BUILD_DIR)/render_board_loader
WTSF_IMAGE ?= $(BUILD_DIR)/assets/wavetable.wtsf.img
WTSF_SF2_START_LBA ?= 1
WTSF_CRC ?=
SD_DEVICE ?=
RENDER_OPT_FAST ?= -O3
RENDER_OPT_GLOBAL ?= $(RENDER_OPT_FAST)

RTL_SOURCES := \
	rtl/pkg/synth_pkg.sv \
	rtl/pkg/synth_register_pkg.sv \
	rtl/control/voice_active_store.sv \
	rtl/control/voice_bram_1r1w.sv \
	rtl/control/voice_bram_1w2r.sv \
	rtl/control/voice_commit_engine.sv \
	rtl/control/voice_descriptor_store.sv \
	rtl/control/voice_runtime_store.sv \
	rtl/control/voice_register_bank.sv \
	rtl/memory/wave_memory_subsystem.sv \
	rtl/dsp/linear_interpolator.sv \
	rtl/dsp/gain_saturate.sv \
	rtl/dsp/voice_dsp_pipeline.sv \
	rtl/audio/output_sample_fifo.sv \
	rtl/voice/voice_phase_frame.sv \
	rtl/voice/voice_endpoint_fetch.sv \
	rtl/voice/multi_voice_pipeline.sv \
	rtl/top/wavetable_render_core.sv \
	rtl/top/wavetable_cached_render_core.sv

FPGA_COMMON_RTL_SOURCES := \
	fpga/common/rtl/fractional_tick_gen.sv \
	fpga/common/rtl/spi_register_bridge.sv \
	fpga/common/rtl/wavetable_register_fabric.sv \
	fpga/common/rtl/wavetable_common_status_regs.sv \
	fpga/common/rtl/i2s_tx.sv \
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

I2S_SIM_SOURCES := \
	sim/tb/tb_i2s_tx.sv

COMMON_STATUS_SIM_SOURCES := \
	sim/tb/tb_wavetable_demo_common_status.sv

VOICE_PHASE_SIM_SOURCES := \
	sim/tb/tb_voice_phase_frame.sv

HARNESS_RENDER_COMMON_SRCS := \
	$(abspath sim/harness/render/render_support.cpp) \
	$(abspath sim/harness/control/register_control.cpp) \
	$(abspath sim/harness/formats/midi_parser.cpp) \
	$(abspath sim/harness/formats/sf2_loader.cpp)

HARNESS_WAV_SRC := \
	$(abspath sim/harness/common/wav_writer.cpp)

HARNESS_MEMORY_PROFILE_SRC := \
	$(abspath sim/harness/common/memory_profile.cpp)

HARNESS_BOARD_LOADER_SRCS := \
	$(abspath sim/harness/board_loader/board_loader_render_harness.cpp) \
	$(abspath sim/harness/board_loader/board_loader_render_utils.cpp)

SMART_ARTIX_RTL_SOURCES := \
	rtl/pkg/synth_register_pkg.sv \
	fpga/common/rtl/sd_native_block_reader.sv \
	fpga/common/rtl/sd_native_pin_phy.sv \
	fpga/smart_artix/rtl/smart_artix_pkg.sv \
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
	tb_smart_artix_sd_native_asset_loader \
	tb_sd_native_block_reader \
	tb_sd_native_block_reader_fake \
	tb_sd_native_pin_phy \
	tb_sd_native_pin_phy_fake

.PHONY: all generate-register-map check-register-map lint test test-cpp-unit test-rtl-core test-rtl-peripheral smart-artix-test $(SMART_ARTIX_TESTBENCHES) host-ch347 host-smart-artix-bringup list-instruments wtsf-image verify-wtsf-image flash-wtsf-sd render-instrument render-quick render-memory render-full-system render-board-loader vivado-summary clean

all: test

generate-register-map:
	python3 tools/gen_register_map.py

check-register-map:
	python3 tools/gen_register_map.py
	git diff --exit-code -- rtl/pkg/synth_register_pkg.sv sim/harness/generated/register_map.h

lint:
	# Lint only synthesizable RTL; simulation models and testbenches are excluded.
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_render_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_cached_render_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wave_memory_subsystem $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_system_core $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_i2s_output $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_demo_system $(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module i2s_tx rtl/pkg/synth_pkg.sv fpga/common/rtl/fractional_tick_gen.sv fpga/common/rtl/i2s_tx.sv

test: test-cpp-unit test-rtl-core test-rtl-peripheral

test-cpp-unit:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/formats/midi_parser.cpp sim/harness/formats/midi_parser_test.cpp \
		-o $(BUILD_DIR)/midi_parser_test
	$(BUILD_DIR)/midi_parser_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/control/register_control.cpp sim/harness/control/register_control_test.cpp \
		-o $(BUILD_DIR)/register_control_test
	$(BUILD_DIR)/register_control_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/formats/sf2_loader.cpp sim/harness/formats/sf2_loader_test.cpp \
		-o $(BUILD_DIR)/sf2_loader_test
	$(BUILD_DIR)/sf2_loader_test
	$(CXX) $(CXX_STD_FLAGS) \
		sim/harness/render/render_support.cpp sim/harness/formats/sf2_loader.cpp \
		sim/harness/render/reference_synth.cpp \
		sim/harness/formats/midi_parser.cpp sim/harness/render/render_support_test.cpp \
		-o $(BUILD_DIR)/render_support_test
	$(BUILD_DIR)/render_support_test

test-rtl-core:
	mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/voice_phase_obj_dir --top-module tb_voice_phase_frame \
		$(RTL_SOURCES) $(VOICE_PHASE_SIM_SOURCES)
	$(BUILD_DIR)/voice_phase_obj_dir/Vtb_voice_phase_frame
	# Build and run the self-checking synthetic-data regression.
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/memory_obj_dir --top-module tb_wave_memory_subsystem \
		$(RTL_SOURCES) $(MEMORY_SIM_SOURCES)
	$(BUILD_DIR)/memory_obj_dir/Vtb_wave_memory_subsystem

test-rtl-peripheral:
	mkdir -p $(BUILD_DIR)
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
		sim/harness/control/register_control.cpp \
		-o $(BUILD_DIR)/ch347_control -ldl

host-smart-artix-bringup:
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CXX_STD_FLAGS) -I. \
		host/smart_artix_bringup_main.cpp host/ch347_transport.cpp \
		sim/harness/control/register_control.cpp \
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

render-quick:
	# Build and run the fast C++ reference-vs-RTL harness against wavetable_render_core.
	mkdir -p $(RENDER_QUICK_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_quick_cpp_obj_dir --top-module wavetable_render_core \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/apps/render_quick_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_WAV_SRC) \
		$(abspath sim/harness/render/reference_synth.cpp) \
		$(abspath sim/harness/dut/quick_rtl_harness.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_quick_cpp_obj_dir -f Vwavetable_render_core.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_quick_cpp_obj_dir/Vwavetable_render_core --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--adsr-tick-ms $(ADSR_TICK_MS) \
		--out-dir $(RENDER_QUICK_OUT_DIR)

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
		$(abspath sim/harness/dut/rtl_harness.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_memory_cpp_obj_dir -f Vwavetable_cached_render_core.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_memory_cpp_obj_dir/Vwavetable_cached_render_core --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--adsr-tick-ms $(ADSR_TICK_MS) \
		--out-dir $(RENDER_MEMORY_OUT_DIR)

render-full-system:
	# Build and run the pin-level full-system harness. WAV output is captured from I2S RX.
	mkdir -p $(RENDER_FULL_SYSTEM_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_full_system_cpp_obj_dir --top-module wavetable_demo_system \
		$(RTL_SOURCES) $(FPGA_COMMON_RTL_SOURCES) --exe \
		$(abspath sim/harness/apps/render_full_system_main.cpp) \
		$(HARNESS_RENDER_COMMON_SRCS) \
		$(HARNESS_WAV_SRC) \
		$(abspath sim/harness/dut/full_system_harness.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_full_system_cpp_obj_dir -f Vwavetable_demo_system.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_full_system_cpp_obj_dir/Vwavetable_demo_system --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--adsr-tick-ms $(ADSR_TICK_MS) \
		--out-dir $(RENDER_FULL_SYSTEM_OUT_DIR)

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
		$(HARNESS_BOARD_LOADER_SRCS) \
		$(abspath sim/harness/render/reference_synth.cpp) \
		-CFLAGS "$(HARNESS_CXXFLAGS)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_board_loader_cpp_obj_dir -f Vboard_loader_render_tops.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_board_loader_cpp_obj_dir/Vboard_loader_render_tops --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--adsr-tick-ms $(ADSR_TICK_MS) \
		--out-dir $(RENDER_BOARD_LOADER_OUT_DIR)

vivado-summary:
	python3 tools/vivado_report_summary.py show

clean:
	rm -rf $(BUILD_DIR)
