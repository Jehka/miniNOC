#!/usr/bin/env bash
# mutate.sh -- inject known bugs into a copy of rtl/ and confirm tb_noc_top catches each.
#   bash scripts/mutate.sh            all mutants
#   bash scripts/mutate.sh M1 M4      selected
set -u
cd "$(dirname "$0")/.."
declare -A FILE PAT DESC
FILE[M1]=output_port_ctrl.sv; PAT[M1]='s/end else if (!locked \&\& gnt_valid) begin/end else if (!locked \&\& gnt_valid \&\& xfer) begin/'
DESC[M1]="v0.1 behaviour: lock on header transfer instead of on grant"
FILE[M2]=route_decode.sv;     PAT[M2]='s/assign route_o = open_q ? dst_q : hdr_sel;/assign route_o = hdr_sel;/'
DESC[M2]="route decoded from every flit instead of latched at SOP"
FILE[M3]=endpoint_port.sv;    PAT[M3]="s/assign tx_d     = hdr ? {tx_data\[63:60\], 4'(ID), tx_data\[55:0\]} : tx_data;/assign tx_d     = tx_data;/"
DESC[M3]="SRC_ID not stamped at ingress"
FILE[M4]=route_decode.sv;     PAT[M4]="s/? OUT_IW'(hdst) : OUT_IW'(SINK_PORT);/? OUT_IW'(hdst) : OUT_IW'(0);/"
DESC[M4]="illegal DST_ID routed to EP0 instead of sink"
FILE[M5]=rr_arbiter.sv;       PAT[M5]="s/: release_idx_i + 1'b1;/: release_idx_i;/"
DESC[M5]="round-robin pointer does not advance past owner"
FILE[M6]=memory_adapter.sv;   PAT[M6]="s/mem_raddr = addr_w + 1.b1;/mem_raddr = addr_w;/"
DESC[M6]="memory read burst repeats a word"
FILE[M7]=sync_fifo.sv;        PAT[M7]="s/assign in_ready_o  = !full;/assign in_ready_o  = 1'b1;/"
DESC[M7]="FIFO accepts while full"
FILE[M8]=memory_adapter.sv;   PAT[M8]="s/if (cnt + 1 != rlen) err <= E_LEN;//"
DESC[M8]="short write not reported as E_LEN"
FILE[M9]=output_port_ctrl.sv; PAT[M9]="s/assign done        = xfer \&\& eop_i\[owner_o\];/assign done        = xfer;/"
DESC[M9]="lock released after every flit (packets interleave)"

LIST=("$@"); [ ${#LIST[@]} -eq 0 ] && LIST=(M1 M2 M3 M4 M5 M6 M7 M8 M9)
caught=0; total=0
for m in "${LIST[@]}"; do
  total=$((total+1))
  d=build/mut_$m; rm -rf "$d"; mkdir -p "$d/rtl"; cp rtl/*.sv "$d/rtl/"
  sed -i "${PAT[$m]}" "$d/rtl/${FILE[$m]}"
  if cmp -s "rtl/${FILE[$m]}" "$d/rtl/${FILE[$m]}"; then echo "$m  PATTERN DID NOT APPLY  (${DESC[$m]})"; continue; fi
  R="$d/rtl"
  verilator --binary --timing --assert -j 4 -Wno-fatal -Wno-lint -Wno-style --top-module tb_noc_top \
    $R/noc_pkg.sv $R/rr_arbiter.sv $R/sync_fifo.sv $R/bram_sdp.sv $R/endpoint_port.sv $R/route_decode.sv \
    $R/output_port_ctrl.sv $R/noc_switch.sv $R/memory_adapter.sv $R/noc_top.sv tb/tb_noc_top.sv \
    -Mdir "$d/obj" > "$d/build.log" 2>&1
  out=$(timeout 120 "$d/obj/Vtb_noc_top" +seed=1 2>&1)
  if echo "$out" | grep -q "^PASS"; then
    echo "$m  MISSED   ${DESC[$m]}"
  else
    caught=$((caught+1))
    why=$(echo "$out" | grep -m1 -E "ERROR|Assertion failed|FAIL" | sed 's/^\[[0-9]*\] //' | cut -c1-90)
    echo "$m  CAUGHT   ${DESC[$m]}  <- $why"
  fi
done
echo "mutants caught: $caught / $total"
