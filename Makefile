VERILATOR ?= verilator
BUILD_DIR := build
TOP := tb_wavetable_core
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
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core $(RTL_SOURCES)

test:
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)

list-instruments:
	python3 tools/sf2_extract.py --sf2 "$(SF2)" --list-instruments

render-instrument:
	python3 tools/sf2_extract.py --sf2 "$(SF2)" \
		$(if $(INSTRUMENT),--instrument "$(INSTRUMENT)",) \
		--key $(KEY) --seconds $(SECONDS) --sample-rate $(SAMPLE_RATE) \
		--out-dir $(BUILD_DIR)/render
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		-I$(BUILD_DIR)/render --Mdir $(BUILD_DIR)/render_obj_dir \
		--top-module tb_render_wavetable_core \
		$(RTL_SOURCES) sim/models/wave_memory_model.sv sim/tb/tb_render_wavetable_core.sv
	$(BUILD_DIR)/render_obj_dir/Vtb_render_wavetable_core
	python3 tools/pcm_to_wav.py --pcm $(BUILD_DIR)/render/out.pcm \
		--wav $(BUILD_DIR)/render/out.wav --sample-rate $(SAMPLE_RATE)

clean:
	rm -rf $(BUILD_DIR)
