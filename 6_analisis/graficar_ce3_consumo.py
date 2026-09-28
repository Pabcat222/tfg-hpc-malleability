#!/usr/bin/env python3
"""Figura de §5.5.4 (CE3): las dos magnitudes a la vez, tiempo y consumo de recursos.

Compara la ejecución que sigue la demanda con la estática dimensionada al pico, que es la
comparación que cierra la subsección. La idea de la figura es que el consumo NO hay que
creérselo: se dibuja el número de procesos activos frente al tiempo de RELOJ, y entonces el
área bajo cada curva ES los núcleos x hora. La estática sale como un rectángulo alto; la
maleable, como una escalera que sube tarde. Se ve de un vistazo que una acaba antes y la
otra ocupa menos, que es justo lo que el texto afirma.

Ambas se recortan en la iteración común 185760, igual que todas las cifras de §5.5, así que
los totales que imprime coinciden con los de la prosa (3757,4 / 3353,8 s y 43,11 / 61,49).

Uso:  python3 graficar_ce3_consumo.py [directorio_de_salida]
"""

import re
import sys
import glob
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ITER_COMUN = 185760
# El consumo que declara el caso de estudio incluye los servidores de almacenamiento, no
# sólo los procesos de la aplicación (1 servidor = 1 núcleo reservado). Sin ellos el área
# de la figura no cuadraría con la cifra del texto: 41,02 + 2,09 = 43,11 y 59,62 + 1,86 =
# 61,49. Son 2 en las dos ejecuciones, fijos de principio a fin.
N_SERV = 2

BASE = Path(__file__).resolve().parent
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce3"

# (patrón, etiqueta, color) — el azul es el mismo que identifica a esta ejecución en la
# figura de calendarios; el gris, el que identifica a las estáticas en la de magnitud.
CALENDARIO = ("maleabilidad/4_waypoints/8_32_16_64_d42-64-80_run3/001_*.log",
              "Sigue la demanda", "#2a78d6")
ESTATICA = ("estaticos/poblacion_gra/despues_parche_xpn/64_procesos/multinodo/64app_2xpn/001_*.log",
            "64 procesos, estática", "#52514e")

TINTA = "#0b0b0b"
TINTA_2 = "#52514e"

RE_LINEA = re.compile(r"IOTimeStamp\s+([\d.]+)\s+NumRanks:\s+(\d+).*?IOPerf\s+(\d+)")


def serie(patron):
    """(tiempos de reloj, procesos activos) hasta la iteración común, y el consumo."""
    cands = [p for p in glob.glob(str(BASE / patron)) if not p.endswith("_errores.log")]
    if not cands:
        raise SystemExit(f"sin logs: {patron}")
    ts, ranks = [], []
    for linea in open(cands[0], errors="ignore"):
        m = RE_LINEA.search(linea)
        if m and int(m.group(3)) <= ITER_COMUN:
            ts.append(float(m.group(1)))
            ranks.append(int(m.group(2)))
    # consumo = integral del nº de procesos sobre el reloj (idéntico método al del resto
    # de la campaña: se acumula con el valor VIGENTE en cada tramo, no con el siguiente)
    consumo, t_prev, r_prev = 0.0, 0.0, ranks[0]
    for t, r in zip(ts, ranks):
        consumo += r_prev * (t - t_prev)
        t_prev, r_prev = t, r
    wall = ts[-1]
    return ts, ranks, wall, (consumo + N_SERV * wall) / 3600.0


datos = []
for patron, etiqueta, color in (CALENDARIO, ESTATICA):
    ts, ranks, wall, coreh = serie(patron)
    datos.append(dict(ts=ts, ranks=ranks, wall=wall, coreh=coreh,
                      etiqueta=etiqueta, color=color))
    print(f"  {etiqueta:24s} wall={wall:7.1f} s   consumo={coreh:5.2f} núcleos·hora")

d_mal, d_est = datos
dt = 100 * (d_mal["wall"] / d_est["wall"] - 1)
dc = 100 * (1 - d_mal["coreh"] / d_est["coreh"])
print(f"  -> {dt:+.1f} % de tiempo, {dc:+.1f} % de consumo")

fig, ejes = plt.subplots(2, 1, figsize=(8, 6.2), sharex=True, sharey=True)
x_max = max(d["wall"] for d in datos) * 1.06
y_max = (max(max(d["ranks"]) for d in datos) + N_SERV) * 1.26

for ax, d in zip(ejes, datos):
    # escalera: el nº de procesos se mantiene hasta el volcado siguiente
    total = [r + N_SERV for r in d["ranks"]]
    ax.step(d["ts"], total, where="post", color=d["color"], linewidth=2.0)
    ax.fill_between(d["ts"], d["ranks"], step="post", color=d["color"], alpha=0.22)
    # los servidores de almacenamiento, apilados encima: son parte del consumo
    ax.fill_between(d["ts"], d["ranks"], total, step="post", color="#8a8981", alpha=0.5)
    ax.axvline(d["wall"], color=d["color"], linestyle="--", linewidth=1.2, alpha=0.8)

    # el área, escrita dentro del área
    ax.text(d["wall"] * 0.72, max(d["ranks"]) * 0.45,
            f"{d['coreh']:.2f}".replace(".", ",") + " núcleos × hora\n(el área sombreada)",
            ha="center", va="center", fontsize=10.5, color=TINTA, fontweight="bold",
            linespacing=1.4)
    # el tiempo, junto a la línea del final
    ax.annotate(f"termina a los\n{d['wall']:.0f} s".replace(".", ","),
                xy=(d["wall"], y_max * 0.62), xytext=(8, 0),
                textcoords="offset points", fontsize=9.5, color=d["color"],
                fontweight="bold", va="center", linespacing=1.3)

    ax.set_title(d["etiqueta"], fontsize=12.5, fontweight="bold", color=TINTA, loc="left")
    ax.set_ylabel("Procesos activos", fontsize=11)
    ax.set_xlim(0, x_max)
    ax.set_ylim(0, y_max)
    ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    ax.set_axisbelow(True)
    for lado in ("top", "right"):
        ax.spines[lado].set_visible(False)

ejes[1].set_xlabel("Tiempo de reloj (s)", fontsize=11)
ejes[0].text(x_max * 0.015, y_max * 0.97,
             "la franja gris son los 2 servidores de almacenamiento,\n"
             "que también ocupan núcleos",
             ha="left", va="top", fontsize=8.5, color=TINTA_2, linespacing=1.35)

fig.suptitle("La misma simulación con dos configuraciones: cuánto tarda y cuánto ocupa\n"
             f"la maleable termina un {dt:.1f} % más tarde".replace(".", ",") +
             f" y ocupa un {dc:.1f} % menos".replace(".", ","),
             fontsize=12.5, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.93])

SALIDA.mkdir(exist_ok=True)
out = SALIDA / "ce3_consumo_vs_tiempo.png"
fig.savefig(out, dpi=150)
plt.close(fig)
print("escrito", out)
