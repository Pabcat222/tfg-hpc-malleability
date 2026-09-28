#!/usr/bin/env python3
"""Figuras de la variabilidad de las medidas (§5.5.1 de la memoria).

Genera dos figuras a partir de los logs archivados, sin cifras escritas a mano:

  variabilidad_ejecuciones.png   dispersión entre ejecuciones y entre despliegues
                                 sobre la campaña de co-maleabilidad
  variabilidad_configs.png       dispersión entre despliegues de las diez
                                 configuraciones estáticas medidas dos veces

Uso:  python3 graficar_variabilidad.py [directorio_de_salida]
"""

import sys
import glob
import statistics
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

ITER_COMUN = 185760

BASE = Path(__file__).resolve().parent
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_variabilidad"

# Ranuras 1 y 2 de la paleta categórica de referencia, validadas como pareja.
AZUL = "#2a78d6"
NARANJA = "#eb6834"
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"
SUPERFICIE = "#ffffff"


def extrae(ruta, limite=ITER_COMUN):
    """Tiempo y E/S acumulada hasta `limite`.

    Las líneas IOPerf aparecen en dos formatos: el normal, precedido de
    'IOTimeStamp <t> NumRanks: <n> s:', y otro sin ese prefijo, cuando la salida
    de varios rangos se entremezcla y lo pierde. Las segundas no dan tiempo pero
    sí tiempo de E/S, así que hay que sumarlas o la E/S sale corta.
    """
    t = acc = 0.0
    with open(ruta, errors="replace") as fh:
        for linea in fh:
            if "IOPerf" not in linea:
                continue
            c = linea.split()
            if c[0] == "IOTimeStamp" and len(c) >= 12 and c[5] == "IOPerf":
                it, io, marca = c[6], c[9], c[1]
            elif c[0] == "IOPerf" and len(c) >= 7:
                it, io, marca = c[1], c[4], None
            else:
                continue
            try:
                it, io = int(it), float(io)
            except ValueError:
                continue
            if it > limite:
                continue
            acc += io
            if marca is not None:
                t = float(marca)
    return t, acc


def unico(patron):
    hits = [p for p in glob.glob(str(BASE / patron)) if "errores" not in p]
    if not hits:
        raise SystemExit(f"no encuentro: {patron}")
    return hits[0]


def dispersion(a, b):
    """Diferencia relativa a la media, en tanto por ciento."""
    return abs(a - b) / ((a + b) / 2) * 100


def coma(x, dec=1):
    """Número con la coma decimal del castellano."""
    return f"{x:.{dec}f}".replace(".", ",")


def estilo(ax):
    ax.set_facecolor(SUPERFICIE)
    for lado in ("top", "right"):
        ax.spines[lado].set_visible(False)
    for lado in ("left", "bottom"):
        ax.spines[lado].set_color(TINTA_3)
        ax.spines[lado].set_linewidth(0.8)
    ax.tick_params(colors=TINTA_2, labelsize=9, length=3, width=0.8)


# ---------------------------------------------------------------- figura 1
CAMPANA = "maleabilidad/5_comaleabilidad/8_40_d40_C40_shrink_REAL"
# s1-s2 y s3-s6 se ejecutaron sobre dos despliegues distintos.
DESPLIEGUE = {"s1": "A", "s2": "A", "s3": "B", "s4": "B", "s5": "B", "s6": "B"}
MINDAY = 1440  # iteraciones por día simulado
DIA_SHRINK = 40


def serie(ruta, limite=ITER_COMUN):
    """Pares (iteración, tiempo transcurrido) de los volcados de estado."""
    pares = []
    with open(ruta, errors="replace") as fh:
        for linea in fh:
            if "IOPerf" not in linea:
                continue
            c = linea.split()
            if c[0] != "IOTimeStamp" or len(c) < 12 or c[5] != "IOPerf":
                continue
            try:
                it, marca = int(c[6]), float(c[1])
            except ValueError:
                continue
            if it <= limite:
                pares.append((it, marca))
    pares.sort()
    return pares


def figura_ejecuciones():
    """Las dos ejecuciones de un mismo despliegue que más se alejan entre sí.

    Se trabaja dentro de un único despliegue para que la figura mida sólo la
    variabilidad entre ejecuciones, sin el desplazamiento que introduce
    cambiar de despliegue. Se toma el que más repeticiones tiene, y de él la
    más rápida y la más lenta a la iteración común.
    """
    tiempos = {s: extrae(unico(f"{CAMPANA}/001_comall_C40sr_8_40_{s}.log"))[0]
               for s in DESPLIEGUE}
    despliegue = max(set(DESPLIEGUE.values()),
                     key=lambda d: sum(1 for s in DESPLIEGUE if DESPLIEGUE[s] == d))
    corridas = [s for s in tiempos if DESPLIEGUE[s] == despliegue]
    lenta = max(corridas, key=tiempos.get)
    rapida = min(corridas, key=tiempos.get)
    brecha = tiempos[lenta] - tiempos[rapida]
    brecha_pct = dispersion(tiempos[lenta], tiempos[rapida])

    fig, (ax, axd) = plt.subplots(2, 1, figsize=(7.2, 4.6), dpi=200, sharex=True,
                                  gridspec_kw=dict(height_ratios=[2.1, 1],
                                                   hspace=0.18))
    estilo(ax)
    estilo(axd)

    curvas = {}
    for s, color in ((lenta, NARANJA), (rapida, AZUL)):
        pares = serie(unico(f"{CAMPANA}/001_comall_C40sr_8_40_{s}.log"))
        curvas[s] = dict(pares)
        ax.plot([it / MINDAY for it, _ in pares], [t for _, t in pares],
                color=color, lw=1.8, zorder=4,
                label=("Más lenta" if s is lenta else "Más rápida") +
                      f": {coma(tiempos[s], 1)} s")

    dia_fin = ITER_COMUN / MINDAY
    for eje in (ax, axd):
        eje.axvline(DIA_SHRINK, color=TINTA_3, lw=0.9, ls=(0, (4, 3)), zorder=1)
    ax.annotate("reconfiguración (día 40)", (DIA_SHRINK + 1.5, 0.06),
                xycoords=("data", "axes fraction"), fontsize=8.5, color=TINTA_2)

    ax.set_xlim(0, dia_fin * 1.02)
    ax.set_ylim(0, tiempos[lenta] * 1.06)
    ax.set_ylabel("Tiempo transcurrido (s)", fontsize=10, color=TINTA)
    ax.set_title("Las dos ejecuciones más separadas de las "
                 f"{len(corridas)} de un mismo despliegue",
                 fontsize=11, color=TINTA, loc="left", pad=26)
    leg = ax.legend(frameon=False, fontsize=9, loc="lower left", ncols=2,
                    bbox_to_anchor=(0.0, 1.005), borderaxespad=0)
    for t in leg.get_texts():
        t.set_color(TINTA_2)
    ax.grid(axis="y", color=TINTA_3, alpha=0.25, lw=0.6)
    ax.set_axisbelow(True)

    # Panel inferior: la diferencia entre ambas, que en el de arriba no se ve.
    comunes = sorted(set(curvas[lenta]) & set(curvas[rapida]))
    dias = [it / MINDAY for it in comunes]
    dif = [curvas[lenta][it] - curvas[rapida][it] for it in comunes]
    axd.fill_between(dias, 0, dif, color=TINTA_3, alpha=0.30, lw=0, zorder=2)
    axd.plot(dias, dif, color=TINTA, lw=1.4, zorder=3)
    axd.axhline(0, color=TINTA_3, lw=0.9, zorder=1)
    axd.scatter([dia_fin], [brecha], s=42, color=TINTA, zorder=4,
                edgecolors=SUPERFICIE, linewidths=1.2)
    axd.annotate(f"{coma(brecha, 1)} s ({coma(brecha_pct, 1)} %)",
                 (dia_fin - 2.5, brecha), ha="right", va="center",
                 fontsize=9.5, color=TINTA)
    axd.set_ylim(min(0, min(dif) * 1.2), brecha * 1.35)
    axd.set_xlabel("Día simulado", fontsize=10, color=TINTA)
    axd.set_ylabel("Diferencia (s)", fontsize=10, color=TINTA)
    axd.grid(axis="y", color=TINTA_3, alpha=0.25, lw=0.6)
    axd.set_axisbelow(True)

    salida = SALIDA / "variabilidad_ejecuciones.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)
    print(f"  {salida.name}: despliegue {despliegue}, "
          f"{lenta} {tiempos[lenta]:.1f} s vs {rapida} "
          f"{tiempos[rapida]:.1f} s → {brecha:.1f} s ({brecha_pct:.1f} %); "
          f"seis ejecuciones " +
          " ".join(f"{s}={tiempos[s]:.1f}" for s in sorted(tiempos)))
    return brecha, brecha_pct


# ---------------------------------------------------------------- figura 2
CONFIGS = [
    ("8 proc., NFS", "estaticos/poblacion_gra/despues_parche_xpn/8_procesos/8_nodos_sin_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce1_8p_nfs/*.log"),
    ("8 proc., colocalizado", "estaticos/poblacion_gra/despues_parche_xpn/8_procesos/8_nodos_colocalizado/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce4_8p_lb/*.log"),
    ("8 proc., sin balanceo", "estaticos/poblacion_gra/despues_parche_xpn/8_procesos/8_nodos_sin_rebalanceo/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce4_8p_nolb/*.log"),
    ("16 proc., NFS", "estaticos/poblacion_gra/antes_parche_xpn/16_procesos/16_nodos_sin_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce1_16p_nfs/*.log"),
    ("16 proc., colocalizado", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_colocalizado/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce4_16p_lb/*.log"),
    ("16 proc., sin balanceo", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_sin_rebalanceo/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce4_16p_nolb/*.log"),
    ("16 proc., 2 servidores", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_2_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce2_16p_x2/*.log"),
    ("16 proc., 4 servidores", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_4_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce2_16p_x4/*.log"),
    ("16 proc., 8 servidores", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_8_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce2_16p_x8/*.log"),
    ("16 proc., 16 servidores", "estaticos/poblacion_gra/despues_parche_xpn/16_procesos/16_nodos_16_expand/*.log",
     "estaticos/poblacion_gra/lote_n2_11ago/ce2_16p_x16/*.log"),
]


def figura_configs():
    filas = []
    for nombre, p1, p2 in CONFIGS:
        t1, io1 = extrae(unico(p1))
        t2, io2 = extrae(unico(p2))
        filas.append((nombre, dispersion(t1, t2), dispersion(io1, io2)))
    # De mayor a menor discrepancia en tiempo: arriba lo que peor se repite.
    filas.sort(key=lambda f: f[1], reverse=True)

    ys = list(range(len(filas)))
    alto = 0.36
    fig, ax = plt.subplots(figsize=(7.2, 4.8), dpi=200)
    estilo(ax)

    tope = max(f[2] for f in filas) * 1.22

    # Los dos umbrales que fija la sección, cada uno con su etiqueta.
    for x, texto in ((2, "umbral del tiempo, 2 %"), (13, "umbral de la E/S, 13 %")):
        ax.axvline(x, color=TINTA_3, lw=0.9, ls=(0, (4, 3)), zorder=1)
        ax.annotate(texto, (x, 0.005), xycoords=("data", "axes fraction"),
                    xytext=(4, 0), textcoords="offset points",
                    fontsize=8.5, color=TINTA_2, ha="left", va="bottom")

    for y, f in zip(ys, filas):
        for desp, valor, color in ((-alto / 2, f[1], AZUL), (+alto / 2, f[2], NARANJA)):
            ax.barh(y + desp, valor, height=alto, color=color, zorder=3)
            ax.annotate(f"{coma(valor, 1)} %", (valor, y + desp), xytext=(4, 0),
                        textcoords="offset points", va="center", fontsize=8,
                        color=TINTA_2)

    proxies = [Patch(color=AZUL, label="Tiempo total"),
               Patch(color=NARANJA, label="Tiempo de E/S")]

    ax.set_yticks(ys)
    ax.set_yticklabels([f[0] for f in filas], fontsize=9, color=TINTA_2)
    # Holgura abajo para las etiquetas de los umbrales.
    ax.set_ylim(len(filas) - 0.10, -0.75)
    ax.set_xlabel("Diferencia entre las dos medidas de la misma configuración (%)",
                  fontsize=10, color=TINTA)
    ax.set_title("Lo que cambia una medida al repetirla sobre otro despliegue",
                 fontsize=11, color=TINTA, loc="left", pad=30)
    ax.set_xlim(0, tope)
    ax.grid(axis="x", color=TINTA_3, alpha=0.25, lw=0.6)
    ax.set_axisbelow(True)
    leg = ax.legend(handles=proxies, frameon=False, fontsize=9, loc="lower left",
                    ncols=2, bbox_to_anchor=(0.0, 1.005), borderaxespad=0)
    for txt in leg.get_texts():
        txt.set_color(TINTA_2)

    salida = SALIDA / "variabilidad_configs.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)

    mt = sorted(f[1] for f in filas)
    mi = sorted(f[2] for f in filas)
    med = lambda v: statistics.median(v)
    print(f"  {salida.name}: tiempo mediana {med(mt):.1f} % máx {mt[-1]:.1f} % · "
          f"E/S mediana {med(mi):.1f} % máx {mi[-1]:.1f} %")
    return filas


if __name__ == "__main__":
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Iteración común: {ITER_COMUN}")
    figura_ejecuciones()
    figura_configs()
    print(f"Figuras en {SALIDA}")
