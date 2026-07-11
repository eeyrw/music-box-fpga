VERILATOR ?= verilator
BUILD_DIR := build
TOP := tb_wavetable_core

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

.PHONY: all lint test clean

all: test

lint:
	$(VERILATOR) --lint-only --Wall -Wno-fatal --top-module wavetable_core $(RTL_SOURCES)

test:
	$(VERILATOR) --binary --timing --Wall -Wno-fatal \
		--Mdir $(BUILD_DIR)/obj_dir --top-module $(TOP) \
		$(RTL_SOURCES) $(SIM_SOURCES)
	$(BUILD_DIR)/obj_dir/V$(TOP)

clean:
	rm -rf $(BUILD_DIR)
