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

RTL_SOURCES := \
	rtl/pkg/synth_pkg.sv \
	rtl/bus/register_bus_if.sv \
	rtl/control/voice_register_bank.sv \
	rtl/dsp/linear_interpolator.sv \
	rtl/dsp/gain_saturate.sv \
	rtl/voice/voice_pipeline.sv \
	rtl/top/wavetable_core.sv

SIM_SOURCES := \
	sim/models/wave_memory_model.sv \
	sim/tb/tb_wavetable_core.sv

.PHONY: all lint test list-instruments render-instrument clean

all: test

lint:
	# Lint only synthesizable RTL; simulation models and testbenches are excluded.
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core $(RTL_SOURCES)

test:
	# Build and run the self-checking synthetic-data regression.
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)

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
		$(RTL_SOURCES) sim/models/wave_memory_model.sv sim/tb/tb_render_wavetable_core.sv
	$(BUILD_DIR)/render_obj_dir/Vtb_render_wavetable_core
	# 3. Convert the raw stereo PCM stream into a playable WAV file.
	python3 tools/pcm_to_wav.py --pcm $(BUILD_DIR)/render/out.pcm \
		--wav $(BUILD_DIR)/render/out.wav --sample-rate $(SAMPLE_RATE)

clean:
	rm -rf $(BUILD_DIR)
