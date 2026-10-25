#!/bin/bash
# Re-clock an already placed and routed design: change only the DCM's
# CLKFX_MULTIPLY / CLKFX_DIVIDE through XDL, keep placement and routing.
#   bash refreq.sh <mul> <div> <tag> [ncd] [prom]
#     -> out/<tag>.bit (JTAG load); with prom also out/<tag>.svf (PROM)
HERE=$(cd "$(dirname "$0")" && pwd)
MUL=$1; DIV=$2; TAG=$3
NCD=${4:-/tmp/nexys2-build/miner_top.ncd}
PROM=$5
W=/tmp/refreq-$TAG
set -e
. "$(ls /opt/Xilinx/*/ISE_DS/settings64.sh | head -1)" > /dev/null
rm -rf "$W" && mkdir -p "$W" && cd "$W"
xdl -ncd2xdl "$NCD" design.xdl > xdl1.log
grep -o "CLKFX_MULTIPLY::[0-9]*\|CLKFX_DIVIDE::[0-9]*" design.xdl | head -2
sed -i "s/CLKFX_MULTIPLY::[0-9]*/CLKFX_MULTIPLY::$MUL/; s/CLKFX_DIVIDE::[0-9]*/CLKFX_DIVIDE::$DIV/" design.xdl
grep -o "CLKFX_MULTIPLY::[0-9]*\|CLKFX_DIVIDE::[0-9]*" design.xdl | head -2
xdl -xdl2ncd design.xdl design.ncd > xdl2.log
bitgen -w -g StartUpClk:JtagClk design.ncd "$TAG.bit" > bitgen.log
cp "$TAG.bit" "$HERE/out/" && echo "REFREQ OK $TAG"

if [ "$PROM" = prom ]; then
  # Same steps as build.sh: CCLK start-up, MCS, then iMPACT writes an SVF.
  bitgen -w -g StartUpClk:Cclk design.ncd prom.bit > bitgen_prom.log
  promgen -w -p mcs -c FF -o prom.mcs -x xcf04s -u 0 prom.bit > promgen.log
  printf '%s\n' "setMode -bs" "setCable -port svf -file \"$W/prom.svf\"" \
    "addDevice -p 1 -part xc3s500e" "addDevice -p 2 -part xcf04s" \
    "assignFile -p 2 -file \"$W/prom.mcs\"" "program -e -v -p 2" "quit" > prom.cmd
  impact -batch prom.cmd > impact.log 2>&1
  [ -s prom.svf ] || { echo "FAILED: impact wrote no SVF"; exit 1; }
  cp prom.svf "$HERE/out/$TAG.svf" && echo "PROM OK $TAG"
fi
