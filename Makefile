VERILATOR ?= verilator
BUILD_DIR := build
TOP := tb_wavetable_core
NUM_VOICES ?= 32
VERILATOR_JOBS ?= -j 0
MAKE_JOBS ?= -j
RTL_DEFINES := -DSYNTH_NUM_VOICES=$(NUM_VOICES)
CXX_DEFINES := -DRENDER_NUM_VOICES=$(NUM_VOICES)

# Defaults for the SoundFont render flow. Users can override any of these on the
# make command line, for example: make render-instrument INSTRUMENT=10 KEY=64.
SF2 ?= assets/soundfonts/MT6276.sf2
INSTRUMENT ?=
KEY ?= 60
SECONDS ?= 2
SAMPLE_RATE ?= 48000
MIDI ?=
MEMORY_PROFILE ?= ddr
RENDER_MEMORY_OUT_DIR ?= $(BUILD_DIR)/render_memory
RENDER_QUICK_OUT_DIR ?= $(BUILD_DIR)/render_quick
RENDER_FULL_SYSTEM_OUT_DIR ?= $(BUILD_DIR)/render_full_system
RENDER_OPT_FAST ?= -O3
RENDER_OPT_GLOBAL ?= $(RENDER_OPT_FAST)

RTL_SOURCES := \
	rtl/pkg/synth_pkg.sv \
	rtl/bus/register_bus_if.sv \
	rtl/bus/spi_register_bridge.sv \
	rtl/control/voice_bram_1r1w.sv \
	rtl/control/voice_bram_1w2r.sv \
	rtl/control/voice_register_bank.sv \
	rtl/memory/wave_memory_subsystem.sv \
	rtl/dsp/biquad_filter_datapath.sv \
	rtl/dsp/linear_interpolator.sv \
	rtl/dsp/gain_saturate.sv \
	rtl/dsp/voice_dsp_pipeline.sv \
	rtl/audio/fractional_tick_gen.sv \
	rtl/audio/output_sample_fifo.sv \
	rtl/audio/i2s_tx.sv \
	rtl/voice/multi_voice_pipeline.sv \
	rtl/top/wavetable_core.sv \
	rtl/top/wavetable_core_memory.sv \
	rtl/top/wavetable_core_spi.sv \
	rtl/top/wavetable_core_system.sv

SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wavetable_core.sv

SPI_SIM_SOURCES := \
	sim/tb/tb_spi_register_bridge.sv

MEMORY_SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wave_memory_subsystem.sv

I2S_SIM_SOURCES := \
	sim/tb/tb_i2s_tx.sv

.PHONY: all lint test host-ch347 list-instruments render-instrument render-quick render-memory render-full-system clean

all: test

lint:
	# Lint only synthesizable RTL; simulation models and testbenches are excluded.
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_core $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_core_spi $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_core_memory $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wavetable_core_system $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module wave_memory_subsystem $(RTL_SOURCES)
	$(VERILATOR) $(RTL_DEFINES) --lint-only --Wall -Wno-fatal --top-module i2s_tx $(RTL_SOURCES)

test:
	mkdir -p $(BUILD_DIR)
	$(CXX) -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) \
		sim/harness/midi_parser.cpp sim/harness/midi_parser_test.cpp \
		-o $(BUILD_DIR)/midi_parser_test
	$(BUILD_DIR)/midi_parser_test
	$(CXX) -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) \
		sim/harness/register_control.cpp sim/harness/register_control_test.cpp \
		-o $(BUILD_DIR)/register_control_test
	$(BUILD_DIR)/register_control_test
	$(CXX) -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) \
		sim/harness/sf2_loader.cpp sim/harness/sf2_loader_test.cpp \
		-o $(BUILD_DIR)/sf2_loader_test
	$(BUILD_DIR)/sf2_loader_test
	$(CXX) -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) \
		sim/harness/render_support.cpp sim/harness/sf2_loader.cpp \
		sim/harness/midi_parser.cpp sim/harness/render_support_test.cpp \
		-o $(BUILD_DIR)/render_support_test
	$(BUILD_DIR)/render_support_test
	# Build and run the self-checking synthetic-data regression.
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/spi_obj_dir --top-module tb_spi_register_bridge \
		$(RTL_SOURCES) $(SPI_SIM_SOURCES)
	$(BUILD_DIR)/spi_obj_dir/Vtb_spi_register_bridge
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/memory_obj_dir --top-module tb_wave_memory_subsystem \
		$(RTL_SOURCES) $(MEMORY_SIM_SOURCES)
	$(BUILD_DIR)/memory_obj_dir/Vtb_wave_memory_subsystem
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/i2s_obj_dir --top-module tb_i2s_tx \
		$(RTL_SOURCES) $(I2S_SIM_SOURCES)
	$(BUILD_DIR)/i2s_obj_dir/Vtb_i2s_tx

host-ch347:
	mkdir -p $(BUILD_DIR)
	$(CXX) -std=c++17 -Wall -Wextra -Werror $(CXX_DEFINES) -I. \
		host/ch347_control_main.cpp host/ch347_transport.cpp \
		sim/harness/register_control.cpp \
		-o $(BUILD_DIR)/ch347_control -ldl

list-instruments:
	# Inspect instrument names from the configured SF2 without running RTL.
	python3 tools/sf2_extract.py --sf2 "$(SF2)" --list-instruments

render-instrument:
	# 1. Extract one instrument zone to wave.memh plus render_config.svh.
	python3 tools/sf2_extract.py --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(BUILD_DIR)/render
	# 2. Build and execute the render testbench against the generated memory.
	$(VERILATOR) $(RTL_DEFINES) --binary $(VERILATOR_JOBS) --timing --Wall -Wno-fatal \
		-I$(BUILD_DIR)/render --Mdir $(BUILD_DIR)/render_obj_dir \
		--top-module tb_render_wavetable_core \
		$(RTL_SOURCES) sim/models/line_memory_model.sv sim/tb/tb_render_wavetable_core.sv
	$(BUILD_DIR)/render_obj_dir/Vtb_render_wavetable_core
	# 3. Convert the raw stereo PCM stream into a playable WAV file.
	python3 tools/pcm_to_wav.py --pcm $(BUILD_DIR)/render/out.pcm \
		--wav $(BUILD_DIR)/render/out.wav --sample-rate $(SAMPLE_RATE)

render-quick:
	# Build and run the fast C++ reference-vs-RTL harness against wavetable_core.
	mkdir -p $(RENDER_QUICK_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_quick_cpp_obj_dir --top-module wavetable_core \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/render_quick_main.cpp) \
		$(abspath sim/harness/render_support.cpp) \
		$(abspath sim/harness/register_control.cpp) \
		$(abspath sim/harness/midi_parser.cpp) \
		$(abspath sim/harness/sf2_loader.cpp) \
		$(abspath sim/harness/reference_synth.cpp) \
		$(abspath sim/harness/quick_rtl_harness.cpp) \
		-CFLAGS "-std=c++17 $(CXX_DEFINES)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_quick_cpp_obj_dir -f Vwavetable_core.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_quick_cpp_obj_dir/Vwavetable_core --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(RENDER_QUICK_OUT_DIR)

render-memory:
	# Build and run the C++ MIDI/SF2 memory-profile harness against wavetable_core_memory.
	mkdir -p $(RENDER_MEMORY_OUT_DIR)
	rm -f $(RENDER_MEMORY_OUT_DIR)/out.pcm
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_memory_cpp_obj_dir --top-module wavetable_core_memory \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/render_memory_main.cpp) \
		$(abspath sim/harness/render_support.cpp) \
		$(abspath sim/harness/register_control.cpp) \
		$(abspath sim/harness/midi_parser.cpp) \
		$(abspath sim/harness/sf2_loader.cpp) \
		$(abspath sim/harness/rtl_harness.cpp) \
		-CFLAGS "-std=c++17 $(CXX_DEFINES)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_memory_cpp_obj_dir -f Vwavetable_core_memory.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_memory_cpp_obj_dir/Vwavetable_core_memory --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(RENDER_MEMORY_OUT_DIR)

render-full-system:
	# Build and run the pin-level full-system harness. WAV output is captured from I2S RX.
	mkdir -p $(RENDER_FULL_SYSTEM_OUT_DIR)
	$(VERILATOR) $(RTL_DEFINES) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_full_system_cpp_obj_dir --top-module wavetable_core_system \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/render_full_system_main.cpp) \
		$(abspath sim/harness/render_support.cpp) \
		$(abspath sim/harness/register_control.cpp) \
		$(abspath sim/harness/midi_parser.cpp) \
		$(abspath sim/harness/sf2_loader.cpp) \
		$(abspath sim/harness/full_system_harness.cpp) \
		-CFLAGS "-std=c++17 $(CXX_DEFINES)"
	$(MAKE) $(MAKE_JOBS) -C $(BUILD_DIR)/render_full_system_cpp_obj_dir -f Vwavetable_core_system.mk \
		OPT_FAST="$(RENDER_OPT_FAST)" OPT_GLOBAL="$(RENDER_OPT_GLOBAL)"
	$(BUILD_DIR)/render_full_system_cpp_obj_dir/Vwavetable_core_system --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(RENDER_FULL_SYSTEM_OUT_DIR)

clean:
	rm -rf $(BUILD_DIR)
