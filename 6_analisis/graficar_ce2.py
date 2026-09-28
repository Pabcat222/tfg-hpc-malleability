#!/usr/bin/env python3
"""Figura y tablas de CE2 (§5.5.3 de la memoria): despliegue del almacenamiento.

Reproduce el barrido del número de servidores sobre un solo nodo y dibuja la
disociación que es el resultado central del caso de estudio: el tiempo de
entrada/salida ordena con el número de servidores sin excepción, mientras que el
tiempo total apenas se mueve. De ahí que la figura tenga dos filas con el mismo
eje de abscisas ---una para cada observable--- y no una sola con dos escalas.

Las cifras salen del lote de repeticiones del 13-ago-2026, que mide dos veces
cada celda dentro de un mismo despliegue y junto a su ejecución de referencia, de
modo que ninguna comparación mezcla despliegues. La lógica de extracción es la
misma de graficar_ce1.py: punto de medida común en la iteración 185760, los dos
formatos de línea IOPerf, RTIME para el cómputo y el resto por diferencia.

Uso:  python3 graficar_ce2.py [directorio_de_salida]
"""

import re
import sys
import glob
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

ITER_COMUN = 185760

BASE = Path(__file__).resolve().parent
GRA = BASE / "estaticos/poblacion_gra"
LOTE = "lote_ce2_n2_13ago"
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "graficas_ce2"

# Misma paleta que graficar_ce1.py, para que las dos figuras de la sección se
# lean como una sola serie.
AZUL = "#2a78d6"
NARANJA = "#eb6834"
AQUA = "#1baf7a"
TINTA = "#0b0b0b"
TINTA_2 = "#52514e"
TINTA_3 = "#8a8981"
SUPERFICIE = "#ffffff"

# Barrido de un solo nodo. Cada celda son sus dos repeticiones del lote.
BARRIDO = {
    8: [("NFS", "ce1_8p_nfs"),
        ("2", "ce2_8p_x2"),
        ("4", "ce2_8p_x4"),
        ("8", "ce2_8p_x8"),
        ("coloc.", "ce2_8p_coloc")],
    16: [("NFS", "ce1_16p_nfs"),
         ("2", "ce2_16p_x2"),
         ("4", "ce2_16p_x4"),
         ("8", "ce2_16p_x8"),
         ("16", "ce2_16p_x16"),
         ("coloc.", "ce2_16p_coloc")],
}


# Topologías multinodo, todas con dieciséis procesos de cómputo y una sola
# ejecución por celda. La referencia es la mejor topología de un solo nodo.
P16 = "despues_parche_xpn/16_procesos"
MULTINODO = {
    "referencia": f"{P16}/16_nodos_colocalizado",
    "Todos en una máquina": [
        ("2", f"{P16}/multinodo/16app_2xpn"),
        ("4", f"{P16}/multinodo/16app_4xpn"),
        ("8", f"{P16}/multinodo/16app_8xpn"),
        ("16", f"{P16}/multinodo/16app_16xpn"),
    ],
    "Repartidos entre las dos": [
        ("2", f"{P16}/multinodo_distribuido/16app_2xpn"),
        ("4", f"{P16}/multinodo_distribuido/16app_4xpn"),
        ("8", f"{P16}/multinodo_distribuido/16app_8xpn"),
        ("16", f"{P16}/multinodo_distribuido/16app_16xpn"),
        ("coloc.", f"{P16}/multinodo_distribuido/16app_colocalizado"),
    ],
}

MORADO = "#8172b3"


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


def celda(subdirs, admite_flops0=False):
    """Media de las ejecuciones válidas de una celda, con su rango.

    `admite_flops0` sólo se activa para la familia multinodo. Sus nueve logs
    declaran FLOPs 0 en las 130 muestras del monitor, de modo que el balanceador
    se quedó sin entrada en todos ellos por igual. Eso hace que las comparaciones
    DENTRO de la familia sigan siendo válidas ---comparten el defecto--- pero
    invalida la comparación contra la referencia de un solo nodo, que sí tiene
    FLOPs. Ver la nota de la sección de multinodo.
    """
    medidas = []
    for sub in subdirs:
        for ruta in sorted(glob.glob(str(GRA / sub / "*.log"))):
            if "errores" in ruta:
                continue
            r = extrae(ruta)
            if r["t"] == 0 or r["rtime"] is None:
                continue
            if r["n_io"] < 1300 or (r["flops0"] > 0 and not admite_flops0):
                print(f"  descartada {Path(ruta).name}: "
                      f"IOPerf={r['n_io']} FLOPs0={r['flops0']}")
                continue
            medidas.append(r)
    if not medidas:
        raise SystemExit(f"sin ejecuciones válidas en {subdirs}")
    n = len(medidas)
    med = lambda k: sum(m[k] for m in medidas) / n
    t, io, rtime = med("t"), med("io"), med("rtime")
    tiempos = [m["t"] for m in medidas]
    ios = [m["io"] for m in medidas]
    return dict(n=n, t=t, io=io, rtime=rtime, resto=t - io - rtime,
                t_min=min(tiempos), t_max=max(tiempos),
                io_min=min(ios), io_max=max(ios), tiempos=tiempos)


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


def posiciones(n):
    """Abscisas de las barras, con un hueco tras la referencia NFS.

    NFS no es un escalón del barrido, sino aquello contra lo que se compara: el
    hueco lo separa visualmente de las configuraciones de XPN sin sacarlo del
    panel, que es lo que permite leer las cuatro partidas contra las suyas.
    """
    return [0.0] + [1.9 + 1.25 * i for i in range(n - 1)]


def panel(ax, datos, tope, ancho=0.62):
    """Descomposición apilada de una serie del barrido.

    Mismo reparto que la figura de CE1: cómputo, entrada/salida y coordinación,
    esta última por diferencia. La barra entera es el tiempo total, de modo que
    la figura explica a la vez la columna del total y las tres que la componen.
    """
    x = posiciones(len(datos))
    for xi, (_, d) in zip(x, datos):
        base = 0.0
        for valor, color in ((d["rtime"], AZUL), (d["io"], NARANJA),
                             (d["resto"], AQUA)):
            # Separación de 2 px entre segmentos: el hueco deja ver el fondo y
            # evita que dos rellenos contiguos se lean como uno solo.
            ax.bar(xi, valor, width=ancho, bottom=base, color=color,
                   linewidth=1.4, edgecolor=SUPERFICIE, zorder=3)
            # Un segmento demasiado fino no admite el número dentro: se saca al
            # hueco de la derecha, con un guion que lo une a su segmento para
            # que no pueda atribuirse a la barra vecina.
            # 0,07 del alto del eje es aproximadamente lo que ocupa el número:
            # por debajo de eso el texto desborda su propio segmento.
            if valor / tope < 0.07:
                ax.annotate(coma(valor, 0), (xi + ancho / 2, base + valor / 2),
                            xytext=(7, 0), textcoords="offset points",
                            ha="left", va="center", fontsize=8,
                            color=TINTA_2, zorder=6,
                            arrowprops=dict(arrowstyle="-", lw=0.6,
                                            color=TINTA_3, shrinkA=0,
                                            shrinkB=1))
            else:
                ax.annotate(coma(valor, 0), (xi, base + valor / 2),
                            ha="center", va="center", fontsize=8.5,
                            color="#ffffff", zorder=5)
            base += valor
        # El rango de las dos ejecuciones, que es lo que decide si una
        # diferencia es afirmable, sobre el remate de la barra.
        ax.vlines(xi, d["t_min"], d["t_max"], color=TINTA_2, lw=1.0, zorder=6)
        ax.annotate(coma(d["t"], 0), (xi, d["t_max"]), xytext=(0, 4),
                    textcoords="offset points", ha="center", fontsize=8,
                    color=TINTA, zorder=5)

    ax.set_xticks(x)
    ax.set_xticklabels([e for e, _ in datos], fontsize=8.5, color=TINTA_2)
    ax.set_xlim(-0.8, x[-1] + 0.8)
    ax.set_ylim(0, tope)
    ax.grid(axis="y", color=TINTA_3, alpha=0.25, lw=0.6)
    ax.set_axisbelow(True)
    estilo(ax)


def figura(datos):
    # Un panel por fila, y no dos en la misma: once barras repartidas a lo ancho
    # de la caja de texto dejan la barra tan estrecha que los números de cuatro
    # cifras no caben dentro al reducir la figura para la memoria.
    fig, axes = plt.subplots(2, 1, figsize=(7.2, 6.6), dpi=200, sharey=True,
                             gridspec_kw=dict(hspace=0.42))

    tope = max(d["t_max"] for panel_ in datos.values()
               for _, d in panel_) * 1.10

    for ax, procs in zip(axes, sorted(datos)):
        panel(ax, datos[procs], tope)
        ax.set_title(f"{procs} procesos de cómputo", fontsize=10,
                     color=TINTA_2, pad=8)
        ax.set_xlabel("Servidores de almacenamiento (n = 2 por celda)",
                      fontsize=9.5, color=TINTA_2)
        ax.set_ylabel("Tiempo hasta el punto\nde medida común (s)",
                      fontsize=9.5, color=TINTA)

    proxies = [Patch(color=AZUL, label="Cómputo"),
               Patch(color=NARANJA, label="Entrada/salida"),
               Patch(color=AQUA, label="Coordinación")]
    leg = fig.legend(handles=proxies, frameon=False, fontsize=9, ncols=3,
                     loc="upper left", bbox_to_anchor=(0.09, 1.02),
                     borderaxespad=0)
    for txt in leg.get_texts():
        txt.set_color(TINTA_2)

    salida = SALIDA / "ce2_servidores.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)
    print(f"\n  {salida}")


def figura_multinodo(ref, series):
    """Las dos disposiciones posibles entre dos máquinas.

    El argumento de la sección es que el cuello no está en el almacenamiento
    sino en el enlace, y eso se ve en la forma de las curvas: la disposición
    anclada es plana ---añadir servidores no la mejora--- mientras que la
    distribuida vuelve a ordenar con el número de servidores.
    """
    fig, axes = plt.subplots(1, 2, figsize=(7.6, 3.5), dpi=200,
                             gridspec_kw=dict(wspace=0.28))
    colores = {"Todos en una máquina": MORADO,
               "Repartidos entre las dos": NARANJA}

    for ax, clave, titulo in ((axes[0], "t", "Tiempo total (s)"),
                              (axes[1], "io", "Tiempo de entrada/salida (s)")):
        # Sin la referencia de un solo nodo: se midió con el balanceador
        # alimentado y estas nueve celdas no, de modo que dibujarla al lado
        # invitaría a leer una diferencia que mezcla dos causas.
        tope = max(d[clave] for celdas in series.values()
                   for _, d in celdas) * 1.22
        ancho_x = max(len(c) for c in series.values())
        for nombre, celdas in series.items():
            x = list(range(len(celdas)))
            v = [d[clave] for _, d in celdas]
            ax.plot(x, v, "o-", color=colores[nombre], lw=1.8, markersize=5,
                    zorder=4, label=nombre)
            for xi, vi in zip(x, v):
                ax.annotate(coma(vi, 0), (xi, vi), xytext=(0, 8),
                            textcoords="offset points", ha="center",
                            fontsize=8, color=TINTA, zorder=5)
        ax.set_xticks(range(ancho_x))
        ax.set_xticklabels([e for e, _ in series["Repartidos entre las dos"]],
                           fontsize=9, color=TINTA_2)
        ax.set_xlim(-0.6, ancho_x - 0.4)
        ax.set_ylim(0, tope)
        ax.set_ylabel(titulo, fontsize=9.5, color=TINTA)
        ax.set_xlabel("Servidores de almacenamiento", fontsize=9.5, color=TINTA_2)
        ax.grid(axis="y", color=TINTA_3, alpha=0.25, lw=0.6)
        ax.set_axisbelow(True)
        estilo(ax)

    proxies = [Line2D([], [], color=MORADO, marker="o", lw=1.8, markersize=5,
                      label="Todos los servidores en una máquina"),
               Line2D([], [], color=NARANJA, marker="o", lw=1.8, markersize=5,
                      label="Servidores repartidos entre las dos máquinas")]
    leg = fig.legend(handles=proxies, frameon=False, fontsize=8.5, ncols=2,
                     loc="upper left", bbox_to_anchor=(0.06, 1.06),
                     borderaxespad=0)
    for txt in leg.get_texts():
        txt.set_color(TINTA_2)

    salida = SALIDA / "ce2_multinodo.png"
    fig.savefig(salida, facecolor=SUPERFICIE, bbox_inches="tight")
    plt.close(fig)
    print(f"  {salida}")


if __name__ == "__main__":
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Iteración común: {ITER_COMUN}")
    datos = {p: [(etiq, celda([f"{LOTE}/{sub}_r1", f"{LOTE}/{sub}_r2"]))
                 for etiq, sub in celdas]
             for p, celdas in BARRIDO.items()}

    for procs in sorted(datos):
        print(f"\n{procs} procesos  (tiempo | cómputo | E/S | coord.)")
        base = datos[procs][0][1]
        for etiq, d in datos[procs]:
            print(f"  {etiq:8s} n={d['n']}  {coma(d['t']):>8s} "
                  f"[{coma(d['t_min'])}--{coma(d['t_max'])}]  "
                  f"{coma(d['rtime']):>8s}  {coma(d['io']):>7s}  "
                  f"{coma(d['resto']):>8s}   "
                  f"vs NFS {(d['t'] - base['t']) / base['t'] * 100:+.1f} % "
                  f"/ E/S {(d['io'] - base['io']) / base['io'] * 100:+.1f} %")
        barrido = [d for _, d in datos[procs][1:]]
        t = [d["t"] for d in barrido]
        io = [d["io"] for d in barrido]
        print(f"  recorrido del barrido: tiempo {(max(t) - min(t)) / max(t) * 100:.1f} %"
              f"   E/S {(max(io) - min(io)) / max(io) * 100:.1f} %")
    figura(datos)

    ref = celda([MULTINODO["referencia"]])
    series = {nombre: [(etiq, celda([sub], admite_flops0=True))
                       for etiq, sub in celdas]
              for nombre, celdas in MULTINODO.items() if nombre != "referencia"}
    print("\nTopologías multinodo, 16 procesos (n=1 por celda, FLOPs 0 en todas)")
    print(f"  un solo nodo, colocalizado   t={coma(ref['t'])}  E/S={coma(ref['io'])}"
          f"   [con FLOPs: no comparable celda a celda]")
    for nombre, celdas in series.items():
        print(f"  {nombre}:")
        for etiq, d in celdas:
            print(f"    {etiq:8s} t={coma(d['t']):>8s}  E/S={coma(d['io']):>7s}")
    # La comparación limpia es ésta: las dos disposiciones entre sí, que
    # comparten campaña y comparten el defecto de FLOPs.
    anc = [d for _, d in series["Todos en una máquina"]]
    dis = [d for _, d in series["Repartidos entre las dos"]]
    peor_dis = min(d["t"] for d in dis)
    print(f"\n  anclada vs distribuida (misma familia, comparación válida):")
    print(f"    mejor anclada {coma(min(d['t'] for d in anc))} s  vs  "
          f"mejor distribuida {coma(peor_dis)} s  ->  "
          f"{(min(d['t'] for d in anc) - peor_dis) / peor_dis * 100:+.1f} %")
    print(f"    recorrido de la anclada: tiempo "
          f"{(max(d['t'] for d in anc) - min(d['t'] for d in anc)) / max(d['t'] for d in anc) * 100:.1f} %"
          f"   E/S {(max(d['io'] for d in anc) - min(d['io'] for d in anc)) / max(d['io'] for d in anc) * 100:.1f} %")
    figura_multinodo(ref, series)
