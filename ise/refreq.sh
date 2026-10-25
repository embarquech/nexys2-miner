#!/bin/bash
# Re-clock an already placed and routed design: change only the DCM's
# CLKFX_MULTIPLY / CLKFX_DIVIDE through XDL, keep placement and routing.
#   bash refreq.sh <mul> <div> <tag> [ncd]   ->  out/<tag>.bit (JTAG load)
HERE=$(cd "$(dirname "$0")" && pwd)
MUL=$1; DIV=$2; TAG=$3
NCD=${4:-/tmp/nexys2-build/miner_top.ncd}
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
