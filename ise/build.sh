#!/bin/bash
# Command-line ISE 14.7 build of the Nexys2 miner, inside AMD's ISE Linux VM.
#   bash build.sh [part] [cores] [Speed|Area] [mul] [div] [tag] [ts_ns] [seed] [depp|uart] [display|nodisplay] [core]
#   core: an alternative to hdl/sha256_core.vhd, e.g. sha256_core_csa.vhd
#   12th arg: a UCF fragment in ise/ appended to the pin constraints (floorplan)
#   default: xc3s500e-fg320-4, 4 units, Speed, core clock 50 MHz * 6 / 5 = 60 MHz.
#   With a tag, the outputs are also kept as out/<tag>.bit and out/<tag>.svf.
#   ts_ns is the input period told to the timing tools (default 20 = the real
#   50 MHz). A longer one makes PAR aim below the real DCM output: asked for
#   the true overclocked target, PAR gives up and places far worse. seed picks
#   the PAR cost table (1..100). depp (default) talks to the PC over USB, uart
#   to an ESP32-S3 on Pmod JA.
# Outputs land in out/, next to this script, so Windows sees them through the
# shared folder:
#   miner_top.bit    JTAG load (sw/jtagprog.py), StartUpClk = JtagClk
#   miner_prom.svf   writes the XCF04S Platform Flash (sw/svfplay.py), so the
#                    FPGA boots the miner by itself with the mode jumper on ROM
PART=${1:-xc3s500e-fg320-4}
CORES=${2:-4}
OPT=${3:-Speed}
MUL=${4:-6}
DIV=${5:-5}
TAG=${6:-}
TS=${7:-20}
SEED=${8:-1}
HOST=${9:-depp}
SHOW_RATE=TRUE
CORE=${11:-sha256_core.vhd}
FLOORPLAN=${12:-}
[ "${10:-display}" = nodisplay ] && SHOW_RATE=FALSE
HOST_UART=FALSE
[ "$HOST" = uart ] && HOST_UART=TRUE
MAPOPT=""
[ "$OPT" = Area ] && MAPOPT="-cm area -c 100"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
SRC=/tmp/nexys2-build              # vboxsf mounts confuse XST's file locking
set -e
. "$(ls /opt/Xilinx/*/ISE_DS/settings64.sh | head -1)" > /dev/null

rm -rf "$SRC" && mkdir -p "$SRC" "$OUT"
cp "$HERE"/../hdl/*.vhd "$SRC"/
cp "$HERE/../hdl/$CORE" "$SRC"/sha256_core.vhd
sed "s/PERIOD \"clk50\" 20 ns/PERIOD \"clk50\" $TS ns/" "$HERE"/../hdl/nexys2.ucf > "$SRC"/nexys2.ucf
[ -n "$FLOORPLAN" ] && cat "$HERE/$FLOORPLAN" >> "$SRC"/nexys2.ucf
cd "$SRC"

cat > miner.prj <<EOF
vhdl work "sha256_pkg.vhd"
vhdl work "clkgen_dcm.vhd"
vhdl work "sha256_core.vhd"
vhdl work "miner_unit.vhd"
vhdl work "rate_display.vhd"
vhdl work "uart_bridge.vhd"
vhdl work "miner_top.vhd"
EOF

cat > miner.xst <<EOF
run
-ifn miner.prj
-ifmt mixed
-ofn miner_top.ngc
-ofmt NGC
-p $PART
-top miner_top
-opt_mode $OPT
-opt_level 1
-generics {NCORES=$CORES CLK_MUL=$MUL CLK_DIV=$DIV HOST_UART=$HOST_UART SHOW_RATE=$SHOW_RATE}
EOF

step() { echo "== $*"; "$@" > "$1.log" 2>&1 || { tail -40 "$1.log"; cp ./*.log ./*.syr ./*.mrp "$OUT"/ 2>/dev/null; echo "FAILED: $1"; exit 1; }; }

step xst      -ifn miner.xst -ofn miner_top.syr
step ngdbuild -uc nexys2.ucf -p "$PART" miner_top.ngc miner_top.ngd
step map      -w $MAPOPT -p "$PART" -o miner_top_map.ncd miner_top.ngd miner_top.pcf
step par      -w -t $SEED miner_top_map.ncd miner_top.ncd miner_top.pcf
step trce     -v 3 -o miner_top.twr miner_top.ncd miner_top.pcf
step bitgen   -w -g StartUpClk:JtagClk miner_top.ncd miner_top.bit
cp miner_top.ncd miner_prom.ncd
step bitgen   -w -g StartUpClk:Cclk miner_prom.ncd miner_prom.bit
step promgen  -w -p mcs -c FF -o miner_prom.mcs -x xcf04s -u 0 miner_prom.bit

# iMPACT writes the PROM programming sequence to an SVF file instead of a cable.
# Chain from TDI: position 1 = FPGA, position 2 = XCF04S (nearest TDO).
cat > prom.cmd <<EOF
setMode -bs
setCable -port svf -file "$SRC/miner_prom.svf"
addDevice -p 1 -part xc3s500e
addDevice -p 2 -part xcf04s
assignFile -p 2 -file "$SRC/miner_prom.mcs"
program -e -v -p 2
quit
EOF
step impact   -batch prom.cmd
[ -s miner_prom.svf ] || { echo "FAILED: impact wrote no SVF"; exit 1; }

cp miner_top.bit miner_prom.mcs miner_prom.svf miner_top.syr miner_top_map.mrp miner_top.twr ./*.log "$OUT"/
if [ -n "$TAG" ]; then cp miner_top.bit "$OUT/$TAG.bit"; cp miner_prom.svf "$OUT/$TAG.svf"; cp miner_top.twr "$OUT/$TAG.twr"; fi
grep -E "Number of Slices:|Number of 4 input LUTs:" miner_top_map.mrp
grep -E "Timing errors:|Minimum period:" miner_top.twr
echo "BUILD OK"
