#!/usr/bin/env python3
"""Figura de §5.5.4 (CE3): el día en que se pide la expansión decide lo que devuelve.

Sustituye a graficar_ce3_frontera.py, que comparaba una sola pareja de destinos. Aquí se
usan TODAS las ejecuciones maleables del archivo que llegan a la iteración común, agrupadas
por campaña, porque juntas dicen algo que la pareja sola no decía: el retorno de ampliar no
depende del tamaño del destino sino de cuánta simulación cara queda por delante cuando los
procesos nuevos entran a trabajar.

Dos paneles, en el orden del argumento:

  A (arriba) --- el contexto que lo explica: lo que cuesta avanzar un dia simulado, con las
  cuatro fases de la escena sombreadas y marcados los cuatro dias en que las campanas piden
  la expansion. Junto a cada marca, la fraccion de la ejecucion ya consumida cuando el
  destino queda operativo. Se ve que el dia 78 llega con la onda cara ya pagada.

  B (abajo) --- lo que tarda la ejecucion completa segun el dia en que se solicita la
  expansion, con una serie por destino. Desde el lote CE3-B el dia 78 esta medido sobre la
  misma topologia de ocho servidores que los dias tempranos, asi que entra en este eje: se
  ve que las series suben y se juntan, es decir, que cuanto mas tarde se pide menos importa
  a cuanto se amplie.

Las tres ejecuciones del dia 78 con DOS servidores se siguen midiendo, pero solo se
imprimen por consola: sirven para aislar el efecto del almacenamiento, no para este eje.

Todas las medidas se toman en la iteración común 185760 e integran el NumRanks realmente
activo sobre el reloj, igual que el resto de §5.5.

Uso:  python3 graficar_ce3_momento_magnitud.py [directorio_de_salida]
"""

import re
import sys
import glob
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

ITER_COMUN = 185760
MINDAY = 1440          # iteraciones por día simulado

BASE = Path(__file__).resolve().parent
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce3"

# Rampa secuencial: el destino de la expansión es una magnitud ordenada, no una identidad,
# así que se codifica con un solo tono de claro a oscuro. Validada para daltonismo
# (ΔE OKLab ≥ 14 en los tres tipos entre pasos contiguos).
DESTINO = {32: "#a8cfe8", 40: "#5ba3d0", 48: "#2a6faf", 64: "#123f6b"}
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"
ACENTO = "#c2410c"

FASES = [
    (0,   42,  "#e8ebe4", "Fase inicial\nbarata"),
    (42,  78,  "#fbe0d4", "1.ª onda\n(cara)"),
    (78,  84,  "#dbe8f7", "Valle"),
    (84,  130, "#fbe0d4", "Meseta final\n(cara)"),
]

RE_LINEA = re.compile(r"IOTimeStamp\s+([\d.]+)\s+NumRanks:\s+(\d+).*?IOPerf\s+(\d+)")

# Campaña de co-maleabilidad: barrido completo de día × destino. La celda de 40 procesos
# el día 40 es la que tiene seis repeticiones.
TEMPRANA = [
    # (día pedido, destino, patrones de los logs)
    # El lote CE3-B (17-ago) sube a n>=2 las celdas que estaban a una sola ejecución y
    # añade el día 78 sobre esta misma topología de ocho servidores, que es lo que permite
    # dibujarlo en el mismo eje que los días tempranos.
    (30, 32, ["maleabilidad/5_comaleabilidad/8_32_d30_G30/001_comall*.log",
              "lote_ce3b_17ago/ce3b_d30p32_r*/001_*.log"]),
    (40, 32, ["maleabilidad/5_comaleabilidad/8_32_d40_A/001_comall*.log"]),
    (50, 32, ["maleabilidad/5_comaleabilidad/8_32_d50_G50/001_comall*.log",
              "lote_ce3b_17ago/ce3b_d50p32_r*/001_*.log"]),
    (30, 40, ["maleabilidad/5_comaleabilidad/8_40_d30_G30p40/001_comall*.log",
              "lote_ce3_16ago/ce3_d30_r*/001_*.log"]),
    (40, 40, ["maleabilidad/5_comaleabilidad/8_40_d40_C40/001_comall_C40_8_40*.log"]),
    (50, 40, ["maleabilidad/5_comaleabilidad/8_40_d50_G50p40/001_comall*.log",
              "lote_ce3_16ago/ce3_d50_r*/001_*.log"]),
    (40, 64, ["maleabilidad/5_comaleabilidad/8_64_d40_C/001_comall*.log",
              "lote_ce3b_17ago/ce3b_d40p64_r*/001_*.log"]),
    (78, 40, ["lote_ce3b_17ago/ce3b_d78p40_r*/001_*.log"]),
    (78, 48, ["lote_ce3b_17ago/ce3b_d78p48_r*/001_*.log"]),
    (78, 64, ["lote_ce3b_17ago/ce3b_d78p64_r*/001_*.log"]),
]

# Campaña de waypoints, con DOS servidores en lugar de ocho: mismo día y mismos tres
# destinos. Ya no entra en el panel B, porque el día 78 se mide ahora sobre la topología
# de arriba; se conserva para imprimir el efecto del almacenamiento. Del destino 48 hay
# dos ejecuciones independientes (13 y 27 de julio); wp_run1_colgado.log es copia de una
# de ellas y se excluye para no contarla dos veces.
DOS_SERV = [
    (78, 40, ["maleabilidad/4_waypoints/8_40_d78_run1b/001_xpn_mall*.log"]),
    (78, 48, ["maleabilidad/4_waypoints/8_48_d78_run1/001_xpn_mall*.log",
              "maleabilidad/4_waypoints/8_48_d78_run1/run1_d13partial.log"]),
    (78, 64, ["maleabilidad/4_waypoints/8_64_d78_run2/001_xpn_mall*.log"]),
]

# El panel A dibuja la escena tal como la recorre una ejecución que todavía no ha ampliado:
# la de destino 40 pedida el día 78 va con ocho procesos durante toda la primera onda.
LOG_ESCENA = "lote_ce3b_17ago/ce3b_d78p40_r1/001_*.log"


def serie(path):
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
    """(duración, núcleos·hora de aplicación, fracción del tiempo ya consumida cuando el
    destino queda operativo)."""
    ts, ranks, _ = serie(path)
    consumo, t_prev, r_prev = 0.0, 0.0, ranks[0]
    for t, r in zip(ts, ranks):
        consumo += r_prev * (t - t_prev)
        t_prev, r_prev = t, r
    pico = max(ranks)
    t_pico = next(t for t, r in zip(ts, ranks) if r == pico)
    return ts[-1], consumo / 3600.0, 100 * t_pico / ts[-1]


def coste_por_dia(path):
    ts, _, iters = serie(path)
    por_dia = {}
    t_prev = 0.0
    for t, i in zip(ts, iters):
        por_dia.setdefault((i - 1) // MINDAY, []).append(t - t_prev)
        t_prev = t
    dias = sorted(por_dia)
    return dias, [sum(por_dia[d]) / len(por_dia[d]) for d in dias]


def logs(patrones):
    if isinstance(patrones, str):
        patrones = [patrones]
    ps = []
    for patron in patrones:
        ps += [p for p in sorted(glob.glob(str(BASE / patron)))
               if not p.endswith("_errores.log")]
    if not ps:
        raise SystemExit(f"sin logs: {patrones}")
    return ps


def celda(patrones):
    ms = [medida(p) for p in logs(patrones)]
    n = len(ms)
    return dict(t=sum(m[0] for m in ms) / n, c=sum(m[1] for m in ms) / n,
                frac=sum(m[2] for m in ms) / n, n=n,
                tmin=min(m[0] for m in ms), tmax=max(m[0] for m in ms))


datos_t = [dict(dia=d, destino=k, **celda(p)) for d, k, p in TEMPRANA]
datos_w = [dict(dia=d, destino=k, **celda(p)) for d, k, p in DOS_SERV]

print("== ocho servidores de almacenamiento ==")
for d in datos_t:
    print(f"  día {d['dia']:2d} -> {d['destino']:2d} procesos   n={d['n']}  "
          f"{d['t']:7.1f} s  {d['c']:6.2f} núcleos·hora   "
          f"destino operativo con el {d['frac']:.0f} % consumido")
print("== dos servidores (campaña de waypoints) ==")
for d in datos_w:
    print(f"  día {d['dia']:2d} -> {d['destino']:2d} procesos   n={d['n']}  "
          f"{d['t']:7.1f} s  {d['c']:6.2f} núcleos·hora   "
          f"destino operativo con el {d['frac']:.0f} % consumido")

# --- figuras -----------------------------------------------------------------------------
# Desde el 3-sep-2026 los dos paneles se emiten como figuras INDEPENDIENTES, porque en la
# memoria cada uno se explica por separado. Se conserva la misma escala y los mismos
# colores que tenían dentro de la figura conjunta.

SALIDA.mkdir(exist_ok=True)


def guarda(fig, nombre):
    for ext in ("png", "pdf"):
        out = SALIDA / f"{nombre}.{ext}"
        fig.savefig(out, dpi=150)
        print("escrito", out)
    plt.close(fig)


# --- 1: la escena y los cuatro momentos en que se pide la expansión ----------------------
fig_a, ax_a = plt.subplots(figsize=(9.6, 4.8))

for d0, d1, color, etiqueta in FASES:
    ax_a.axvspan(d0, d1, color=color, zorder=0)
    ax_a.text((d0 + d1) / 2, 0.98, etiqueta, transform=ax_a.get_xaxis_transform(),
              ha="center", va="top", fontsize=8.5, color=TINTA_2, linespacing=1.25)

dias, coste = coste_por_dia(logs(LOG_ESCENA)[0])
dias, coste = zip(*[(d, c) for d, c in zip(dias, coste) if d <= 128])
ax_a.fill_between(dias, coste, color=ACENTO, alpha=0.16, zorder=2)
ax_a.plot(dias, coste, color=ACENTO, linewidth=1.6, zorder=3,
          label="Coste de un día simulado con ocho procesos")

frac = {(d["dia"], d["destino"]): d["frac"] for d in datos_t + datos_w}
# (día, celda de la que se toma la fracción, altura relativa, lado del rótulo)
MARCAS = [(30, 32, 0.24, "right"), (40, 40, 0.45, "right"),
          (50, 40, 0.66, "right"), (78, 40, 0.55, "left")]
for dia, destino, y, lado in MARCAS:
    pc = frac[(dia, destino)]
    ax_a.axvline(dia, color=TINTA, linestyle=":", linewidth=1.5, zorder=4)
    ax_a.annotate(f"día {dia}\n{pc:.0f} % ya consumido",
                  xy=(dia, y), xycoords=ax_a.get_xaxis_transform(),
                  xytext=(6 if lado == "left" else -6, 0), textcoords="offset points",
                  ha=lado, va="center", fontsize=8.5, color=TINTA, linespacing=1.35,
                  zorder=6,
                  bbox=dict(boxstyle="round,pad=0.22", facecolor="white", alpha=0.78,
                            edgecolor="none"))

ax_a.set_xlim(0, 129)
ax_a.set_ylim(0, 20)
ax_a.set_xlabel("Día simulado", fontsize=10)
ax_a.set_ylabel("Tiempo por volcado (s)", fontsize=10)
ax_a.grid(True, axis="y", linestyle="--", alpha=0.35, zorder=1)
ax_a.set_axisbelow(True)
for lado in ("top", "right"):
    ax_a.spines[lado].set_visible(False)
ax_a.set_title("Lo que cuesta un día simulado, y cuándo se pide cada expansión",
               fontsize=12, fontweight="bold", pad=10, loc="left")
fig_a.tight_layout()
guarda(fig_a, "ce3_momento_escena")

# --- 2: el tiempo de ejecución frente al día en que se pide la expansión -----------------
fig_b, ax_b = plt.subplots(figsize=(9.6, 4.6))

for destino in (32, 40, 48, 64):
    pts = sorted([d for d in datos_t if d["destino"] == destino], key=lambda d: d["dia"])
    # Entre el día 50 y el 78 no hay ninguna medida intermedia. Ese tramo se traza
    # discontinuo para que la línea no se lea como una interpolación medida.
    for a, b in zip(pts, pts[1:]):
        ax_b.plot([a["dia"], b["dia"]], [a["t"], b["t"]],
                  linestyle="--" if b["dia"] - a["dia"] > 15 else "-",
                  color=DESTINO[destino], linewidth=2.0, zorder=4)
    ax_b.plot([p["dia"] for p in pts], [p["t"] for p in pts], "o",
              color=DESTINO[destino], markersize=10,
              markeredgecolor=TINTA, markeredgewidth=0.9, zorder=5,
              label=f"{destino} procesos")

# la línea que hace visible el resultado: pedir 40 procesos el día 50 es más lento que
# pedir 32 diez o veinte días antes
ref = next(d for d in datos_t if d["dia"] == 50 and d["destino"] == 40)
ax_b.axhline(ref["t"], color=TINTA_2, linestyle="--", linewidth=1.1, zorder=2)
ax_b.annotate("40 procesos pedidos el día 50 tardan más\nque 32 pedidos el día 30 o el 40",
              xy=(26.6, ref["t"] + 55), fontsize=9, color=TINTA_2, linespacing=1.35,
              va="bottom", zorder=6)

ax_b.set_xlim(26, 82)
ax_b.set_xticks([30, 40, 50, 78])
ax_b.set_ylim(2820, 5120)
ax_b.set_xlabel("Día simulado en que se solicita la expansión", fontsize=10)
ax_b.set_ylabel("Tiempo de ejecución (s)", fontsize=10)
ax_b.grid(True, axis="y", linestyle="--", alpha=0.35, zorder=0)
ax_b.set_axisbelow(True)
for lado in ("top", "right"):
    ax_b.spines[lado].set_visible(False)
ax_b.set_title("Lo que tarda la ejecución según el día en que se amplía",
               fontsize=12, fontweight="bold", pad=10, loc="left")
ax_b.legend(loc="upper left", frameon=False, fontsize=9.5,
            title="Destino de la expansión", title_fontsize=9.5)
fig_b.tight_layout()
guarda(fig_b, "ce3_momento_tiempo")
