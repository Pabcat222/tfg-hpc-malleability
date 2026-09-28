#!/usr/bin/env bash
# extrae_iter.sh <log> [iter]
# Devuelve: <t> <E/S acumulada> <nº volcados contados> <líneas IOPerf sin marca de tiempo>
#
# Las líneas IOPerf aparecen en DOS formatos: el normal, con el prefijo
# "IOTimeStamp <t> NumRanks: <n> s:", y otro sin prefijo, cuando la salida de
# varios rangos se entremezcla y lo pierde. Las segundas no dan tiempo pero SÍ
# dan tiempo de E/S, así que hay que sumarlas o la E/S sale corta.
awk -v LIM="${2:-185760}" '
  $1=="IOTimeStamp" && $6=="IOPerf" && NF>=12 { it=$7+0;  io=$10+0; t_=$2+0; ok=1 }
  $1=="IOPerf"                     && NF>=7  { it=$2+0;  io=$5+0;  ok=1; nsin++ }
  ok && it<=LIM { acc+=io; n++; if(t_>0){t=t_} ; ok=0; next }
  { ok=0 }
  END { printf "%.1f %.1f %d %d\n", t, acc, n, nsin+0 }
' "$1"
