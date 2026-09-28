#!/usr/bin/env python3
"""Mide a la iteración común 185760 e integra el NumRanks real, igual que
graficar_ce3_momento_magnitud.py. Imprime t, núcleos·hora y E/S de cada log."""
import re, sys, glob
from pathlib import Path

ITER_COMUN = 185760
RE_LINEA = re.compile(r"IOTimeStamp\s+([\d.]+)\s+NumRanks:\s+(\d+).*?IOPerf\s+(\d+)")

def medida(path):
    ts, ranks = [], []
    for linea in open(path, errors="ignore"):
        m = RE_LINEA.search(linea)
        if m and int(m.group(3)) <= ITER_COMUN:
            ts.append(float(m.group(1)))
            ranks.append(int(m.group(2)))
    if not ts:
        return None
    consumo, t_prev, r_prev = 0.0, 0.0, ranks[0]
    for t, r in zip(ts, ranks):
        consumo += r_prev * (t - t_prev)
        t_prev, r_prev = t, r
    return ts[-1], consumo / 3600.0, max(ranks), len(ts)

BASE = Path.home() / "Escritorio/TFG/xpn-docker/install-src/EpiGraphFlexMPI-XPN/logs_ya_mirados/tucan"

GRUPOS = {
    # --- lote nuevo (16-ago) ---
    "NUEVO est8":   "lote_ce3_16ago/ce3_est8_r*/001_*.log",
    "NUEVO est16":  "lote_ce3_16ago/ce3_est16_r*/001_*.log",
    "NUEVO est64":  "lote_ce3_16ago/ce3_est64_r*/001_*.log",
    "NUEVO m8a16":  "lote_ce3_16ago/ce3_m8a16_r*/001_*.log",
    "NUEVO m8a32":  "lote_ce3_16ago/ce3_m8a32_r*/001_*.log",
    "NUEVO m8a64":  "lote_ce3_16ago/ce3_m8a64_r*/001_*.log",
    "NUEVO d30":    "lote_ce3_16ago/ce3_d30_r*/001_*.log",
    "NUEVO d50":    "lote_ce3_16ago/ce3_d50_r*/001_*.log",
    # --- campaña de julio (up-scaling, n=1) ---
    "JUL m8a16":    "maleabilidad/1_upscaling/8_16/001_*.log",
    "JUL m8a32":    "maleabilidad/1_upscaling/8_32/001_*.log",
    "JUL m8a64":    "maleabilidad/1_upscaling/8_64/001_*.log",
    "JUL est16":    "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/multinodo/16app_2xpn/001_*.log",
    "JUL est64":    "estaticos/poblacion_gra/despues_parche_xpn/64_procesos/multinodo/64app_2xpn/001_*.log",
    # --- co-maleabilidad, barrido de días (n=1 previo) ---
    "COM d30p40":   "maleabilidad/5_comaleabilidad/8_40_d30_G30p40/001_comall*.log",
    "COM d40p40":   "maleabilidad/5_comaleabilidad/8_40_d40_C40/001_comall_C40_8_40*.log",
    "COM d50p40":   "maleabilidad/5_comaleabilidad/8_40_d50_G50p40/001_comall*.log",
}

for nombre, patron in GRUPOS.items():
    paths = sorted(p for p in glob.glob(str(BASE / patron)) if not p.endswith("_errores.log"))
    if not paths:
        print(f"{nombre:16s}  -- sin logs ({patron})")
        continue
    filas = []
    for p in paths:
        r = medida(p)
        if r:
            filas.append((r, Path(p).parent.name))
    if not filas:
        print(f"{nombre:16s}  -- sin líneas útiles")
        continue
    ts = [f[0][0] for f in filas]
    ch = [f[0][1] for f in filas]
    print(f"{nombre:16s} n={len(filas)}  t={sum(ts)/len(ts):8.1f}  "
          f"[{min(ts):.1f}-{max(ts):.1f}]  coreh={sum(ch)/len(ch):6.2f}  "
          f"maxranks={ {f[0][2] for f in filas} }  nvolc={ {f[0][3] for f in filas} }")
    for (r, d) in filas:
        print(f"                    {d:22s} t={r[0]:8.1f}  coreh={r[1]:6.2f}  ranks={r[2]}")
