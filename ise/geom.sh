#!/bin/bash
# Slice grid and per-unit bounding boxes of a placed design (from its XDL).
X=${1:-/tmp/refreq-x_106/design.xdl}
grep -o '^inst "[^"]*" "SLICE[LM]*",placed [^ ]* SLICE_X[0-9]*Y[0-9]*' "$X" | \
awk '{ match($0,/SLICE_X([0-9]+)Y([0-9]+)/,m); x=m[1]; y=m[2];
       if (NR==1||x<minx) minx=x; if (x>maxx) maxx=x; if (NR==1||y<miny) miny=y; if (y>maxy) maxy=y;
       u="other"; if (match($0,/g_units\[([0-9])\]/,k)) u="unit" k[1];
       n[u]++; if(!(u in ax)||x<ax[u])ax[u]=x; if(x>bx[u])bx[u]=x; if(!(u in ay)||y<ay[u])ay[u]=y; if(y>by[u])by[u]=y }
     END { print "grid X", minx "-" maxx, "Y", miny "-" maxy;
           for (u in n) print u, n[u], "slices, X", ax[u] "-" bx[u], "Y", ay[u] "-" by[u] }'
