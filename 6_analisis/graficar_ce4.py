#!/usr/bin/env python3
"""Figura de CE4 (§5.5.5 de la memoria): cuándo compensa el rebalanceo.

El resultado de CE4 no es una magnitud sino un cambio de signo: el mismo
mecanismo ahorra una cuarta parte del tiempo en unas condiciones y lo encarece
en otras. Por eso la figura no representa tiempos absolutos ---que van de 1122 a
7064 segundos y no caben en un eje común--- sino el efecto de activar el
balanceo, siempre con la misma definición: la variación del tiempo con balanceo
respecto al tiempo sin balanceo, medida sobre parejas de ejecuciones que sólo
difieren en la política. Cuando una celda reúne más de una pareja se promedian
los tiempos de cada rama, y la n de la etiqueta es el número de parejas.

Las barras se agrupan en los tres ejes que la sección recorre. La celda del
clúster con volcado diario aparece en los dos primeros grupos porque es el punto
que ambos comparten: es el mismo par de ejecuciones, no dos medidas distintas.

La banda gris es el ruido de despliegue medido en §5.5.1. Lo que cae dentro no
tiene signo, y se dibuja en gris para que no se lea como resultado.

Uso:  python3 graficar_ce4.py [directorio_de_salida]
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
RUIDO = 1.0          # ruido de despliegue, en por ciento (§5.5.1)

BASE = Path(__file__).resolve().parent
GRA = BASE / "estaticos/poblacion_gra"
PEQ = BASE / "estaticos/poblacion_peq"
PORT = BASE.parent / "portatil/stat_xpn"
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce4"

# Misma paleta que el resto de figuras de la memoria.
AZUL = "#2a78d6"
NARANJA = "#eb6834"
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"
GRIS = "#b9b8b2"
SUPERFICIE = "#ffffff"

# Cada pareja: (etiqueta, ruta con balanceo, ruta sin balanceo, volcados/día).
# El número de volcados fija cuántas líneas IOPerf debe traer una ejecución
# válida: 10 por día son 1300, y 1 por día son 130.
GRUPOS = [
    ("Hardware", "Población de 800 826, 1 volcado por día, 8 procesos", [
        ("Equipo local",
         PORT / "8_nodos", PORT / "8_nodos_sin_rebalanceo", 1),
        ("Clúster Tucán",
         PEQ / "ce4_control_9ago/p800k_nilb1440_lb",
         PEQ / "ce4_control_9ago/p800k_nilb1440_nolb", 1),
    ]),
    ("Cadencia de evaluación", "Clúster Tucán, población de 800 826, 8 procesos", [
        ("1 volcado por día",
         PEQ / "ce4_control_9ago/p800k_nilb1440_lb",
         PEQ / "ce4_control_9ago/p800k_nilb1440_nolb", 1),
        ("10 volcados por día",
         [PEQ / "ce4_control_9ago/p800k_nilb144_lb",
          PEQ / "ce4_control_9ago/p800k_nilb144_lb_r2"],
         [PEQ / "ce4_control_9ago/p800k_nilb144_nolb",
          PEQ / "ce4_control_9ago/p800k_nilb144_nolb_r2"], 10),
    ]),
    ("Tamaño de la población", "Clúster Tucán, 10 volcados por día", [
        ("800 826, 8 procesos",
         [PEQ / "ce4_control_9ago/p800k_nilb144_lb",
          PEQ / "ce4_control_9ago/p800k_nilb144_lb_r2"],
         [PEQ / "ce4_control_9ago/p800k_nilb144_nolb",
          PEQ / "ce4_control_9ago/p800k_nilb144_nolb_r2"], 10),
        ("3 511 110, 8 procesos",
         [GRA / "ce4_p35m_10ago/p35m_8p_nilb144_lb",
          GRA / "lote_n2_11ago/ce4_8p_lb"],
         [GRA / "ce4_p35m_10ago/p35m_8p_nilb144_nolb",
          GRA / "lote_n2_11ago/ce4_8p_nolb"], 10),
        ("3 511 110, 16 procesos",
         GRA / "lote_n2_11ago/ce4_16p_lb",
         GRA / "lote_n2_11ago/ce4_16p_nolb", 10),
    ]),
]


def extrae(ruta, limite=ITER_COMUN):
    """Tiempo transcurrido hasta `limite`, más los datos de validez.

    Las líneas IOPerf aparecen en dos formatos: el normal, precedido de
    'IOTimeStamp <t> NumRanks: <n> s:', y otro sin ese prefijo, cuando la salida
    de varios rangos se entremezcla y lo pierde. Aquí sólo interesa el tiempo,
    que viene del primero, pero las segundas cuentan para el recuento.
    """
    t = 0.0
    n_io = flops0 = 0
    with open(ruta, errors="replace") as fh:
        for linea in fh:
            if "IOPerf" in linea:
                c = linea.split()
                if c[0] == "IOTimeStamp" and len(c) >= 12 and c[5] == "IOPerf":
                    it, marca = c[6], c[1]
                elif c[0] == "IOPerf" and len(c) >= 7:
                    it, marca = c[1], None
                else:
                    continue
                try:
                    it = int(it)
                except ValueError:
                    continue
                n_io += 1
                if it <= limite and marca is not None:
                    t = float(marca)
            elif linea.startswith("Iter:") and " FLOPs: 0 " in linea:
                flops0 += 1
    return dict(t=t, n_io=n_io, flops0=flops0)


def celda(dirs, volcados):
    """Media de las ejecuciones válidas de una celda.

    Sin la métrica de coma flotante el balanceador se queda sin entrada, de modo
    que una ejecución con ceros no informa sobre el rebalanceo y no entra.
    """
    minimo = 130 * volcados
    tiempos = []
    for d in (dirs if isinstance(dirs, list) else [dirs]):
        for ruta in sorted(glob.glob(str(d / "*.log"))):
            if "errores" in ruta:
                continue
            r = extrae(ruta)
            if r["t"] == 0:
                continue
            if r["n_io"] < minimo or r["flops0"] > 0:
                print(f"    descartada {Path(ruta).name}: "
                      f"IOPerf={r['n_io']} FLOPs0={r['flops0']}")
                continue
            tiempos.append(r["t"])
    if not tiempos:
        raise SystemExit(f"sin ejecuciones válidas en {dirs}")
    return sum(tiempos) / len(tiempos), len(tiempos), tiempos


def coma(x, dec=1):
    """Número con la coma decimal del castellano."""
    return f"{x:.{dec}f}".replace(".", ",")


def figura(filas):
    n_barras = sum(1 for f in filas if f["y"] is not None)
    n_grupos = len(filas) - n_barras
    alto = 0.42 * n_barras + 0.38 * n_grupos + 1.35
    fig, ax = plt.subplots(figsize=(7.2, alto), dpi=200)
    ax.set_facecolor(SUPERFICIE)

    deltas = [f["delta"] for f in filas if f["y"] is not None]
    # Márgenes asimétricos: el hueco a cada lado sólo tiene que dar cabida a la
    # etiqueta de la barra más extrema, no a la simetría del eje.
    izq = min(deltas) * 1.30 - 6.0
    der = max(deltas) * 1.30 + 5.0
    ax.axvspan(-RUIDO, RUIDO, color=GRIS, alpha=0.35, zorder=1)
    ax.axvline(0, color=TINTA_2, lw=0.9, zorder=4)

    for f in filas:
        if f["y"] is None:
            continue
        d = f["delta"]
        nulo = abs(d) <= RUIDO
        color = GRIS if nulo else (AZUL if d < 0 else NARANJA)
        ax.barh(f["y"], d, height=0.50, color=color, zorder=3)
        # El valor va siempre fuera de la barra, del lado que apunta: dentro no
        # cabe en las que caen en la banda de ruido.
        off = 5 if d >= 0 else -5
        ax.annotate(f"{'+' if d > 0 else '−'}{coma(abs(d))} %",
                    (d, f["y"]), xytext=(off, 0), textcoords="offset points",
                    ha="left" if d >= 0 else "right", va="center",
                    fontsize=8.5, color=TINTA if not nulo else TINTA_2, zorder=5)

    etiquetas, posiciones = [], []
    for f in filas:
        if f["y"] is None:      # cabecera de grupo
            ax.annotate(f["titulo"], (izq, f["ycab"]), xytext=(0, 0),
                        textcoords="offset points", ha="left", va="center",
                        fontsize=9.5, color=TINTA, weight="bold")
            ax.annotate(f["sub"], (izq, f["ycab"] - 0.36), ha="left",
                        va="center", fontsize=8, color=TINTA_3)
        else:
            posiciones.append(f["y"])
            etiquetas.append(f"{f['etiqueta']}  (n={f['n']})")

    ax.set_yticks(posiciones)
    ax.set_yticklabels(etiquetas, fontsize=8.5, color=TINTA_2)
    ax.set_xlim(izq, der)
    ax.set_ylim(min(f["y"] for f in filas if f["y"] is not None) - 0.55,
                max(f["ycab"] for f in filas if f["y"] is None) + 0.55)
    ax.set_xlabel("Variación del tiempo al activar el balanceo (\\%)"
                  .replace("\\%", "%"), fontsize=9.5, color=TINTA)
    for lado in ("top", "right", "left"):
        ax.spines[lado].set_visible(False)
    ax.spines["bottom"].set_color(TINTA_3)
    ax.spines["bottom"].set_linewidth(0.8)
    ax.tick_params(axis="x", colors=TINTA_2, labelsize=8.5, length=3, width=0.8)
    ax.tick_params(axis="y", length=0)
    ax.grid(axis="x", color=TINTA_3, alpha=0.22, lw=0.6)
    ax.set_axisbelow(True)

    proxies = [Patch(color=AZUL, label="El balanceo acelera"),
               Patch(color=NARANJA, label="El balanceo penaliza"),
               Patch(color=GRIS, label=f"Ruido de despliegue (±{coma(RUIDO)} %)")]
    leg = fig.legend(handles=proxies, frameon=False, fontsize=8.5, ncols=3,
                     loc="lower center", bbox_to_anchor=(0.52, -0.02))
    for txt in leg.get_texts():
        txt.set_color(TINTA_2)

    salida = SALIDA / "ce4_ejes.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)
    print(f"\n  {salida}")


if __name__ == "__main__":
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Iteración común: {ITER_COMUN}\n")

    filas, y = [], 0.0
    for titulo, sub, parejas in GRUPOS:
        y -= 1.30
        filas.append(dict(y=None, ycab=y, titulo=titulo, sub=sub))
        print(f"{titulo} — {sub}")
        for etiqueta, con, sin, volcados in parejas:
            y -= 0.85
            t_con, n_con, l_con = celda(con, volcados)
            t_sin, n_sin, l_sin = celda(sin, volcados)
            delta = (t_con - t_sin) / t_sin * 100
            filas.append(dict(y=y, ycab=None, etiqueta=etiqueta,
                              n=min(n_con, n_sin), delta=delta))
            print(f"  {etiqueta:28s} con={coma(t_con)} (n={n_con}) "
                  f"sin={coma(t_sin)} (n={n_sin})  Δ={delta:+.1f} %")
        print()
    figura(filas)
