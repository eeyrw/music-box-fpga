VERILATOR ?= verilator
BUILD_DIR := build
TOP := tb_wavetable_core

# Defaults for the SoundFont render flow. Users can override any of these on the
# make command line, for example: make render-instrument INSTRUMENT=10 KEY=64.
SF2 ?= assets/soundfonts/MT6276.sf2
INSTRUMENT ?=
KEY ?= 60
SECONDS ?= 2
SAMPLE_RATE ?= 48000
MIDI ?=
MEMORY_PROFILE ?= ddr
RENDER_MIDI_OUT_DIR ?= $(BUILD_DIR)/render_midi

RTL_SOURCES := \
	rtl/pkg/synth_pkg.sv \
	rtl/bus/register_bus_if.sv \
	rtl/bus/spi_register_bridge.sv \
	rtl/control/voice_register_bank.sv \
	rtl/memory/wave_memory_subsystem.sv \
	rtl/dsp/linear_interpolator.sv \
	rtl/dsp/gain_saturate.sv \
	rtl/voice/multi_voice_pipeline.sv \
	rtl/top/wavetable_core.sv \
	rtl/top/wavetable_core_memory.sv \
	rtl/top/wavetable_core_spi.sv

SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wavetable_core.sv

SPI_SIM_SOURCES := \
	sim/tb/tb_spi_register_bridge.sv

MEMORY_SIM_SOURCES := \
	sim/models/line_memory_model.sv \
	sim/tb/tb_wave_memory_subsystem.sv

.PHONY: all lint test list-instruments render-instrument render-midi clean

all: test

lint:
	# Lint only synthesizable RTL; simulation models and testbenches are excluded.
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core $(RTL_SOURCES)
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core_spi $(RTL_SOURCES)
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core_memory $(RTL_SOURCES)
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wave_memory_subsystem $(RTL_SOURCES)

test:
	mkdir -p $(BUILD_DIR)
	$(CXX) -std=c++17 -Wall -Wextra -Werror \
		sim/harness/midi_parser.cpp sim/harness/midi_parser_test.cpp \
		-o $(BUILD_DIR)/midi_parser_test
	$(BUILD_DIR)/midi_parser_test
	# Build and run the self-checking synthetic-data regression.
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/spi_obj_dir --top-module tb_spi_register_bridge \
		$(RTL_SOURCES) $(SPI_SIM_SOURCES)
	$(BUILD_DIR)/spi_obj_dir/Vtb_spi_register_bridge
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/memory_obj_dir --top-module tb_wave_memory_subsystem \
		$(RTL_SOURCES) $(MEMORY_SIM_SOURCES)
	$(BUILD_DIR)/memory_obj_dir/Vtb_wave_memory_subsystem

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
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		-I$(BUILD_DIR)/render --Mdir $(BUILD_DIR)/render_obj_dir \
		--top-module tb_render_wavetable_core \
		$(RTL_SOURCES) sim/models/line_memory_model.sv sim/tb/tb_render_wavetable_core.sv
	$(BUILD_DIR)/render_obj_dir/Vtb_render_wavetable_core
	# 3. Convert the raw stereo PCM stream into a playable WAV file.
	python3 tools/pcm_to_wav.py --pcm $(BUILD_DIR)/render/out.pcm \
		--wav $(BUILD_DIR)/render/out.wav --sample-rate $(SAMPLE_RATE)

render-midi:
	# Build and run the C++ MIDI/SF2 harness against wavetable_core.
	mkdir -p $(RENDER_MIDI_OUT_DIR)
	rm -f $(RENDER_MIDI_OUT_DIR)/out.pcm
	$(VERILATOR) --cc --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/render_midi_cpp_obj_dir --top-module wavetable_core_memory \
		$(RTL_SOURCES) --exe \
		$(abspath sim/harness/render_midi_main.cpp) \
		$(abspath sim/harness/midi_parser.cpp) \
		$(abspath sim/harness/sf2_loader.cpp) \
		$(abspath sim/harness/rtl_harness.cpp) \
		--build -CFLAGS "-std=c++17"
	$(BUILD_DIR)/render_midi_cpp_obj_dir/Vwavetable_core_memory --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		$(if $(MIDI),--midi "$(MIDI)",) \
		--memory-profile "$(MEMORY_PROFILE)" \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(RENDER_MIDI_OUT_DIR)

clean:
	rm -rf $(BUILD_DIR)
