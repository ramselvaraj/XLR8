VERILATOR ?= verilator
OBJ       := build/obj
BIN       := $(OBJ)/Vtb_gpu
SOURCES   := $(shell cat rtl/gpu/files.txt)
PY        := $(shell if [ -x .venv/bin/python ]; then echo .venv/bin/python; else echo python3; fi)

GPU_RTL := rtl/gpu/simt_gpu.sv rtl/gpu/warp.sv rtl/gpu/regfile.sv rtl/gpu/alu.sv \
           rtl/gpu/decoder.sv rtl/gpu/dcr.sv rtl/gpu/dispatcher.sv \
           rtl/gpu/scheduler.sv rtl/gpu/mem_unit.sv

UNIT_TESTS := tb_alu tb_decoder tb_regfile tb_dcr tb_dispatcher tb_scheduler tb_branch

UNIT_SRC_tb_alu        := rtl/gpu/alu.sv        tb/unit/tb_alu.sv
UNIT_SRC_tb_decoder    := rtl/gpu/decoder.sv    tb/unit/tb_decoder.sv
UNIT_SRC_tb_regfile    := rtl/gpu/regfile.sv    tb/unit/tb_regfile.sv
UNIT_SRC_tb_dcr        := rtl/gpu/dcr.sv        tb/unit/tb_dcr.sv
UNIT_SRC_tb_dispatcher := rtl/gpu/dispatcher.sv tb/unit/tb_dispatcher.sv
UNIT_SRC_tb_scheduler  := rtl/gpu/scheduler.sv  tb/unit/tb_scheduler.sv
UNIT_SRC_tb_branch     := $(GPU_RTL)            tb/unit/tb_branch.sv

.PHONY: all venv build lint unit test-unit test-py test-ball test-gpu build-xlr8 prog test-xlr8 test-ball-axi test clean

all: build

venv:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

build: $(BIN)

$(BIN): $(SOURCES) rtl/gpu/files.txt
	mkdir -p $(OBJ)
	$(VERILATOR) --binary --timing --top-module tb_gpu -f rtl/gpu/files.txt --Mdir $(OBJ)

XLR8_RTL := $(GPU_RTL) $(shell cat rtl/axi/files.txt)
XLR8_TB  := tb/system/axi_mem_model.sv tb/system/tb_xlr8.sv
XLR8_BIN := build/xlr8/Vtb_xlr8
STALLS   ?= 0 25 60 90
SEEDS    ?= 1 2

lint:
	$(VERILATOR) --lint-only -Wall --top-module simt_gpu $(GPU_RTL)
	$(VERILATOR) --lint-only -Wall --top-module xlr8_top $(XLR8_RTL)

prog:
	mkdir -p build/prog
	$(PY) tools/assemble.py sw/kernels/brighten.asm --out build/prog/brighten.hex --meta build/prog/brighten.json

build-xlr8: $(XLR8_BIN)

$(XLR8_BIN): $(XLR8_RTL) $(XLR8_TB) rtl/axi/files.txt
	mkdir -p build/xlr8
	$(VERILATOR) --binary --timing -Wno-fatal --top-module tb_xlr8 $(XLR8_RTL) $(XLR8_TB) --Mdir build/xlr8

# Phase 2: wrapper tests under random AXI stalls and seeds, then the ball animation through the wrapper.
test-xlr8: build-xlr8 prog
	@for s in $(STALLS); do for seed in $(SEEDS); do \
	  echo "xlr8 all stall=$$s seed=$$seed"; \
	  $(XLR8_BIN) +test=all +stall=$$s +verilator+seed+$$seed | grep -E "FAIL|PASS|PROTOCOL" ; \
	  $(XLR8_BIN) +test=all +stall=$$s +verilator+seed+$$seed >/dev/null 2>&1 || exit 1; \
	done; done

test-ball-axi: build-xlr8
	$(PY) tools/run_ball_axi.py --frames 100 --stall 0
	$(PY) tools/run_ball_axi.py --frames 100 --stall 50 --seed 2
	$(PY) tools/run_ball_axi.py --frames 30 --stall 90 --seed 3

unit:
	@test -n "$(TEST)" || (echo "usage: make unit TEST=<$(UNIT_TESTS)>"; exit 1)
	mkdir -p build/unit/$(TEST)
	$(VERILATOR) --binary --timing --top-module $(TEST) $(UNIT_SRC_$(TEST)) --Mdir build/unit/$(TEST)
	build/unit/$(TEST)/V$(TEST)

test-unit:
	@for t in $(UNIT_TESTS); do $(MAKE) --no-print-directory unit TEST=$$t || exit 1; done

test-py:
	$(PY) tools/tests/test_blur_ref.py
	$(PY) tools/tests/test_blur_border.py

# Phase 1: ball kernel vs independent reference, ISA sim and RTL.
test-ball: build
	$(PY) tools/tests/test_ball.py
	$(PY) tools/tests/test_kernels.py

# Existing RAPTOR GPU regression: unit tests, python tests, brighten, blur (interior + full frame).
test-gpu: build test-unit test-py
	$(PY) tools/run_sim.py
	$(PY) tools/run_sim.py --kernel sw/kernels/blur.asm
	$(PY) tools/run_sim.py --full --width 16 --height 16
	$(PY) tools/run_sim.py --full --width 32 --height 32
	$(PY) tools/run_sim.py --full --width 64 --height 64

test: test-gpu test-ball test-xlr8 test-ball-axi

clean:
	rm -rf build
