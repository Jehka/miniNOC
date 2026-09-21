# Mini-NoC v0.2 -- Verilator >= 5.0 flow
#   make all            lint + unit tests + system regression
#   make sys DEPTH=16 SEED=3
#   make mutate         prove the testbenches catch injected bugs
VERILATOR ?= verilator
RTL  = rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/sync_fifo.sv rtl/skid_reg.sv rtl/bram_sdp.sv \
       rtl/endpoint_port.sv rtl/route_decode.sv rtl/output_port_ctrl.sv \
       rtl/noc_switch.sv rtl/memory_adapter.sv rtl/noc_top.sv
SIMF = --binary --timing --assert -j 4 -Wno-fatal -Wno-lint -Wno-style
N ?= 9
DEPTH ?= 16
SEED ?= 1

all: lint unit regress selftest n1

lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM --top-module noc_top $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL --top-module zed_top $(RTL) fpga/ep_traffic.sv fpga/zed_top.sv
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL --top-module n1_top $(RTL) rtl/axil_noc_bridge.sv fpga/ep_traffic.sv fpga/n1_top.sv
	@echo "LINT CLEAN"

build:
	@mkdir -p build

arb: build
	@$(VERILATOR) $(SIMF) -GN=$(N) --top-module tb_rr_arbiter rtl/rr_arbiter.sv tb/tb_rr_arbiter.sv -Mdir build/arb_$(N) > build/arb_$(N).log 2>&1
	@./build/arb_$(N)/Vtb_rr_arbiter | grep -E "PASS|FAIL|Error"

fifo: build
	@$(VERILATOR) $(SIMF) -GDEPTH=$(DEPTH) --top-module tb_sync_fifo rtl/sync_fifo.sv tb/tb_sync_fifo.sv -Mdir build/fifo_$(DEPTH) > build/fifo_$(DEPTH).log 2>&1
	@./build/fifo_$(DEPTH)/Vtb_sync_fifo | grep -E "PASS|FAIL|Error"

build/sys_$(DEPTH)/Vtb_noc_top: $(RTL) tb/tb_noc_top.sv
	@mkdir -p build
	@$(VERILATOR) $(SIMF) -GFIFO_DEPTH=$(DEPTH) --top-module tb_noc_top $(RTL) tb/tb_noc_top.sv -Mdir build/sys_$(DEPTH) > build/sys_$(DEPTH).log 2>&1

sys: build/sys_$(DEPTH)/Vtb_noc_top
	@./build/sys_$(DEPTH)/Vtb_noc_top +seed=$(SEED) +verilator+seed+$(SEED) | grep -E "PASS|FAIL|ERROR|Error|counters|max simult" | head -20

unit:
	@$(MAKE) -s arb N=5; $(MAKE) -s arb N=8; $(MAKE) -s arb N=9
	@$(MAKE) -s fifo DEPTH=2; $(MAKE) -s fifo DEPTH=16; $(MAKE) -s fifo DEPTH=64

regress:
	@for d in 2 4 16 64; do for s in 1 2 3; do $(MAKE) -s sys DEPTH=$$d SEED=$$s | grep -E "^(PASS|FAIL)"; done; done

FPGA = $(RTL) fpga/ep_traffic.sv fpga/zed_top.sv
selftest: build
	@$(VERILATOR) $(SIMF) --top-module tb_zed_selftest $(FPGA) tb/tb_zed_selftest.sv -Mdir build/zed > build/zed.log 2>&1
	@./build/zed/Vtb_zed_selftest | grep -E "self-test|PASS|FAIL"
	@./build/zed/Vtb_zed_selftest +inject | grep -E "PASS|FAIL"

N1   = $(RTL) rtl/axil_noc_bridge.sv fpga/ep_traffic.sv fpga/n1_top.sv
n1: build
	@$(VERILATOR) $(SIMF) --top-module tb_n1_bridge $(N1) tb/tb_n1_bridge.sv -Mdir build/n1 > build/n1.log 2>&1
	@./build/n1/Vtb_n1_bridge | grep -E "ok|info|ERROR|PASS|FAIL"

mutate:
	@bash scripts/mutate.sh

clean:
	rm -rf build
.PHONY: all lint build arb fifo sys unit regress selftest n1 mutate clean
