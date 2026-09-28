#!/bin/bash

# =============================================================================
# lanza_multinodo_waypoints.sh
# MALEABILIDAD MULTINODO POR CALENDARIO DE WAYPOINTS  (spawn nativo, SIN restart)
#
#   EpiGraph = compute-15-1 (contenedores app)  |  XPN = compute-15-3 (2 servidores, exclusivo)
#   Bypass real de XPN (LD_PRELOAD) + locality 0. La E/S viaja por la red overlay a los XPN.
#
#   Reproduce la estrategia de Paula (SARTECO 2025): SEGUIR LA CARGA DE CÓMPUTO con el número
#   de procesos, a NUESTRA escala. XPN fijo a 2 servidores (en multinodo la E/S está limitada
#   por la NIC entre nodos, no por el nº de servidores — verificado 2/4/8/16 xpn ~idénticos).
#
#   Curva de carga real (medida a 32p, s/día): baseline barato d0-42 · joroba Delta pico ~d54 ·
#   valle d78-82 · MESETA Ómicron sostenida d82-130 (coste dominante, no vuelve a bajar).
#
#   CONFIG POR CALENDARIO:  WAYPOINTS="día:procs día:procs ..."  (en orden de día).
#     El script arranca con N_A procesos y, al llegar a cada día, reconfigura a ese nº de procs:
#       - SUBIR  (spawn) : escalonado en lotes de <=BATCH_MAX hijos; tras cada lote LEE el
#                          NumRanks REAL del log y continúa desde ahí (rellena spawns parciales)
#                          hasta alcanzar el objetivo -> evita el crash de shrink por spawn parcial.
#       - BAJAR  (shrink): un solo comando dirigido al PICO REAL (hosts [target .. real-1]).
#
#   Ejemplos:
#     Run 1 (foco Ómicron 48): N_A=8 N_MAX=48 WAYPOINTS="78:48"                RUN_TAG=run1_omicron48
#     Run 2 (foco Ómicron 64): N_A=8 N_MAX=64 WAYPOINTS="78:64"                RUN_TAG=run2_omicron64
#     Run 3 (load-following)  : N_A=8 N_MAX=64 WAYPOINTS="42:32 64:16 80:64"   RUN_TAG=run3_bidir
#
# PRERREQUISITOS (dentro del contenedor app #1, swarm 15-1+15-3, >=N_MAX app + 2 xpn):
#   ./xpn_docker.sh start ${N_MAX} 2     (machines_mpi = N_MAX+2, ORDENADO app->xpn)
#   deps (libglpk/gsl/papi + sshpass) en TODOS los contenedores — RUNBOOK
#   FlexMPI + EpiGraph recompilados con el fix (cPathPrefix) y NUMBER_OPTIONS=256
#   Lanzar SIEMPRE desacoplado:
#     docker exec -d --user lab <CID> setsid bash -lc \
#       'N_A=8 N_MAX=48 WAYPOINTS="78:48" RUN_TAG=run1_omicron48 \
#        bash /shared/install-src/lanza_multinodo_waypoints.sh > /shared/wp.log 2>&1'
# =============================================================================

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
XPN_SCRIPT="/home/lab/src/xpn/scripts/execute/xpn.sh"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"
CONTROLLER_DIR="$FLEXMPI_DIR/controller"
LOG_DIR="$EPIGRAPH_DIR/mis_logs"

# =============================================================================
# CONFIGURACIÓN  (ajustable por env)
# =============================================================================
N_A=${N_A:-8}                    # procesos iniciales (fase barata pre-epidemia)
N_MAX=${N_MAX:-48}               # nº de contenedores app = tope de procesos (>= mayor waypoint)
N_XPN_NODES=2                    # servidores XPN exclusivos en el otro nodo físico
WAYPOINTS=${WAYPOINTS:-"78:48"}  # calendario "día:procs ..." (Run 1 por defecto)
RUN_TAG=${RUN_TAG:-wp}           # etiqueta para el nombre del log

BATCH_MAX=${BATCH_MAX:-16}       # máx. hijos nuevos por lote de spawn (evita spawn parcial)
APPLY_LEAD=${APPLY_LEAD:-720}    # iters de antelación con que se programa cada comando (0.5 día)
SPAWN_TIMEOUT=${SPAWN_TIMEOUT:-180}  # s máx esperando a que un lote suba el NumRanks
DMR_DELAY=${DMR_DELAY:-20}       # s de cortesía antes de que el scheduler empiece a vigilar
SIM_DAYS=${SIM_DAYS:-130}        # días simulados (acortar para validar rápido)

XPN_PREFIX="/tmp/expand/xpn"
BYPASS_SO="/shared/xpn_bypass_patched.so"
XML_FILE="$EPIGRAPH_DIR/src/data/XMLConfigFile.xml"
export XPN_SCK_PORT=5555
XPN_LOC=0

N_TOTAL_NODES=$(wc -l < /work/machines_mpi)
if [ "$N_TOTAL_NODES" -lt $(( N_MAX + N_XPN_NODES )) ]; then
    echo "ERROR: machines_mpi tiene $N_TOTAL_NODES entradas; se necesitan $(( N_MAX + N_XPN_NODES ))"
    echo "       (${N_MAX} app + ${N_XPN_NODES} XPN). Arranca: ./xpn_docker.sh start ${N_MAX} ${N_XPN_NODES}"
    exit 1
fi
# Validar que ningún waypoint excede N_MAX
for wp in $WAYPOINTS; do
    _t=${wp##*:}
    if [ "$_t" -gt "$N_MAX" ]; then
        echo "ERROR: waypoint '$wp' pide $_t procs > N_MAX=$N_MAX. Sube N_MAX (y ./xpn_docker.sh start $_t 2)."
        exit 1
    fi
done

# =============================================================================
# ENTORNO
# =============================================================================
export MY_LD_LIB=$LD_LIBRARY_PATH:$FLEXMPI_DIR/lib:/home/lab/bin/mpich/lib:/shared/papi-install/lib:/shared/libpfm4-install/lib
export FI_PROVIDER=sockets
export HYDRA_IFACE=eth0
export PATH=/home/lab/bin/mpich/bin:$PATH
export LIBPFM_FORCE_PMU=icx
export PAPI_EVENTS_FILE=/shared/papi-install/share/papi/papi_events.csv
export XPN_CONF=/shared/config.txt
export XPN_LOCALITY=$XPN_LOC
unset MOUNT_POINT

run_epigraph() {
    local NP=$1
    local HOSTFILE=$2
    echo "  Lanzando epiGraph con $NP procesos iniciales (waypoints: ${WAYPOINTS})"
    LD_PRELOAD="$BYPASS_SO" \
    $MPIEXEC -genvall \
        -np $NP \
        -usize "$N_MAX" \
        -hostfile "$HOSTFILE" \
        -genv XPN_CONF /shared/config.txt \
        -genv XPN_LOCALITY $XPN_LOC \
        -genv XPN_SCK_PORT $XPN_SCK_PORT \
        -genv LD_PRELOAD "$BYPASS_SO" \
        -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
        -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
        -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
        -genv LIBPFM_FORCE_PMU icx \
        -genv PAPI_EVENTS_FILE /shared/papi-install/share/papi/papi_events.csv \
        ./epiGraph random "@" \
        -cfile /shared/nodefile2.dat \
        -policy-malleability-triggered \
        -lbpolicy-counts \
        -ni 1440 \
        -nilb 144 \
        -ports 6668 6669 \
        -controller "$CTRL_NODE" \
        -IOaction 0 >> >(tee -a "$LOG_FILE") 2>> >(tee -a "$ERR_FILE" >&2)
}

# =============================================================================
# PASO 1 (UNA VEZ): SSH + DNS + HOSTNAMES + NODEFILES  (head=app, tail=xpn)
# =============================================================================
echo "=========================================="
echo "1. SSH, DNS y hostfiles (una vez)..."
echo "=========================================="

rm -f /shared/ssh_authorized_keys_all
> /shared/ssh_authorized_keys_all
command -v sshpass &>/dev/null || sudo apt-get install -y -q sshpass

while IFS= read -r ip; do
    [ -n "$ip" ] && sshpass -p "lab" ssh -q -n \
        -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
        lab@$ip "cat /home/lab/.ssh/id_rsa.pub" >> /shared/ssh_authorized_keys_all
done < /work/machines_mpi
while IFS= read -r ip; do
    [ -n "$ip" ] && sshpass -p "lab" ssh -q -n \
        -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
        lab@$ip "cat /shared/ssh_authorized_keys_all >> /home/lab/.ssh/authorized_keys \
                 && sort -u /home/lab/.ssh/authorized_keys -o /home/lab/.ssh/authorized_keys \
                 && chmod 600 /home/lab/.ssh/authorized_keys"
done < /work/machines_mpi
echo "✓ SSH verificado"

rm -f /shared/nodefile*.dat /shared/hostfile*.txt
> /shared/global_hosts.txt
ALL_HOSTS=()
_node_idx=0
while IFS= read -r ip; do
    if [ -n "$ip" ]; then
        REAL_HOST=$(ssh -q -n -o StrictHostKeyChecking=no "$ip" "hostname" | tr -d '\r\n')
        if grep -q " $REAL_HOST$" /shared/global_hosts.txt 2>/dev/null; then
            UNIQUE_HOST="node-$(echo "$ip" | tr '.' '-')"
            ssh -q -n -o StrictHostKeyChecking=no "$ip" \
                "sudo hostname $UNIQUE_HOST && echo $UNIQUE_HOST | sudo tee /etc/hostname > /dev/null"
            REAL_HOST=$UNIQUE_HOST
        fi
        echo "$ip $REAL_HOST" >> /shared/global_hosts.txt
        ALL_HOSTS+=("$REAL_HOST")
        ssh -q -n -o StrictHostKeyChecking=no "$ip" \
            "pkill -9 epiGraph 2>/dev/null; pkill -9 hydra 2>/dev/null; rm -f /tmp/xpn* 2>/dev/null; true"
        ssh -q -n -o StrictHostKeyChecking=no "$ip" \
            "mkdir -p ~/.ssh && printf 'Host *\n\tStrictHostKeyChecking no\n\tUserKnownHostsFile /dev/null\n' \
            > ~/.ssh/config && chmod 600 ~/.ssh/config"
        if [ $_node_idx -lt $N_MAX ]; then
            echo "${REAL_HOST}:12:${REAL_HOST}:100:5000" >> /shared/nodefile2.dat
            echo "${REAL_HOST}:1:${REAL_HOST}" >> /shared/nodefile.dat
        fi
        _node_idx=$((_node_idx + 1))
    fi
done < /work/machines_mpi

while IFS= read -r ip; do
    [ -n "$ip" ] && cat /shared/global_hosts.txt | ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "sudo tee -a /etc/hosts > /dev/null"
done < /work/machines_mpi

head -n $N_MAX /work/machines_mpi > /shared/app_nodes_ips.txt
tail -n $N_XPN_NODES /work/machines_mpi > /shared/xpn_nodes_ips.txt
echo "✓ Modo EXCLUSIVO multinodo: ${N_MAX} nodos cómputo + ${N_XPN_NODES} nodos XPN"

: > /shared/hostfile_init.txt
for ((i=0; i<N_A; i++)); do echo "${ALL_HOSTS[$i]}:1"; done >> /shared/hostfile_init.txt

mkdir -p "$EPIGRAPH_DIR/output"
CTRL_NODE="${ALL_HOSTS[0]}"
echo "  Controller: $CTRL_NODE"
echo "  Nodos XPN dedicados:"; sed 's/^/    /' /shared/xpn_nodes_ips.txt

cp -f "$XML_FILE" "${XML_FILE}.bak_xpn"
restore_xml() { [ -f "${XML_FILE}.bak_xpn" ] && mv -f "${XML_FILE}.bak_xpn" "$XML_FILE" && echo "✓ XML restaurado"; }
trap restore_xml EXIT
sed -i 's#SimDays\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#SimDays\1=\2"'"$SIM_DAYS"'"#' "$XML_FILE"
sed -i 's#PathStructure\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#PathStructure\1=\2"'"$XPN_PREFIX"'/struct/"#' "$XML_FILE"
echo "✓ XML PathStructure -> $XPN_PREFIX/struct/ ; SimDays -> $SIM_DAYS"
grep -E "PathDest|PathStructure|SimDays" "$XML_FILE"

mkdir -p "$CONTROLLER_DIR/../run"
cp /shared/nodefile2.dat "$CONTROLLER_DIR/../run/nodefile2.dat"
echo "$CTRL_NODE" > "$CONTROLLER_DIR/controller.dat"
WORKLOAD_LINE="epigraph:0:0:0:0:0.000000:93600"
for ((i=0; i<N_MAX; i++)); do WORKLOAD_LINE="${WORKLOAD_LINE}:${ALL_HOSTS[$i]}:1"; done
echo "$WORKLOAD_LINE" > "$CONTROLLER_DIR/workload.dat"

# =============================================================================
# EJECUCIÓN ÚNICA: N_A -> [calendario de waypoints]
# =============================================================================
echo ""
echo "##########################################################"
echo "#  MALEABLE POR WAYPOINTS [${RUN_TAG}]: inicio ${N_A}, calendario '${WAYPOINTS}', tope ${N_MAX}"
echo "##########################################################"

LOG_NAME="001_xpn_mall_multinodo_${RUN_TAG}_${N_A}i_$(echo "$WAYPOINTS" | tr ' :' '_-')"
LOG_FILE="$LOG_DIR/${LOG_NAME}.log"
ERR_FILE="$LOG_DIR/${LOG_NAME}_errores.log"

rm -f "$LOG_FILE" "$ERR_FILE"
rm -f "$LOG_DIR/cpu_stats.tsv" "$LOG_DIR/io_stats.tsv"
rm -f "$EPIGRAPH_DIR/output/"* 2>/dev/null || true
rm -f /tmp/epigraph_current_phase
pkill -9 epiGraph 2>/dev/null || true
pkill -9 mpiexec  2>/dev/null || true
pkill -9 controller 2>/dev/null || true
sleep 1

echo "== XPN: limpiando storage y arrancando ${N_XPN_NODES} servidores =="
while IFS= read -r __ip; do
    [ -n "$__ip" ] && ssh -n -o StrictHostKeyChecking=no "$__ip" "rm -rf /tmp/struct /tmp/expand" 2>/dev/null
done < /shared/xpn_nodes_ips.txt
$XPN_SCRIPT -e sck -w /shared -l /shared/xpn_nodes_ips.txt -x /tmp/ -n $N_XPN_NODES start
sleep 5
LD_PRELOAD="$BYPASS_SO" $MPIEXEC -np 1 -hostfile /shared/hostfile_init.txt \
    -genv XPN_CONF /shared/config.txt -genv XPN_LOCALITY $XPN_LOC -genv XPN_SCK_PORT $XPN_SCK_PORT \
    -genv LD_PRELOAD "$BYPASS_SO" -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
    perl -e "mkdir('$XPN_PREFIX/struct'); mkdir('$XPN_PREFIX/struct/output');" || true

CPU_STATS_FILE="$LOG_DIR/cpu_stats.tsv"; IO_STATS_FILE="$LOG_DIR/io_stats.tsv"
> "$CPU_STATS_FILE"; > "$IO_STATS_FILE"
echo -e "timestamp\tphase\thostname\tcpu_percent"                   >> "$CPU_STATS_FILE"
echo -e "timestamp\tphase\thostname\tio_read_bytes\tio_write_bytes" >> "$IO_STATS_FILE"
chmod 666 "$CPU_STATS_FILE" "$IO_STATS_FILE"
PHASE_FILE="/tmp/epigraph_current_phase"; echo "N${N_A}" > "$PHASE_FILE"

cd "$CONTROLLER_DIR"; ./controller & CONTROLLER_PID=$!; cd - > /dev/null
sleep 2
echo "✓ Controlador FlexMPI arrancado (PID $CONTROLLER_PID)"

cd "$EPIGRAPH_DIR"

# --- Helpers para leer el estado en caliente desde la última línea IOPerf del log ---
#     Formato: "IOTimeStamp <ts> NumRanks: <n> s: IOPerf <iter> ..."
_last_ioperf() { grep -aE "IOTimeStamp .* IOPerf" "$LOG_FILE" 2>/dev/null | tail -1; }
cur_iter()  { _last_ioperf | grep -oE "IOPerf[[:space:]]+[0-9]+" | grep -oE "[0-9]+$"; }
cur_ranks() { _last_ioperf | grep -oE "NumRanks: [0-9]+"        | grep -oE "[0-9]+";  }

# =============================================================================
# SCHEDULER: recorre los waypoints y reconfigura (spawn escalonado / shrink dirigido)
# =============================================================================
(
    while [ ! -f "$LOG_FILE" ]; do sleep 0.5; done
    sleep "$DMR_DELAY"
    real=$N_A
    for wp in $WAYPOINTS; do
        WP_DAY=${wp%%:*}; WP_TARGET=${wp##*:}
        WP_ITER=$(( WP_DAY * 1440 ))
        echo "  [SCHED @ $(date +%T)] Waypoint día ${WP_DAY} (iter ${WP_ITER}) -> ${WP_TARGET} procs"
        # esperar a acercarse al día del waypoint
        while :; do ci=$(cur_iter); [ -n "$ci" ] && [ "$ci" -ge "$WP_ITER" ] && break; sleep 3; done
        r=$(cur_ranks); [ -n "$r" ] && real=$r

        if [ "$WP_TARGET" -gt "$real" ]; then
            # ---- SPAWN ESCALONADO adaptativo ----
            _stuck=0
            while [ "$real" -lt "$WP_TARGET" ]; do
                bt=$(( real + BATCH_MAX )); [ "$bt" -gt "$WP_TARGET" ] && bt=$WP_TARGET
                apply=$(( $(cur_iter) + APPLY_LEAD ))
                cmd="11:${apply}"
                for ((h=real; h<bt; h++)); do cmd="${cmd}:${ALL_HOSTS[$h]}:1"; done
                echo "  [SCHED spawn @ $(date +%T)] ${real}->${bt} (hosts ${real}..$((bt-1)), aplica iter ${apply})"
                nping --udp -p 6668 -c 1 "${CTRL_NODE}" --data-string "$cmd" > /dev/null 2>&1
                # esperar a que el NumRanks REAL suba respecto a 'real'
                _deadline=$(( SECONDS + SPAWN_TIMEOUT ))
                while :; do
                    nr=$(cur_ranks)
                    [ -n "$nr" ] && [ "$nr" -gt "$real" ] && break
                    [ $SECONDS -ge $_deadline ] && break
                    sleep 2
                done
                nr=$(cur_ranks); [ -z "$nr" ] && nr=$real
                if [ "$nr" -le "$real" ]; then
                    _stuck=$((_stuck+1))
                    echo "  [SCHED warn @ $(date +%T)] el lote no subió NumRanks (sigue en ${real}); reintento ${_stuck}"
                    [ $_stuck -ge 3 ] && { echo "  [SCHED abort] 3 lotes sin progreso; me quedo en ${real}"; break; }
                else
                    _stuck=0; real=$nr
                    echo "  [SCHED @ $(date +%T)] NumRanks real = ${real}"
                fi
            done
        elif [ "$WP_TARGET" -lt "$real" ]; then
            # ---- SHRINK dirigido al pico REAL ----
            apply=$(( $(cur_iter) + APPLY_LEAD ))
            cmd="11:${apply}"
            for ((h=WP_TARGET; h<real; h++)); do cmd="${cmd}:${ALL_HOSTS[$h]}:-1"; done
            echo "  [SCHED shrink @ $(date +%T)] ${real}->${WP_TARGET} (hosts ${WP_TARGET}..$((real-1)), aplica iter ${apply})"
            nping --udp -p 6668 -c 1 "${CTRL_NODE}" --data-string "$cmd" > /dev/null 2>&1
            sleep 8
            r=$(cur_ranks); [ -n "$r" ] && real=$r
        else
            echo "  [SCHED @ $(date +%T)] ya en ${real} procs, nada que hacer."
        fi
        echo "N${real}" > "$PHASE_FILE"
    done
    echo "  [SCHED @ $(date +%T)] Calendario completado; NumRanks final ~${real}."
) &
SCHED_PID=$!

echo "EXECUTION ${RUN_TAG} ${N_A} :: ${WAYPOINTS}" >> "$LOG_FILE"
T0=$(date +%s%N)
set +e
run_epigraph $N_A /shared/hostfile_init.txt
RC=$?
set -e
T_TOTAL=$(( ($(date +%s%N) - T0) / 1000000 ))

kill $SCHED_PID 2>/dev/null || true

if [[ $RC -eq 0 || $RC -eq 255 ]]; then
    echo "  ✓ Ejecución maleable [${RUN_TAG}] completada (RC=$RC) — ${T_TOTAL} ms ($(( T_TOTAL/1000 ))s)"
else
    echo "  ✗ Ejecución maleable [${RUN_TAG}] FALLÓ (RC=$RC)" >&2
fi

echo "== ¿XPN interceptó la E/S en los servidores remotos? =="
while IFS= read -r ip; do
    [ -n "$ip" ] && { echo "[$ip]"; ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "find /tmp/struct -maxdepth 3 2>/dev/null | head"; }
done < /shared/xpn_nodes_ips.txt

rm -f "$PHASE_FILE"
[ -n "${CONTROLLER_PID+x}" ] && kill $CONTROLLER_PID 2>/dev/null || true
$XPN_SCRIPT -e sck -w /shared -d /shared/xpn_nodes_ips.txt stop
while IFS= read -r node_ip; do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node_ip" "pkill -9 xpn_server 2>/dev/null; true" &
done < /shared/xpn_nodes_ips.txt
wait
sleep 3
echo ""
echo "=========================================="
echo "✅ Run maleable por waypoints [${RUN_TAG}] terminado"
echo "   Log: $LOG_FILE"
echo "=========================================="
