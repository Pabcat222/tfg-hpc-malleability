#!/usr/bin/env python3
"""Recompone tab:ce3_dia_destino con el lote CE3-B (17-ago).

Misma receta que mide_ce3.py y que graficar_ce3_momento_magnitud.py: iteración
común 185760 e integración del NumRanks real sobre el reloj. El consumo es de
APLICACIÓN, sin los servidores de almacenamiento, porque en estas celdas los
servidores también se mueven (8->4) y lo que se compara es consumo de la
aplicación.

Las celdas del día 78 quedan en DOS grupos separados y no se promedian entre
sí: las de julio despliegan 2 servidores y las del CE3-B, 8.
"""
import re, glob
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

BASE = Path(__file__).resolve().parent

# (día, destino) -> patrones. Varios patrones = varias campañas que SÍ se
# promedian (misma topología de 8 servidores, distinto despliegue).
CELDAS = {
    (30, 32): ["maleabilidad/5_comaleabilidad/8_32_d30_G30/001_comall*.log",
               "maleabilidad/5_comaleabilidad/_sondas_shrink/001_comall_G30_8_32_r2*.log",
               "lote_ce3b_17ago/ce3b_d30p32_r*/001_*.log"],
    (30, 40): ["maleabilidad/5_comaleabilidad/8_40_d30_G30p40/001_comall*.log",
               "lote_ce3_16ago/ce3_d30_r*/001_*.log"],
    # ⚠️ 8_32_d40_xpn8fijo_F1 NO entra: mantiene los 8 servidores fijos, mientras
    # que todas las celdas de la tabla los reducen de 8 a 4 el día de la
    # expansión. Es otra configuración, no una repetición.
    (40, 32): ["maleabilidad/5_comaleabilidad/8_32_d40_A/001_comall*.log"],
    (40, 40): ["maleabilidad/5_comaleabilidad/8_40_d40_C40/001_comall_C40_8_40*.log"],
    (40, 64): ["maleabilidad/5_comaleabilidad/8_64_d40*/001_comall*.log",
               "lote_ce3b_17ago/ce3b_d40p64_r*/001_*.log"],
    (50, 32): ["maleabilidad/5_comaleabilidad/8_32_d50_G50/001_comall*.log",
               "lote_ce3b_17ago/ce3b_d50p32_r*/001_*.log"],
    (50, 40): ["maleabilidad/5_comaleabilidad/8_40_d50_G50p40/001_comall*.log",
               "lote_ce3_16ago/ce3_d50_r*/001_*.log"],
    (78, 40): ["lote_ce3b_17ago/ce3b_d78p40_r*/001_*.log"],
    (78, 48): ["lote_ce3b_17ago/ce3b_d78p48_r*/001_*.log"],
    (78, 64): ["lote_ce3b_17ago/ce3b_d78p64_r*/001_*.log"],
}

# Las tres del día 78 con DOS servidores, que van en bloque aparte.
CELDAS_2SERV = {
    (78, 40): ["maleabilidad/4_waypoints/8_40_d78_run1b/001_*.log"],
    # Tres ficheros y sólo DOS ejecuciones: wp_run1_colgado.log es copia del
    # 001_ (los dos dan 5263,7 s) y run1_d13partial, pese al nombre, llega a la
    # iteración común y es la segunda ejecución (5273,9 s). Se deduplica por la
    # MEDIDA, nunca por el nombre ni por md5.
    (78, 48): ["maleabilidad/4_waypoints/8_48_d78_run1/001_xpn_mall*.log",
               "maleabilidad/4_waypoints/8_48_d78_run1/run1_d13partial.log",
               "maleabilidad/4_waypoints/8_48_d78_run1/wp_run1_colgado.log"],
    (78, 64): ["maleabilidad/4_waypoints/8_64_d78_run2/001_*.log"],
}

# Una run sólo cuenta si llega a la iteración común. Con nilb=144 eso son 1290
# volcados; el regex pierde los que salen sin marca de tiempo, así que el corte
# se pone holgado. Las sondas parciales (400-600 volcados) quedan fuera.
MIN_VOLCADOS = 1100

def resuelve(patrones):
    paths = []
    for pat in patrones:
        paths += [p for p in glob.glob(str(BASE / pat)) if not p.endswith("_errores.log")]
    return sorted(set(paths))

def informe(titulo, celdas):
    print(f"\n=== {titulo} ===")
    print(f"{'día':>4} {'dest':>5} {'n':>3} {'t (s)':>9} {'[rango]':>19} {'core-h':>7}  detalle")
    for (dia, dest), patrones in sorted(celdas.items()):
        paths = resuelve(patrones)
        filas = [(medida(p), Path(p).name) for p in paths]
        filas = [f for f in filas if f[0] and f[0][3] >= MIN_VOLCADOS]
        # Deduplicación por la MEDIDA: dos ficheros con el mismo tiempo son el
        # mismo log copiado, aunque tengan nombres distintos.
        vistos, unicas = set(), []
        for f in filas:
            clave = round(f[0][0], 1)
            if clave in vistos:
                continue
            vistos.add(clave)
            unicas.append(f)
        filas = unicas
        if not filas:
            print(f"{dia:>4} {dest:>5}   --  sin logs: {patrones}")
            continue
        ts = [f[0][0] for f in filas]
        ch = [f[0][1] for f in filas]
        rk = {f[0][2] for f in filas}
        media_t = sum(ts) / len(ts)
        media_c = sum(ch) / len(ch)
        print(f"{dia:>4} {dest:>5} {len(filas):>3} {media_t:9.1f} "
              f"[{min(ts):8.1f}-{max(ts):8.1f}] {media_c:7.2f}  ranks={sorted(rk)}")
        for (r, d) in filas:
            print(f"{'':>24} {d:26s} t={r[0]:8.1f} core-h={r[1]:6.2f} ranks={r[2]} volc={r[3]}")

informe("OCHO servidores de almacenamiento", CELDAS)
informe("DOS servidores (campaña de waypoints)", CELDAS_2SERV)
