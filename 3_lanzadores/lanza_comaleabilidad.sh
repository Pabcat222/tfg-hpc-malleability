#!/bin/bash

# =============================================================================
# lanza_comaleabilidad.sh
# CO-MALEABILIDAD MULTINODO POR CALENDARIO DE WAYPOINTS  (spawn nativo, SIN restart)
# Extiende lanza_multinodo_waypoints.sh: ademas del calendario de PROCESOS (WAYPOINTS),
# lleva un calendario propio para los SERVIDORES de Expand (XPN_WAYPOINTS), de modo que
# los dos recursos se reconfiguran dentro de la misma ejecucion.
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
#        bash /shared/install-src/lanza_comaleabilidad.sh > /shared/wp.log 2>&1'
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
N_XPN_NODES=${N_XPN_NODES:-8}    # servidores Expand iniciales (4+4 en la topologia distribuida)
# OJO: aqui va ${VAR-...} y NO ${VAR:-...}. Con `:-` el valor por defecto tambien se
# aplica cuando la variable esta DEFINIDA PERO VACIA, que es justo como los controles
# F1/F2 desactivan el shrink -> se les reescribia a "40:4" y corrian con shrink, o sea
# como copias del perfil A. Sin los dos puntos, solo actua si no esta definida.
XPN_WAYPOINTS=${XPN_WAYPOINTS-"40:4"}    # calendario de Expand "dia:servidores" ("" = sin shrink)
# Igual que arriba: ${VAR-...} y NO ${VAR:-...}. Con los dos puntos, pasar
# WAYPOINTS="" (una run SIN maleabilidad de procesos, p. ej. una sonda del
# shrink de Expand a solas) devolvia el valor por defecto "78:48" y la run
# expandia a 48 procesos sin que nadie lo hubiera pedido.
WAYPOINTS=${WAYPOINTS-"78:48"}   # calendario "día:procs ..." ("" = sin spawn)
RUN_TAG=${RUN_TAG:-wp}           # etiqueta para el nombre del log

BATCH_MAX=${BATCH_MAX:-16}       # máx. hijos nuevos por lote de spawn (evita spawn parcial)
APPLY_LEAD=${APPLY_LEAD:-720}    # iters de antelación con que se programa cada comando (0.5 día)
SPAWN_TIMEOUT=${SPAWN_TIMEOUT:-180}  # s máx esperando a que un lote suba el NumRanks
DMR_DELAY=${DMR_DELAY:-20}       # s de cortesía antes de que el scheduler empiece a vigilar
SIM_DAYS=${SIM_DAYS:-130}        # días simulados (acortar para validar rápido)

# Rootdir de los SERVIDORES de Expand. Tiene que ser un directorio DEDICADO.
# 🔴 2026-08-06: estaba en "/tmp/", el mismo /tmp donde Hydra (el gestor de procesos de
# mpiexec) deja sus temporales. `xpn_shrink` recorre este directorio fichero a fichero y
# al toparse con /tmp/hydra_hwloc_xmlfile_* hacia:
#     open :: No such file or directory  ->  MPI_Abort(MPI_COMM_WORLD, 1)
# es decir, el shrink ABORTABA SIEMPRE y no migraba nada. Con un directorio propio solo
# ve datos de XPN. El valor se empotra en cada server_url de config.txt (xpn.sh lo
# regenera en cada `start`), asi que cliente y servidor quedan de acuerdo solos.
XPN_STORAGE=${XPN_STORAGE:-"/tmp/xpn_data/"}
XPN_PREFIX="/tmp/expand/xpn"

# -----------------------------------------------------------------------------
# SHRINK REAL (2026-08-07). Con XPN_REAL_SHRINK=1 se usa el Expand PARCHEADO de
# /shared/xpn_install, que anade recarga en caliente de config.txt al cliente.
#
# Sin el parche, retirar servidores bajo una aplicacion viva es IMPOSIBLE, no
# dificil: xpn_shrink marca el fichero como maleable (data_nserv[1] != 0) y a
# partir de ahi XpnCheckServAffectedByOp (xpn_open.c:154) da por afectados a
# TODOS los servidores de la tabla del cliente, que se cargo una sola vez en
# xpn_init.c:158 y nunca se relee. EpiGraph reabre el fichero en CADA
# checkpoint, asi que el primer open posterior al shrink iria contra los
# servidores retirados.
#
# El parche anade xpn_reload_if_needed(), que relee config.txt cuando sube el
# contador de generacion de XPN_RECONF_FILE y deja la traza [XPN-RELOAD] en el
# log. Ver /shared/01-xpn-client-reload.patch.
# -----------------------------------------------------------------------------
XPN_REAL_SHRINK=${XPN_REAL_SHRINK:-1}
if [ "$XPN_REAL_SHRINK" = "1" ]; then
    XPN_SCRIPT="/shared/xpn_build/xpn/scripts/execute/xpn.sh"
    XPN_SERVER_BIN="/shared/xpn_build/xpn/src/xpn_server/xpn_server"
    BYPASS_SO="/shared/xpn_install/xpn/lib64/xpn_bypass.so"
    export XPN_RECONF_FILE=${XPN_RECONF_FILE:-/shared/xpn_reconf_gen.txt}
else
    XPN_SERVER_BIN="/home/lab/src/xpn/src/xpn_server/xpn_server"
    BYPASS_SO="/shared/xpn_bypass_patched.so"
fi
XML_FILE="$EPIGRAPH_DIR/src/data/XMLConfigFile.xml"
export XPN_SCK_PORT=5555
# el mismo puerto en hexadecimal y en mayusculas, que es como aparece en
# /proc/net/tcp (lo usa la espera del shrink; ver nota alli sobre `ss`)
XPN_SCK_PORT_HEX=$(printf '%04X' "$XPN_SCK_PORT")
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
        -genv XPN_RECONF_FILE "${XPN_RECONF_FILE:-}" \
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
        # 🔴 timeout OBLIGATORIO. Este bucle recorre los 88 contenedores EN SERIE y
        # sin limite de tiempo: el 2026-08-07 uno de estos ssh se quedo colgado
        # (el host respondia perfectamente al probarlo a mano, o sea que era la
        # sesion ssh, no la red) y dejo la ejecucion parada indefinidamente
        # despues de "SSH verificado", sin un solo mensaje de error. En un lote de
        # 6 runs eso son horas de reserva tiradas sin que nadie se entere.
        timeout 20 ssh -q -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ip" \
            "pkill -9 epiGraph 2>/dev/null; pkill -9 hydra 2>/dev/null; rm -f /tmp/xpn* 2>/dev/null; true" \
            || echo "  [AVISO] limpieza previa sin respuesta en $ip (se continua)"
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

LOG_NAME="001_comall_${RUN_TAG}_${N_A}i_$(echo "$WAYPOINTS" | tr ' :' '_-')_xpn$(echo "${XPN_WAYPOINTS:-none}" | tr ' :' '_-')"
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
    [ -n "$__ip" ] && ssh -n -o StrictHostKeyChecking=no "$__ip" \
        "rm -rf /tmp/struct /tmp/expand ${XPN_STORAGE}; mkdir -p ${XPN_STORAGE}" 2>/dev/null
done < /shared/xpn_nodes_ips.txt
if [ "$XPN_REAL_SHRINK" = "1" ]; then
    # ---------------------------------------------------------------------
    # ARRANQUE INDEPENDIENTE, UN mpiexec POR SERVIDOR.
    # `xpn.sh start` con -e sck lanza los N servidores como UN SOLO
    # `mpiexec -np N` (xpn.sh:132-135). Al ser los N rangos del mismo trabajo,
    # Hydra aborta el trabajo entero en cuanto cae uno -> retirar 4 de 8 mataba
    # la ejecucion. La propia xpn.sh ya hace lo contrario en su otra rama
    # (xpn.sh:145-151, un `mpiexec -np 1` por host), asi que aqui se hace igual
    # para sck: cada servidor es un trabajo suyo y se puede retirar solo.
    # ---------------------------------------------------------------------
    $XPN_SCRIPT -e sck -w /shared -l /shared/xpn_nodes_ips.txt -x "$XPN_STORAGE" \
                -n $N_XPN_NODES -o 512k mk_conf
    sed -i '/^$/d' /shared/config.txt
    echo 0 > "$XPN_RECONF_FILE"          # generacion inicial (contador, no mtime)
    __i=0
    while IFS= read -r __ip; do
        [ -z "$__ip" ] && continue
        __i=$((__i+1))
        [ "$__i" -gt "$N_XPN_NODES" ] && break
        $MPIEXEC -np 1 -host "$__ip" "$XPN_SERVER_BIN" -s sck -t pool &
    done < /shared/xpn_nodes_ips.txt
    sleep 8
    echo "  [XPN] arrancados ${__i} servidores como trabajos independientes"
else
    $XPN_SCRIPT -e sck -w /shared -l /shared/xpn_nodes_ips.txt -x "$XPN_STORAGE" -n $N_XPN_NODES start
    sleep 5
fi
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

# =============================================================================
# SCHEDULER DE EXPAND: reduce servidores segun XPN_WAYPOINTS="dia:servidores"
# La aplicacion es E/S-bound hasta ~d40 y CPU-bound despues: pasado ese punto
# los servidores estan ociosos el 91-95% del tiempo y se pueden retirar.
# =============================================================================
if [ -n "${XPN_WAYPOINTS}" ]; then
(
    while [ ! -f "$LOG_FILE" ]; do sleep 0.5; done
    for wp in $XPN_WAYPOINTS; do
        WP_DAY=${wp%%:*}; WP_TARGET=${wp##*:}
        WP_ITER=$(( WP_DAY * 1440 ))
        echo "  [XPN-SCHED] waypoint dia ${WP_DAY} -> ${WP_TARGET} servidores"
        while :; do ci=$(cur_iter); [ -n "$ci" ] && [ "$ci" -ge "$WP_ITER" ] && break; sleep 3; done
        VIVOS=$(grep -c . /shared/xpn_nodes_ips.txt)
        RETIRAR=$(( VIVOS - WP_TARGET ))
        if [ "$RETIRAR" -gt 0 ]; then
            # -----------------------------------------------------------------
            # SECUENCIA DE RECONFIGURACION DE EXPAND — variante "v2" de la
            # referencia que trae el propio XPN: admire/io-scheduler/expand.sh,
            # caso `shrink_v2` ("start and stop only necessary servers").
            #
            # 🔴 2026-08-06: lo que habia aqui era una secuencia CASERA (`shrink`
            # y luego `stop` a pelo) que NO es la soportada, y por eso la campana
            # entera midio un artefacto:
            #   - `xpn.sh shrink` solo copia; `stop` es otra accion del case.
            #   - el `stop` a secas se cuelga si hay clientes conectados (sus
            #     hilos del pool nunca recogen el TH_FINALIZE), asi que los 4
            #     servidores "retirados" seguian VIVOS y sirviendo hasta el final.
            #   - `config.txt` (=XPN_CONF) seguia listando los 8, de modo que los
            #     clientes nunca se enteraban de la retirada.
            # => la run 8->4 corria en realidad con 8 servidores todo el rato.
            #
            # La secuencia correcta es:
            #   1) `stop_await` SOLO a los retirados. La variante "await" manda
            #      SOCKET_FINISH_CODE_AWAIT en vez de SOCKET_FINISH_CODE: el
            #      servidor espera en vez de cerrar de golpe, que es el mecanismo
            #      de coordinacion previsto para no atropellar a los clientes.
            #   2) `rebuild`, que migra con `xpn_rebuild_active_writer` leyendo
            #      los directorios de almacenamiento LOCALES (no necesita los
            #      servidores vivos) y —esto es lo que faltaba— REGENERA
            #      config.txt a partir del rebuildfile, o sea con los
            #      supervivientes.
            # NO se usa `shrink_v3`: ese para TODOS los servidores y rearranca
            # los supervivientes, dejando una ventana sin almacenamiento.
            # -----------------------------------------------------------------
            # la lista va intercalada por nodo, asi que el tail reparte la retirada 50/50
            tail -n "$RETIRAR"   /shared/xpn_nodes_ips.txt > /shared/xpn_death.txt
            head -n "$WP_TARGET" /shared/xpn_nodes_ips.txt > /shared/xpn_rebuild.txt
            cp /shared/xpn_nodes_ips.txt /shared/xpn_oldall.txt
            echo "  [XPN-SCHED @ $(date +%T)] shrink ${VIVOS} -> ${WP_TARGET} (retira ${RETIRAR})"

            if [ "$XPN_REAL_SHRINK" = "1" ]; then
            # =================================================================
            # SECUENCIA CON EL CLIENTE PARCHEADO (2026-08-07)
            #
            # Ni v1 ni v2 ni v3 de la referencia sirven con la aplicacion viva:
            #   v2 (stop_await a los retirados) SE INTERBLOQUEA -- el servidor
            #      hace worker_pool_destroy() y su pthread_join no vuelve nunca
            #      porque los hilos siguen sirviendo a EpiGraph, que no se ha
            #      enterado de nada (medido: 14 min sin avanzar).
            #   v1/v3 paran TODOS los servidores -> ventana sin almacenamiento.
            #
            # Aqui el orden se invierte: primero se migra con todos vivos, luego
            # se avisa a los clientes (que se reconfiguran solos gracias al
            # parche) y SOLO cuando ya nadie les habla se retiran los servidores.
            # Como cada servidor es un mpiexec independiente, matarlos no toca a
            # los supervivientes.
            # =================================================================

            # -----------------------------------------------------------------
            # MEDIDA DE LA MIGRACION, ANTES Y DESPUES.
            # 🔴 El rc de xpn_shrink NO PRUEBA NADA: es exactamente la evidencia
            # que nos engano toda la campana anterior (un MPI_Abort daba rc=0).
            # Y esta campana NO detecta sola la perdida de datos, porque
            # tPersonalInfo.dat se reescribe entero en cada checkpoint y nadie lo
            # lee: si la migracion no ocurriera, la run iria igual de bien.
            # Por eso se miden los BYTES del rootdir de cada servidor. Si la
            # migracion es real: los retirados caen a ~0 y los supervivientes
            # absorben el total.
            # -----------------------------------------------------------------
            __bytes_de() {
                local __lista=$1 __tot=0 __b
                while IFS= read -r __bip; do
                    [ -n "$__bip" ] || continue
                    __b=$(ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$__bip" \
                          "du -sb ${XPN_STORAGE} 2>/dev/null | cut -f1" 2>/dev/null || echo 0)
                    __tot=$(( __tot + ${__b:-0} ))
                done < "$__lista"
                echo "$__tot"
            }
            __B_RET_ANTES=$(__bytes_de /shared/xpn_death.txt)
            __B_SUP_ANTES=$(__bytes_de /shared/xpn_rebuild.txt)
            echo "  [XPN-SCHED @ $(date +%T)] bytes ANTES  retirados=${__B_RET_ANTES} supervivientes=${__B_SUP_ANTES}"

            # 1) migracion de bloques, con los 8 servidores todavia vivos (~1 s)
            $XPN_SCRIPT -e sck -w /shared -n "$VIVOS" -l /shared/xpn_oldall.txt \
                        -x "$XPN_STORAGE" -d /shared/xpn_death.txt shrink
            RC_SHR=$?
            echo "  [XPN-SCHED @ $(date +%T)] xpn_shrink rc=${RC_SHR}"

            __B_RET_DESP=$(__bytes_de /shared/xpn_death.txt)
            __B_SUP_DESP=$(__bytes_de /shared/xpn_rebuild.txt)
            echo "  [XPN-SCHED @ $(date +%T)] bytes DESPUES retirados=${__B_RET_DESP} supervivientes=${__B_SUP_DESP}"
            echo "  [XPN-SCHED] bytes (informativo):" \
                 "retirados ${__B_RET_ANTES}->${__B_RET_DESP}, supervivientes ${__B_SUP_ANTES}->${__B_SUP_DESP}"

            # -----------------------------------------------------------------
            # LA GUARDA DE VERDAD: que NINGUN BLOQUE apunte ya a un retirado.
            #
            # ⚠️ Los bytes de arriba quedan como informativos y NO sirven de
            # criterio: `xpn_shrink` es un COPY (asi esta comentado el paso en
            # xpn.sh:shrink_xpn, "# 1. Copy"), de modo que los retirados NUNCA se
            # vacian -- se quedan con una copia huerfana que ya nadie direcciona.
            # Medido: 442 MB -> 331 MB, no a 0. Una guarda del tipo "los retirados
            # deben caer a ~0" no se cumple nunca, y una del tipo "no deben crecer"
            # se cumple sola y dejaria pasar una migracion PARCIAL.
            # El criterio correcto es el direccionamiento, que es lo que se rompe
            # si falta un bloque: se muestrea el fichero con xpn_get_block_locality
            # y no puede haber ni uno en un servidor que vaya a morir.
            # -----------------------------------------------------------------
            __LOC=$(N=60 bash /shared/comprueba_localidad.sh 2>&1)
            if echo "$__LOC" | grep -q "NINGÚN bloque apunta"; then
                echo "  [XPN-SCHED] migracion VERIFICADA: 0 bloques en servidores retirados (60 muestreados)"
            else
                echo "  [XPN-SCHED] 🔴 MIGRACION NO VERIFICADA aunque el rc fuera ${RC_SHR}. NO se retira nada:"
                echo "$__LOC" | sed 's/^/      /'
                continue
            fi
            if [ "$RC_SHR" -ne 0 ]; then
                echo "  [XPN-SCHED] 🔴 migracion FALLIDA: no se retira nada (pararlos sin migrar = perder datos)"
                continue
            fi

            # 2) config.txt nuevo, solo con los supervivientes
            $XPN_SCRIPT -e sck -w /shared -l /shared/xpn_rebuild.txt \
                        -x "$XPN_STORAGE" -n "$WP_TARGET" -o 512k mk_conf
            sed -i '/^$/d' /shared/config.txt

            # 3) subir la generacion: cada cliente lo ve en su siguiente open
            #    (EpiGraph reabre el fichero en cada checkpoint, ~2,6 s a d40)
            __gen=$(cat "$XPN_RECONF_FILE" 2>/dev/null || echo 0)
            echo $(( __gen + 1 )) > "$XPN_RECONF_FILE"
            echo "  [XPN-SCHED @ $(date +%T)] generacion -> $(( __gen + 1 )), esperando recarga de los clientes"

            # 4) esperar A QUE NADIE HABLE YA con los retirados. Se mide sobre
            #    las conexiones TCP reales, no sobre un contador de recargas: el
            #    numero de procesos vivos aqui es incierto (el spawn de EpiGraph
            #    cae el mismo dia) y contar mal nos dejaria matando servidores
            #    con clientes colgados de ellos.
            __t0=$SECONDS
            while :; do
                __conn=0
                while IFS= read -r __dip; do
                    [ -n "$__dip" ] || continue
                    # 🔴 Se lee /proc/net/tcp y NO `ss`: en esta imagen `ss` NO
                    # EXISTE, asi que el bucle habria contado 0 conexiones
                    # siempre y habria matado los servidores al instante, con
                    # los clientes todavia colgados de ellos. Un fallo mudo mas.
                    # st=01 es ESTABLISHED; 15B3 = 5555 en hexadecimal.
                    __c=$(ssh -n -o StrictHostKeyChecking=no "$__dip" \
                          "awk 'NR>1 && \$4==\"01\" && \$2 ~ /:${XPN_SCK_PORT_HEX}\$/ {n++} END {print n+0}' /proc/net/tcp" 2>/dev/null || echo 0)
                    __conn=$(( __conn + ${__c:-0} ))
                done < /shared/xpn_death.txt
                [ "$__conn" -eq 0 ] && break
                if [ $(( SECONDS - __t0 )) -gt 120 ]; then
                    echo "  [XPN-SCHED] ⚠️ 120 s y aun quedan ${__conn} conexiones a los retirados; se retiran igual"
                    break
                fi
                sleep 2
            done
            __nrel=$(grep -c "XPN-RELOAD" "$ERR_FILE" "$LOG_FILE" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
            echo "  [XPN-SCHED @ $(date +%T)] conexiones restantes=${__conn}, trazas [XPN-RELOAD]=${__nrel} (${SECONDS_ELAPSED:-$(( SECONDS - __t0 ))} s)"

            # 5) ahora si: retirar los servidores. Cada uno es su propio mpiexec,
            #    asi que esto NO toca a los supervivientes (con el arranque
            #    antiguo, en un solo mpiexec -np 8, mataba la ejecucion entera).
            while IFS= read -r __dip; do
                [ -n "$__dip" ] || continue
                ssh -n -o StrictHostKeyChecking=no "$__dip" "pkill -TERM -x xpn_server || true" 2>/dev/null
            done < /shared/xpn_death.txt
            sleep 3
            else
            # ---- camino ANTIGUO (v2), conservado solo para reproducir el artefacto ----
            $XPN_SCRIPT -e sck -w /shared -d /shared/xpn_death.txt stop_await
            RC_STOP=$?          # capturar ANTES de cualquier $(...), ver nota de abajo
            echo "  [XPN-SCHED @ $(date +%T)] stop_await rc=${RC_STOP}"

            $XPN_SCRIPT -e sck -w /shared -n "$VIVOS" -l /shared/xpn_oldall.txt \
                        -x "$XPN_STORAGE" -d /shared/xpn_oldall.txt \
                        -b /shared/xpn_rebuild.txt rebuild
            RC_REB=$?
            echo "  [XPN-SCHED @ $(date +%T)] rebuild rc=${RC_REB}"
            fi
            # 🔴 Los rc se capturan SIEMPRE en la linea siguiente al comando. Poner
            # `echo "... $(date +%T) rc=$?"` da el rc de `date`, que es 0 SIEMPRE, y
            # fue lo que oculto el MPI_Abort de xpn_shrink durante toda la campana:
            #     false; echo "rc=$?"             -> rc=1
            #     false; echo "$(date +%T) rc=$?" -> rc=0

            # 3) VERIFICACION POR EFECTO, nunca por rc. En esta cadena nada falla
            #    ruidosamente (hemos visto MPI_Abort con rc=0, y un
            #    "mpiexec: command not found" con rc=127 dando por bueno un stop).
            __vivos=0
            while IFS= read -r __dip; do
                [ -n "$__dip" ] || continue
                # `pgrep -xc` DEVUELVE 1 CUANDO LA CUENTA ES 0, y con `set -e` eso
                # aborta el script justo cuando el resultado es el BUENO (0 retirados
                # vivos). Paso 2026-08-06: mato la sonda despues de un shrink correcto.
                __n=$(ssh -n -o StrictHostKeyChecking=no "$__dip" \
                      "pgrep -xc xpn_server || true" 2>/dev/null || echo 0)
                __vivos=$(( __vivos + ${__n:-0} ))
            done < /shared/xpn_death.txt
            __srv_cfg=$(grep -c server_url /shared/config.txt 2>/dev/null)
            echo "  [XPN-SCHED @ $(date +%T)] retirados aun vivos=${__vivos} (esperado 0)," \
                 "server_url en config.txt=${__srv_cfg} (esperado ${WP_TARGET})"

            # el stop final solo debe intentar parar los que siguen vivos
            mv /shared/xpn_rebuild.txt /shared/xpn_nodes_ips.txt
        else
            echo "  [XPN-SCHED] ya hay ${VIVOS} servidores, nada que retirar"
        fi
    done
    echo "  [XPN-SCHED @ $(date +%T)] calendario de Expand completado"
) &
XPN_SCHED_PID=$!
fi

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
# 🔴 EL pkill VA PRIMERO, Y SOBRE LA LISTA COMPLETA.
# Dos motivos, los dos medidos:
#  1) `xpn.sh stop` SE CUELGA cuando los servidores no contestan al ACK, asi que
#     el bucle de pkill que habia DESPUES no llegaba a ejecutarse nunca. Resultado:
#     al acabar cada run quedaban servidores girando en el bucle infinito de
#     "[socket_send] ERROR: client closed the connection", comiendo CPU de los
#     nodos reservados y contaminando la medida de la run siguiente.
#  2) Se recorre `tail -n $N_XPN_NODES /work/machines_mpi` y NO
#     /shared/xpn_nodes_ips.txt, porque tras un shrink ese fichero contiene ya
#     solo a los SUPERVIVIENTES -> los retirados no se limpiarian.
tail -n "$N_XPN_NODES" /work/machines_mpi | while IFS= read -r node_ip; do
    [ -n "$node_ip" ] || continue
    ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node_ip" \
        "pkill -9 -x xpn_server 2>/dev/null; true" &
done
wait
$XPN_SCRIPT -e sck -w /shared -d /shared/xpn_nodes_ips.txt stop 2>/dev/null || true
wait
sleep 3
echo ""
echo "=========================================="
echo "✅ Run maleable por waypoints [${RUN_TAG}] terminado"
echo "   Log: $LOG_FILE"
echo "=========================================="
