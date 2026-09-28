#!/bin/bash
# =============================================================================
# sample_cpu_host.sh  (v3 — tiempo de cómputo)
#
# Muestrea cada $INTERVAL s, desde el HOST y en paralelo al experimento:
#   - cpu_stats.tsv      : %CPU instantáneo por contenedor (referencia)
#   - io_stats.tsv       : BlockIO read/write por contenedor
#   - cpu_time_stats.tsv : tiempo de CPU ACUMULADO por contenedor  <-- NUEVO
#
# Saber que todos los nodos usan el mismo %CPU ya no aporta (era el bug de
# balanceo, ya corregido); lo útil es cuánta CPU consume realmente cada proceso
# = fracción de cómputo, frente al tiempo de espera (E/S + sincronización MPI).
#
# Dos fuentes de tiempo de CPU acumulado por contenedor:
#   container_cpu_s : cgroup cpu.stat usage_usec -> TODO el contenedor
#                     (exclusivo = solo epiGraph; colocalizado = epiGraph + XPN,
#                      la diferencia mide el overhead de CPU de XPN)
#   epigraph_cpu_s  : utime+stime de los procesos epiGraph en /proc/PID/stat
#                     -> aísla el cómputo de la app. Es lo que marca htop.
#
# Funciona igual en el PORTÁTIL y en TUCÁN: en ambos los contenedores están en
# la misma máquina, así que 'docker stats'/'docker exec' los ven todos. La ruta
# de salida se deriva de la ubicación del script (no hay que tocar /home/...).
#
# Uso:   bash sample_cpu_host.sh [intervalo_seg]   (portátil ~3 s; Tucán ~5-8 s)
# Para en cuanto desaparece /tmp/epigraph_current_phase e imprime el resumen.
# =============================================================================

INTERVAL="${1:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/install-src/EpiGraphFlexMPI-XPN/mis_logs"
OUTPUT_CPU="$OUTPUT_DIR/cpu_stats.tsv"
OUTPUT_IO="$OUTPUT_DIR/io_stats.tsv"
OUTPUT_CPUTIME="$OUTPUT_DIR/cpu_time_stats.tsv"
mkdir -p "$OUTPUT_DIR"
echo -e "timestamp\tphase\thostname\tcpu_percent" > "$OUTPUT_CPU"
echo -e "timestamp\tphase\thostname\tio_read_bytes\tio_write_bytes" > "$OUTPUT_IO"
echo -e "timestamp\tphase\thostname\tcontainer_cpu_s\tepigraph_cpu_s" > "$OUTPUT_CPUTIME"

CONTAINER_MAIN=$(docker ps --format "{{.Names}}" | grep xpn | head -1)
if [ -z "$CONTAINER_MAIN" ]; then
    echo "No hay contenedores xpn corriendo. Aborto."
    exit 1
fi
echo "Monitorizando desde: $CONTAINER_MAIN  (intervalo ${INTERVAL}s)  ->  $OUTPUT_DIR"

CLK_TCK=$(docker exec "$CONTAINER_MAIN" getconf CLK_TCK 2>/dev/null)
[[ "$CLK_TCK" =~ ^[0-9]+$ ]] || CLK_TCK=100

# Snippet ejecutado dentro de cada contenedor (entre comillas simples = literal):
# imprime "usec ticks" = cgroup usage_usec + suma utime/stime de epiGraph.
SNIP='u=$(awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null); [ -z "$u" ] && u=$(awk "{print int(\$1/1000)}" /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null); t=0; for p in $(pgrep -x epiGraph 2>/dev/null); do v=$(awk "{print \$14+\$15}" /proc/$p/stat 2>/dev/null); [ -n "$v" ] && t=$((t+v)); done; echo "${u:-0} ${t:-0}"'

to_bytes() {
    local val=$1 unit=$2
    case "${unit,,}" in
        k) echo "$val * 1024"          | bc 2>/dev/null || echo 0 ;;
        m) echo "$val * 1048576"       | bc 2>/dev/null || echo 0 ;;
        g) echo "$val * 1073741824"    | bc 2>/dev/null || echo 0 ;;
        t) echo "$val * 1099511627776" | bc 2>/dev/null || echo 0 ;;
        *) printf "%.0f" "$val" 2>/dev/null || echo 0 ;;
    esac
}

while true; do
    TS=$(date +%s)
    PHASE=$(docker exec "$CONTAINER_MAIN" cat /tmp/epigraph_current_phase 2>/dev/null)
    [ -z "$PHASE" ] && break

    CONTAINERS=$(docker ps --format "{{.Names}}" | grep xpn | tr '\n' ' ')

    # --- %CPU + BlockIO (una sola llamada docker stats) ---
    docker stats --no-stream \
        --format "{{.Name}}\t{{.CPUPerc}}\t{{.BlockIO}}" \
        $CONTAINERS 2>/dev/null | while IFS=$'\t' read -r NAME CPU_RAW IO_LINE; do
        CPU="${CPU_RAW//%/}"
        [ -n "$CPU" ] && echo -e "${TS}\t${PHASE}\t${NAME}\t${CPU}" >> "$OUTPUT_CPU"
        if [[ "$IO_LINE" =~ ^([0-9.]+)([kKMGT]?)B[[:space:]]*/[[:space:]]*([0-9.]+)([kKMGT]?)B$ ]]; then
            RI=$(to_bytes "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
            WI=$(to_bytes "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
            echo -e "${TS}\t${PHASE}\t${NAME}\t${RI%.*}\t${WI%.*}" >> "$OUTPUT_IO"
        fi
    done

    # --- Tiempo de CPU acumulado (un exec por contenedor, en paralelo) ---
    for NAME in $CONTAINERS; do
        (
            OUT=$(docker exec "$NAME" sh -c "$SNIP" 2>/dev/null)
            USEC=${OUT% *}; TICKS=${OUT#* }
            [[ "$USEC"  =~ ^[0-9]+$ ]] || USEC=0
            [[ "$TICKS" =~ ^[0-9]+$ ]] || TICKS=0
            CONT_S=$(awk "BEGIN{printf \"%.3f\", $USEC/1000000}")
            EPI_S=$(awk "BEGIN{printf \"%.3f\", $TICKS/$CLK_TCK}")
            echo -e "${TS}\t${PHASE}\t${NAME}\t${CONT_S}\t${EPI_S}" >> "$OUTPUT_CPUTIME"
        ) &
    done
    wait

    sleep "$INTERVAL"
done

# =============================================================================
# RESUMEN FINAL — tiempo de cómputo durante el experimento
# =============================================================================
echo ""
echo "=========================================="
echo "Resumen tiempo de cómputo (cpu_time_stats.tsv)"
echo "=========================================="
awk -F'\t' '
    NR==1 { next }
    {
        host=$3; ts=$1; cont=$4; epi=$5
        if (!(host in first_ts)) { first_ts[host]=ts; first_c[host]=cont; first_e[host]=epi }
        last_ts[host]=ts; last_c[host]=cont; last_e[host]=epi
    }
    END {
        printf "%-28s %10s %12s %12s %8s\n", "contenedor", "wall(s)", "cpu_cont(s)", "cpu_epi(s)", "uso(cores)"
        sum_epi=0; sum_wall=0; n=0
        for (h in first_ts) {
            wall = last_ts[h]-first_ts[h]
            dc   = last_c[h]-first_c[h]
            de   = last_e[h]-first_e[h]
            use  = (wall>0)? de/wall : 0
            printf "%-28s %10.0f %12.1f %12.1f %8.3f\n", h, wall, dc, de, use
            if (de>0) { sum_epi+=de; sum_wall+=wall; n++ }
        }
        if (n>0) {
            avg_wall = sum_wall/n
            printf "\nFraccion de computo global (epiGraph): %.1f%%  (%.3f cores/proc de media, n=%d)\n", \
                   100*sum_epi/(avg_wall*n), sum_epi/(avg_wall*n), n
            print  "  -> el resto (100% - eso) es espera: E/S + sincronizacion MPI"
        }
    }
' "$OUTPUT_CPUTIME"
echo "=========================================="
