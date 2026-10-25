#!/bin/bash
# Build the Pmod JA wiring probe (hdl/ja_probe.vhd) into out/ja_probe.bit.
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=/tmp/ja-probe
trap 'cp $SRC/*.log $HERE/out/ 2>/dev/null' EXIT
set -e
. "$(ls /opt/Xilinx/*/ISE_DS/settings64.sh | head -1)" > /dev/null
rm -rf "$SRC" && mkdir -p "$SRC" && cp "$HERE"/../hdl/ja_probe.vhd "$HERE"/../hdl/ja_probe.ucf "$SRC"/ && cd "$SRC"
echo 'vhdl work "ja_probe.vhd"' > p.prj
printf 'run\n-ifn p.prj\n-ifmt mixed\n-ofn ja_probe.ngc\n-ofmt NGC\n-p xc3s500e-fg320-4\n-top ja_probe\n' > p.xst
xst -ifn p.xst > xst.log
ngdbuild -uc ja_probe.ucf -p xc3s500e-fg320-4 ja_probe.ngc ja_probe.ngd > ngd.log
map -w -p xc3s500e-fg320-4 -o map.ncd ja_probe.ngd ja_probe.pcf > map.log
par -w map.ncd ja_probe.ncd ja_probe.pcf > par.log
bitgen -w -g StartUpClk:JtagClk ja_probe.ncd ja_probe.bit > bitgen.log
cp ja_probe.bit "$HERE"/out/ && echo PROBE OK
