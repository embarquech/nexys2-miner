#!/bin/bash
# Legal SLICE sites of the XC3S500E, and the nearest legal corners of four
# quadrants, for AREA_GROUP RANGE constraints.
. "$(ls /opt/Xilinx/*/ISE_DS/settings64.sh | head -1)" > /dev/null
cd /tmp && xdl -report xc3s500efg320 s500e.xdlrc > /dev/null 2>&1
grep -o '(primitive_site SLICE_X[0-9]*Y[0-9]*' s500e.xdlrc | sed 's/.*SLICE_X//; s/Y/ /' > sites.txt
wc -l < sites.txt
awk 'function corner(x0,x1,y0,y1,  best,bx,by,d) {
       # lower-left: legal site in the box closest to (x0,y0)
       best=1e9; for (k in X) { if (X[k]>=x0&&X[k]<=x1&&Y[k]>=y0&&Y[k]<=y1) { d=(X[k]-x0)+(Y[k]-y0); if(d<best){best=d;bx=X[k];by=Y[k]} } }
       ll="SLICE_X" bx "Y" by
       best=1e9; for (k in X) { if (X[k]>=x0&&X[k]<=x1&&Y[k]>=y0&&Y[k]<=y1) { d=(x1-X[k])+(y1-Y[k]); if(d<best){best=d;bx=X[k];by=Y[k]} } }
       return ll ":SLICE_X" bx "Y" by }
     { X[NR]=$1; Y[NR]=$2 }
     END { print "U0", corner(0,33,0,45); print "U1", corner(34,67,0,45);
           print "U2", corner(0,33,46,91); print "U3", corner(34,67,46,91) }' sites.txt
