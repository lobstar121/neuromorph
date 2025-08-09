# ====== Config ======
ART=artifacts
F=48
N=96
T=76
EV_REF=$(ART)/X_events_ref.csv
EV_MEM=$(ART)/events_ref.mem
WHEX=$(ART)/weights.hex
VTH=$(ART)/vth.hex
HW_OUT=$(ART)/spikes_hw.csv
SW_Q14=$(ART)/spikes_sw_q14.csv
GOLD=$(ART)/golden_spikes.csv

# Toolchain / build opts
VERILATOR ?= verilator
# Verilator 5.x는 delay/event 제어에 대해 모드 지정 필수
TIMING    ?= --timing
# 튜닝된 기본값 (원하면 make ALPHA_Q14=15474 처럼 덮어쓰기 가능)
ALPHA_Q14 ?= 15520

TOP       := tb_snn_mem
SRC       := tb_snn_mem.sv snn_core.sv lif_neuron.sv

# 단일-특성 스모크(원하면 추가)
SINGLE_CSV=$(ART)/X_events_single_f0.csv $(ART)/X_events_single_f1.csv $(ART)/X_events_single_f23.csv $(ART)/X_events_single_f24.csv
SINGLE_MEM=$(SINGLE_CSV:.csv=.mem)

# ====== Build RTL sim ======
OBJDIR=obj_dir
SIM=$(OBJDIR)/V$(TOP)

.PHONY: all test golden hw swq14 compare smoke clean veryclean smoke_compare report alpha_sweep vth_sweep grid_sweep

all: test

# Verilator 5.x 대응: --binary 로 실행파일까지 생성, --timing 지정, ALPHA 파라미터 주입
# obj_dir/Vtb_snn_mem 를 생성 (실행 가능 바이너리)
$(SIM): $(SRC)
	$(VERILATOR) -sv --binary $(SRC) --top-module $(TOP) \
	  -Mdir $(OBJDIR) -GALPHA_Q14=$(ALPHA_Q14) $(TIMING)

# ====== 1) 회귀 테스트 고정 ======
# 이벤트 CSV -> MEM
$(EV_MEM): $(EV_REF)
	python csv2mem.py $(EV_REF) $(F) $(EV_MEM)

# HW 실행
hw: $(SIM) $(EV_MEM) $(WHEX) $(VTH)
	$(SIM) +EVHEX=$(EV_MEM) +WHEX=$(WHEX) +VTH=$(VTH) +T=$(T) +OUT=$(HW_OUT)

# SW(Q1.14) 생성
swq14:
	python fixedpoint_replay.py

# 비교 (HW vs SW_Q14)
compare:
	python compare_spikes.py $(HW_OUT) $(SW_Q14)

# 단일 타깃: 테스트(1회) = csv2mem -> hw -> swq14 -> compare
test: $(EV_MEM) hw swq14 compare

# ====== 2) 골든 관리 ======
# 현재 SW_Q14를 골든으로 고정
golden: swq14
	cp -f $(SW_Q14) $(GOLD)
	@echo "[GOLD] updated: $(GOLD)"

# 골든과 비교하고 싶을 때 (HW vs GOLD)
compare_golden: hw
	python compare_spikes.py $(HW_OUT) $(GOLD)

# ====== 3) 스모크 (옵션) ======
# 단일-특성 CSV -> MEM 변환
$(ART)/events_%.mem: $(ART)/X_events_%.csv
	python csv2mem.py $< $(F) $@

smoke: $(SIM) $(WHEX) $(VTH) $(SINGLE_MEM)
	@for M in $(SINGLE_MEM); do \
	  BASE=$${M%.mem}; \
	  OUT=$(ART)/spikes_hw_$${BASE##*/}.csv; \
	  echo "[SMOKE] $$M -> $$OUT"; \
	  $(SIM) +EVHEX=$$M +WHEX=$(WHEX) +VTH=$(VTH) +T=16 +OUT=$$OUT; \
	done
	@echo "[SMOKE] done."

# HW↔SW(Q1.14) 비교까지 자동으로
smoke_compare: $(SIM) $(WHEX) $(VTH) $(SINGLE_MEM)
	@for CSV in $(SINGLE_CSV); do \
	  BASE=$${CSV##*/}; NAME=$${BASE%.csv}; \
	  echo "[SMOKE-COMPARE] $$NAME"; \
	  python sw_q14_from_csv.py $$BASE spikes_sw_q14_$${NAME}.csv 16; \
	  $(SIM) +EVHEX=$(ART)/$${NAME}.mem +WHEX=$(WHEX) +VTH=$(VTH) +T=16 +OUT=$(ART)/spikes_hw_$${NAME}.csv; \
	  python compare_spikes.py $(ART)/spikes_hw_$${NAME}.csv $(ART)/spikes_sw_q14_$${NAME}.csv; \
	done
	@echo "[SMOKE-COMPARE] done."

report:
	python spike_report.py artifacts/spikes_hw.csv hw
	python spike_report.py artifacts/spikes_sw_q14.csv swq14

alpha_sweep:
	PATH=/mingw64/bin:$(PATH) python alpha_sweep.py

vth_sweep:
	PATH=/mingw64/bin:$(PATH) python vth_sweep.py

grid_sweep:
	PATH=/mingw64/bin:$(PATH) python grid_sweep.py

clean:
	@rm -f $(ART)/spikes_hw*.csv $(ART)/events_*.mem $(ART)/diff_mask.csv

veryclean: clean
	@rm -rf $(OBJDIR)
