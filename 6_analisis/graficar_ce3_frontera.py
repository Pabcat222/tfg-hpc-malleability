#!/usr/bin/env python3
"""Figura de §5.5.4 (CE3): hasta dónde compensa ampliar el destino de la expansión.

El texto afirma que subir el pico de 40 a 64 procesos no siempre compra lo mismo: con la
expansión pedida tarde (día 78) el tiempo no se mueve y los recursos sí, mientras que con
la expansión pedida pronto (día 40) el tiempo sí baja. Lo que decide no es el tamaño, sino
cuánta simulación ---y sobre todo cuánta simulación CARA--- queda por delante cuando los
procesos nuevos entran a trabajar.

La figura tiene dos paneles, y ese orden es el del argumento:

  ARRIBA, el contexto que explica el resultado: lo que cuesta avanzar un día simulado, con
  las cuatro fases de la escena sombreadas y los dos días de expansión marcados. Se ve que
  el día 40 cae justo antes de que la primera onda encarezca la simulación y que el día 78
  llega con esa onda ya pasada. Se dibujan las dos ejecuciones de la pareja tardía: son
  indistinguibles antes de la expansión (las dos van con 8 procesos) y siguen siéndolo
  después, con 40 una y 64 la otra, que es justamente el empate que mide el panel de abajo.

  ABAJO, la medida: variación de tiempo y de recursos al subir el destino, en las dos
  parejas.

Se dibujan VARIACIONES, no valores absolutos, y por una razón: las dos parejas vienen de
campañas con distinta topología (la de d78 despliega 2 servidores de almacenamiento y la de
d40, 8), así que sus duraciones no son comparables entre sí. Lo que sí es comparable es qué
le pasa a cada pareja cuando se sube el destino, porque dentro de cada una lo único que
cambia es ese número. Por el mismo motivo el consumo es el DE APLICACIÓN: el almacenamiento
es idéntico en los dos extremos de cada flecha y sumarlo solo diluiría el efecto.

Los cuatro puntos se extraen igual que el resto de §5.5: recorte a la iteración común
185760 e integración del NumRanks realmente activo sobre el reloj (no del calendario
solicitado, ver la subsección sobre el cálculo del consumo).

Uso:  python3 graficar_ce3_frontera.py [directorio_de_salida]
"""

import re
import sys
import glob
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ITER_COMUN = 185760
MINDAY = 1440          # iteraciones por día simulado
# Umbral de ruido de la Sección de variabilidad: 1 % entre despliegues distintos con la
# misma configuración y ~2 % de dispersión entre ejecuciones. Se dibuja el más exigente.
RUIDO = 2.0

BASE = Path(__file__).resolve().parent
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce3"

AZUL = "#2a78d6"
NARANJA = "#eb6834"
VERDE = "#2e8b57"
MORADO = "#7b3fa0"
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"

# Fases de la escena simulada, iguales que en graficar_ce3_perfiles: la epidemia no arranca
# hasta el día 42, la primera onda ocupa hasta el 78, sigue un valle corto y una meseta.
FASES = [
    (0,   42,  "#e8ebe4", "Fase inicial\nbarata"),
    (42,  78,  "#fbe0d4", "1.ª onda\n(cara)"),
    (78,  84,  "#dbe8f7", "Valle"),
    (84,  130, "#fbe0d4", "Meseta final\n(cara)"),
]

RE_LINEA = re.compile(r"IOTimeStamp\s+([\d.]+)\s+NumRanks:\s+(\d+).*?IOPerf\s+(\d+)")

# (rótulo, patrón de los logs de destino 40, patrón de los de destino 64)
ESCENARIOS = [
    ("Expansión tardía (día 78)\ncon la primera onda ya pasada",
     "maleabilidad/4_waypoints/8_40_d78_run1b/001_xpn_mall*.log",
     "maleabilidad/4_waypoints/8_64_d78_run2/001_xpn_mall*.log"),
    ("Expansión temprana (día 40)\njusto antes de la primera onda",
     "maleabilidad/5_comaleabilidad/8_40_d40_C40/001_comall_C40_8_40*.log",
     "maleabilidad/5_comaleabilidad/8_64_d40_C/001_comall_C_8_64*.log"),
]


def serie(path):
    """(tiempos, procesos activos, iteraciones) de un log, hasta la iteración común."""
    ts, ranks, iters = [], [], []
    for linea in open(path, errors="ignore"):
        m = RE_LINEA.search(linea)
        if m and int(m.group(3)) <= ITER_COMUN:
            ts.append(float(m.group(1)))
            ranks.append(int(m.group(2)))
            iters.append(int(m.group(3)))
    if not ts:
        raise SystemExit(f"sin líneas útiles: {path}")
    return ts, ranks, iters


def medida(path):
    """(duración, núcleos·hora de aplicación) de un log, hasta la iteración común."""
    ts, ranks, _ = serie(path)
    # el consumo se acumula con el nº de procesos VIGENTE en cada tramo, igual que en
    # graficar_ce3_consumo.py, para que las cifras de las dos figuras sean el mismo número
    consumo, t_prev, r_prev = 0.0, 0.0, ranks[0]
    for t, r in zip(ts, ranks):
        consumo += r_prev * (t - t_prev)
        t_prev, r_prev = t, r
    return ts[-1], consumo / 3600.0


def coste_por_dia(path):
    """(días, segundos que cuesta avanzar cada día simulado) promediando sus volcados."""
    ts, _, iters = serie(path)
    por_dia = {}
    t_prev = 0.0
    for t, i in zip(ts, iters):
        por_dia.setdefault((i - 1) // MINDAY, []).append(t - t_prev)
        t_prev = t
    dias = sorted(por_dia)
    return dias, [sum(por_dia[d]) / len(por_dia[d]) for d in dias]


def logs(patron):
    ps = [p for p in sorted(glob.glob(str(BASE / patron)))
          if not p.endswith("_errores.log")]
    if not ps:
        raise SystemExit(f"sin logs: {patron}")
    return ps


def celda(patron):
    """Promedia todas las repeticiones que haya de una configuración."""
    ms = [medida(p) for p in logs(patron)]
    return (sum(w for w, _ in ms) / len(ms), sum(c for _, c in ms) / len(ms), len(ms))


datos = []
for rotulo, patron40, patron64 in ESCENARIOS:
    t40, c40, n40 = celda(patron40)
    t64, c64, n64 = celda(patron64)
    datos.append(dict(rotulo=rotulo, t40=t40, c40=c40, n40=n40, t64=t64, c64=c64, n64=n64,
                      d_t=100 * (t64 / t40 - 1), d_c=100 * (c64 / c40 - 1)))
    print(f"{rotulo.splitlines()[0]:32s}")
    print(f"   40 procesos: {t40:7.1f} s  {c40:6.2f} núcleos·hora  (n={n40})")
    print(f"   64 procesos: {t64:7.1f} s  {c64:6.2f} núcleos·hora  (n={n64})")
    print(f"   -> tiempo {datos[-1]['d_t']:+.1f} %   recursos {datos[-1]['d_c']:+.1f} %")

# --- panel superior: de dónde sale el empate --------------------------------------------
fig, (ax_p, ax_b) = plt.subplots(
    2, 1, figsize=(9.0, 8.2), gridspec_kw=dict(height_ratios=[1.0, 1.15], hspace=0.55))

for d0, d1, color, etiqueta in FASES:
    ax_p.axvspan(d0, d1, color=color, zorder=0)
    ax_p.text((d0 + d1) / 2, 0.985, etiqueta, transform=ax_p.get_xaxis_transform(),
              ha="center", va="top", fontsize=8.5, color=TINTA_2, linespacing=1.25)

for patron, color, etiqueta in ((ESCENARIOS[0][1], VERDE, "Destino 40 procesos"),
                                (ESCENARIOS[0][2], MORADO, "Destino 64 procesos")):
    dias, coste = coste_por_dia(logs(patron)[0])
    ax_p.plot(dias, coste, color=color, linewidth=1.5, label=etiqueta, zorder=3)

for dia, color, texto, lado in ((40, AZUL, "se pide la\nexpansión temprana", "right"),
                                (78, TINTA, "se pide la\nexpansión tardía", "left")):
    ax_p.axvline(dia, color=color, linestyle=":", linewidth=1.8, zorder=4)
    ax_p.annotate(texto, xy=(dia, 0.62), xycoords=ax_p.get_xaxis_transform(),
                  xytext=(-7 if lado == "right" else 8, 0), textcoords="offset points",
                  ha=lado, va="center", fontsize=9, color=color, linespacing=1.3)

ax_p.set_xlim(0, 130)
ax_p.set_ylim(0, 20)
ax_p.set_yticks([0, 5, 10, 15, 20])
ax_p.set_xlabel("Día simulado", fontsize=10)
ax_p.set_ylabel("Tiempo por volcado (s)", fontsize=10)
ax_p.grid(True, axis="y", linestyle="--", alpha=0.35, zorder=1)
ax_p.set_axisbelow(True)
for lado in ("top", "right"):
    ax_p.spines[lado].set_visible(False)
ax_p.legend(loc="center right", bbox_to_anchor=(1.0, 0.70), fontsize=9, frameon=False)
ax_p.set_title("Lo que cuesta avanzar la simulación, y cuándo entra cada expansión",
               fontsize=11.5, fontweight="bold", pad=8)

# --- panel inferior: la medida ----------------------------------------------------------
ancho = 0.3
xs = [0, 1]
barras_t = ax_b.bar([x - ancho / 2 for x in xs], [d["d_t"] for d in datos], ancho,
                    color=AZUL, label="Tiempo de ejecución", zorder=3)
barras_c = ax_b.bar([x + ancho / 2 for x in xs], [d["d_c"] for d in datos], ancho,
                    color=NARANJA, label="Recursos de aplicación", zorder=3)

# la banda de ruido: dentro de ella una diferencia no es un resultado
ax_b.axhspan(-RUIDO, RUIDO, color=TINTA_3, alpha=0.28, zorder=1)
ax_b.axhline(0, color=TINTA, linewidth=1.1, zorder=4)
ax_b.text(1.60, 0, "  ruido de medida\n  (±2 %)", ha="left", va="center",
          fontsize=9, color=TINTA_2, linespacing=1.35)

for barras, clave in ((barras_t, "d_t"), (barras_c, "d_c")):
    for barra, d in zip(barras, datos):
        v = d[clave]
        ax_b.annotate(f"{v:+.1f} %".replace(".", ","),
                      xy=(barra.get_x() + barra.get_width() / 2, v),
                      xytext=(0, 6 if v >= 0 else -14), textcoords="offset points",
                      ha="center", fontsize=11, fontweight="bold",
                      color=AZUL if clave == "d_t" else NARANJA)

ax_b.annotate("no se mueve", xy=(-0.21, -1.4), xytext=(-0.50, -16.0),
              fontsize=9.5, color=TINTA_2, ha="left",
              arrowprops=dict(arrowstyle="->", color=TINTA_2, linewidth=1.0,
                              connectionstyle="arc3,rad=0.15"))

ax_b.set_xticks(xs)
ax_b.set_xticklabels([d["rotulo"] for d in datos], fontsize=10.5, linespacing=1.4)
ax_b.set_ylabel("Variación al subir el destino\nde 40 a 64 procesos (%)",
                fontsize=10.5, linespacing=1.4)
ax_b.set_ylim(-19, max(d["d_c"] for d in datos) + 7)
ax_b.set_xlim(-0.55, 2.05)
ax_b.grid(True, axis="y", linestyle="--", alpha=0.4, zorder=0)
ax_b.set_axisbelow(True)
for lado in ("top", "right"):
    ax_b.spines[lado].set_visible(False)
ax_b.legend(loc="lower center", bbox_to_anchor=(0.5, 1.02), ncol=2,
            frameon=False, fontsize=10)

fig.suptitle("Veinticuatro procesos de más compran cosas distintas\n"
             "según cuánta simulación cara quede por delante cuando llegan",
             fontsize=13, fontweight="bold", y=0.985)
fig.tight_layout(rect=[0, 0, 1, 0.93])

SALIDA.mkdir(exist_ok=True)
out = SALIDA / "ce3_frontera_destino.png"
fig.savefig(out, dpi=150)
plt.close(fig)
print("escrito", out)
