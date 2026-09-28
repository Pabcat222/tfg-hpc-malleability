#!/usr/bin/env python3
"""Figura de CE1 (§5.5.2 de la memoria): en qué se va el tiempo con NFS y con XPN.

Descompone el tiempo transcurrido hasta la iteración común en tres partidas:
cómputo (RTIME acumulado del rango cero), entrada/salida (suma de las latencias
de los volcados, que es la medida que define CE1) y el resto, obtenido por
diferencia. Se promedia sobre todas las ejecuciones válidas de cada celda, que
es la regla declarada en §5.5.1, y la n viaja en la etiqueta del eje.

Sólo entran las cuatro celdas de CE1: NFS frente a XPN colocalizado, a 8 y 16
procesos. El barrido de servidores es CE2 y la ablación del balanceador, CE4.

El lote CE2 a n=2 del 13-ago-2026 repite las cuatro celdas de aquí, de modo que
desde el 16-ago-2026 la figura incorpora también esas ejecuciones y las celdas
pasan de n=3/4/2/2 a n=5/6/4/4.

Uso:  python3 graficar_ce1.py [directorio_de_salida]
"""

import re
import sys
import glob
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

ITER_COMUN = 185760

BASE = Path(__file__).resolve().parent
GRA = BASE / "estaticos/poblacion_gra"
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce1"

# Ranuras 1-3 de la paleta categórica de referencia. Validadas para todos los
# pares con el puerto de scripts/validate_palette.js: peor CVD 9,2 y peor visión
# normal 24,0. El aqua queda por debajo de 3:1 contra el fondo, de ahí que cada
# segmento lleve su valor escrito dentro (regla de relieve).
AZUL = "#2a78d6"
NARANJA = "#eb6834"
AQUA = "#1baf7a"
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"
SUPERFICIE = "#ffffff"

# Cada celda, con todos los despliegues en los que se ha medido.
CELDAS = {
    8: {
        "NFS": ["despues_parche_xpn/8_procesos/8_nodos_sin_expand",
                "lote_n2_11ago/ce1_8p_nfs",
                "lote_8p_excl_12ago/ce1_8p_nfs",
                "lote_ce2_n2_13ago/ce1_8p_nfs_r1",
                "lote_ce2_n2_13ago/ce1_8p_nfs_r2"],
        "XPN": ["despues_parche_xpn/8_procesos/8_nodos_colocalizado",
                "lote_n2_11ago/ce4_8p_lb",
                "lote_8p_excl_12ago/ce2_8p_coloc",
                "ce4_p35m_10ago/p35m_8p_nilb144_lb",
                "lote_ce2_n2_13ago/ce2_8p_coloc_r1",
                "lote_ce2_n2_13ago/ce2_8p_coloc_r2"],
    },
    16: {
        "NFS": ["antes_parche_xpn/16_procesos/16_nodos_sin_expand",
                "lote_n2_11ago/ce1_16p_nfs",
                "lote_ce2_n2_13ago/ce1_16p_nfs_r1",
                "lote_ce2_n2_13ago/ce1_16p_nfs_r2"],
        "XPN": ["despues_parche_xpn/16_procesos/16_nodos_colocalizado",
                "lote_n2_11ago/ce4_16p_lb",
                "lote_ce2_n2_13ago/ce2_16p_coloc_r1",
                "lote_ce2_n2_13ago/ce2_16p_coloc_r2"],
    },
}


def extrae(ruta, limite=ITER_COMUN):
    """Tiempo transcurrido, E/S acumulada y cómputo hasta `limite`.

    Las líneas IOPerf aparecen en dos formatos: el normal, precedido de
    'IOTimeStamp <t> NumRanks: <n> s:', y otro sin ese prefijo, cuando la salida
    de varios rangos se entremezcla y lo pierde. Las segundas no dan tiempo pero
    sí tiempo de E/S, así que hay que sumarlas o la E/S sale corta.
    """
    t = acc = 0.0
    rtime = None
    n_io = flops0 = 0
    with open(ruta, errors="replace") as fh:
        for linea in fh:
            if "IOPerf" in linea:
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
                n_io += 1
                if it > limite:
                    continue
                acc += io
                if marca is not None:
                    t = float(marca)
            elif linea.startswith("Iter:"):
                m = re.match(r"Iter:\s+(\d+).*RTIME::\s+([0-9.]+)", linea)
                if m and int(m.group(1)) <= limite:
                    v = float(m.group(2))
                    if v < 1e6:      # descarta la primera línea, PAPI sin inicializar
                        rtime = v
                if " FLOPs: 0 " in linea:
                    flops0 += 1
    return dict(t=t, io=acc, rtime=rtime, n_io=n_io, flops0=flops0)


def celda(subdirs):
    """Media de las ejecuciones válidas de una celda."""
    medidas = []
    for sub in subdirs:
        for ruta in sorted(glob.glob(str(GRA / sub / "*.log"))):
            if "errores" in ruta:
                continue
            r = extrae(ruta)
            if r["t"] == 0 or r["rtime"] is None:
                continue
            if r["n_io"] < 1300 or r["flops0"] > 0:
                print(f"  descartada {Path(ruta).name}: "
                      f"IOPerf={r['n_io']} FLOPs0={r['flops0']}")
                continue
            medidas.append(r)
    if not medidas:
        raise SystemExit(f"sin ejecuciones válidas en {subdirs}")
    n = len(medidas)
    med = lambda k: sum(m[k] for m in medidas) / n
    t, io, rtime = med("t"), med("io"), med("rtime")
    return dict(n=n, t=t, io=io, rtime=rtime, resto=t - io - rtime,
                tiempos=[m["t"] for m in medidas])


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


def figura(datos):
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 4.6), dpi=200, sharey=True,
                             gridspec_kw=dict(wspace=0.08))
    tope = max(d["t"] for panel in datos.values() for d in panel.values()) * 1.20
    ancho = 0.52

    for ax, (procs, panel) in zip(axes, sorted(datos.items())):
        estilo(ax)
        nfs, xpn = panel["NFS"], panel["XPN"]
        for x, d in ((0, nfs), (1, xpn)):
            base = 0.0
            partidas = ((d["rtime"], AZUL), (d["io"], NARANJA), (d["resto"], AQUA))
            for valor, color in partidas:
                # Separación de 2 px entre segmentos: el hueco deja ver el fondo
                # y evita que dos rellenos contiguos se lean como uno solo.
                ax.bar(x, valor, width=ancho, bottom=base, color=color,
                       linewidth=1.6, edgecolor=SUPERFICIE, zorder=3)
                # Un segmento demasiado fino no admite el número dentro: se
                # saca al margen antes que dejarlo desbordar sobre el vecino.
                if valor / tope < 0.06:
                    ax.annotate(coma(valor, 0), (x + ancho / 2, base + valor / 2),
                                xytext=(4, 0), textcoords="offset points",
                                ha="left", va="center", fontsize=8.5,
                                color=TINTA_2, zorder=5)
                else:
                    ax.annotate(coma(valor, 0), (x, base + valor / 2),
                                ha="center", va="center", fontsize=8.5,
                                color="#ffffff", zorder=5)
                base += valor
            ax.annotate(f"{coma(d['t'], 0)} s", (x, d["t"]), xytext=(0, 5),
                        textcoords="offset points", ha="center", fontsize=9,
                        color=TINTA)

        # La diferencia entre las dos barras, que es lo que la sección afirma.
        delta = (xpn["t"] - nfs["t"]) / nfs["t"] * 100
        ax.annotate(f"−{coma(abs(delta), 1)} %", (0.5, tope * 0.955),
                    ha="center", fontsize=10, color=TINTA)
        ax.annotate("", xy=(1, tope * 0.905), xytext=(0, tope * 0.905),
                    arrowprops=dict(arrowstyle="->", color=TINTA_2, lw=1.0))

        ax.set_xticks([0, 1])
        ax.set_xticklabels([f"NFS\n(n={nfs['n']})",
                            f"XPN colocalizado\n(n={xpn['n']})"],
                           fontsize=9, color=TINTA_2)
        ax.set_xlim(-0.62, 1.62)
        ax.set_ylim(0, tope)
        ax.set_title(f"{procs} procesos", fontsize=10, color=TINTA_2, pad=6)
        ax.grid(axis="y", color=TINTA_3, alpha=0.25, lw=0.6)
        ax.set_axisbelow(True)

    axes[0].set_ylabel("Tiempo hasta el punto de medida común (s)",
                       fontsize=10, color=TINTA)
    proxies = [Patch(color=AZUL, label="Cómputo"),
               Patch(color=NARANJA, label="Entrada/salida"),
               Patch(color=AQUA, label="Resto")]
    leg = fig.legend(handles=proxies, frameon=False, fontsize=9, ncols=3,
                     loc="upper left", bbox_to_anchor=(0.09, 1.02),
                     borderaxespad=0)
    for txt in leg.get_texts():
        txt.set_color(TINTA_2)

    salida = SALIDA / "ce1_descomposicion.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)
    print(f"  {salida}")


if __name__ == "__main__":
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Iteración común: {ITER_COMUN}")
    datos = {p: {k: celda(v) for k, v in panel.items()}
             for p, panel in CELDAS.items()}
    for procs, panel in sorted(datos.items()):
        nfs, xpn = panel["NFS"], panel["XPN"]
        print(f"\n{procs} procesos:")
        for nombre, d in (("NFS", nfs), ("XPN", xpn)):
            print(f"  {nombre:4s} n={d['n']}  t={coma(d['t'])}  "
                  f"cómputo={coma(d['rtime'])}  E/S={coma(d['io'])}  "
                  f"resto={coma(d['resto'])}   [{', '.join(coma(x) for x in d['tiempos'])}]")
        print(f"  Δt = {(xpn['t'] - nfs['t']) / nfs['t'] * 100:+.1f} %   "
              f"ΔE/S = {(xpn['io'] - nfs['io']) / nfs['io'] * 100:+.1f} %   "
              f"Δcómputo = {(xpn['rtime'] - nfs['rtime']) / nfs['rtime'] * 100:+.1f} %   "
              f"Δresto = {(xpn['resto'] - nfs['resto']) / nfs['resto'] * 100:+.1f} %")
    figura(datos)
