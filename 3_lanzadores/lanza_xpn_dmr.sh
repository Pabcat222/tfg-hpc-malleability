#!/bin/bash

# =============================================================================
# lanza_xpn_dmr.sh
# EpiGraph CON XPN — Maleabilidad DMR nativa (MPI_Comm_spawn)
# 1 switch: 8p→16p (día 41) sin reiniciar mpiexec
# =============================================================================

set -e

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
XPN_SCRIPT="/home/lab/src/xpn/scripts/execute/xpn.sh"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"

SCRIPT_DIR="/home/pabcat/Escritorio/TFG/xpn-docker"
LOG_DIR="$EPIGRAPH_DIR/mis_logs"

# --- Configuración DMR --- (Tucán 3.5M: 8p→16p, spawn en día 41 = inicio del pico)
NUM_PROCS_INIT=8    # procesos con los que arranca EpiGraph (fase A)
N_NODES=16
MAX_SLOTS_PER_NODE=12

# 1 switch: 8p→16p (día 41)
# Iters: 41×1440=59040
DMR_DAYS=(41)
DMR_ITERS=(59040)
DMR_DELTAS=(1)  # sw0=spawn, 1 proc por host

# Nodos usados por spawn: ALL_HOSTS[8..15] (8 nodos extra → 8→16)
SPAWN_START=(8)
SPAWN_END=(16)

# Delay (s) para enviar el comando por nping.
# El comando lleva la iter objetivo (59040); el controlador lo encola y dispara
# el spawn al alcanzarla. Solo hay que enviarlo ANTES (8p tarda ~380s en llegar
# a día 41) → 20s es de sobra.
DMR_DELAYS=(20)

XPN_MODE="colocalizado"
N_XPN_NODES=1

LOG_NAME="001_xpn_dmr_${N_NODES}n_8p16p_1sw_d41_1"
LOG_FILE="$LOG_DIR/${LOG_NAME}.log"
ERR_FILE="$LOG_DIR/${LOG_NAME}_errores.log"

# =============================================================================
# LIMPIEZA
# =============================================================================
echo "=========================================="
echo "0. Limpiando..."
echo "=========================================="

mkdir -p "$LOG_DIR"
rm -f "$LOG_FILE" "$ERR_FILE"
rm -f "$LOG_DIR/cpu_stats.tsv" "$LOG_DIR/io_stats.tsv"
rm -f "$EPIGRAPH_DIR/output/"* 2>/dev/null || true
rm -f /tmp/epigraph_current_phase
pkill -9 epiGraph 2>/dev/null || true
pkill -9 mpiexec  2>/dev/null || true
pkill -9 controller 2>/dev/null || true
sleep 1
echo "✓ Limpieza completada"

# =============================================================================
# CONFIGURACIÓN DE ENTORNO
# =============================================================================
export MY_LD_LIB=$LD_LIBRARY_PATH:$FLEXMPI_DIR/lib:/home/lab/bin/mpich/lib:/shared/papi-install/lib:/shared/libpfm4-install/lib
export FI_PROVIDER=sockets
export PATH=/home/lab/bin/mpich/bin:$PATH
export LIBPFM_FORCE_PMU=icx   # Tucán (Ice Lake-X). Portátil usaba adl_glc.
export PAPI_EVENTS_FILE=/shared/papi-install/share/papi/papi_events.csv
export XPN_CONF=/shared/config.txt   # exportado para que MPI_Comm_spawn lo herede

# =============================================================================
# FUNCIÓN: run_epigraph
# =============================================================================
run_epigraph() {
    local NP=$1
    local HOSTFILE=$2

    echo "  Lanzando epiGraph con $NP procesos iniciales (DMR activado)"

    $MPIEXEC -genvall \
        -np $NP \
        -hostfile "$HOSTFILE" \
        -genv XPN_CONF /shared/config.txt \
        -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
        -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
        -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
        -genv LIBPFM_FORCE_PMU icx \
        ./epiGraph random ./ \
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
# PASO 1: SSH + DNS + HOSTFILES
# =============================================================================
echo "=========================================="
echo "1. SSH, DNS y hostfiles..."
echo "=========================================="

rm -f /shared/ssh_authorized_keys_all
> /shared/ssh_authorized_keys_all

if ! command -v sshpass &>/dev/null; then
    sudo apt-get install -y -q sshpass
fi

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

N_APP_NODES=$N_NODES

rm -f /shared/nodefile*.dat /shared/hostfile_fase*.txt
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

        echo "${REAL_HOST}:${MAX_SLOTS_PER_NODE}:${REAL_HOST}:100:5000" >> /shared/nodefile2.dat
        echo "${REAL_HOST}:1:${REAL_HOST}" >> /shared/nodefile.dat

        _node_idx=$((_node_idx + 1))
    fi
done < /work/machines_mpi

while IFS= read -r ip; do
    [ -n "$ip" ] && cat /shared/global_hosts.txt | ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "sudo tee -a /etc/hosts > /dev/null"
done < /work/machines_mpi

cp /work/machines_mpi /shared/xpn_machines_ips.txt
cp /work/machines_mpi /shared/xpn_nodes_ips.txt

# Hostfile inicial con NUM_PROCS_INIT procesos (round-robin sobre los 8 nodos)
for ((i=0; i<NUM_PROCS_INIT; i++)); do
    echo "${ALL_HOSTS[$((i % N_NODES))]}:1"
done > /shared/hostfile_dmr_init.txt

mkdir -p "$EPIGRAPH_DIR/output"

CTRL_NODE="${ALL_HOSTS[0]}"

echo "✓ $N_NODES nodos configurados"
echo "  Hostfile inicial (${NUM_PROCS_INIT}p): $(cat /shared/hostfile_dmr_init.txt | tr '\n' ' ')"
echo "  Nodos spare para DMR spawn: ${ALL_HOSTS[@]:$NUM_PROCS_INIT}"

# =============================================================================
# PASO 2: XPN
# =============================================================================
echo ""
echo "=========================================="
echo "2. Iniciando XPN..."
echo "=========================================="
$XPN_SCRIPT -w /shared -l /shared/xpn_nodes_ips.txt -x /tmp/ -n $N_NODES start
sleep 5

# =============================================================================
# PASO 2.5: CPU STATS
# =============================================================================
CPU_STATS_FILE="$LOG_DIR/cpu_stats.tsv"
IO_STATS_FILE="$LOG_DIR/io_stats.tsv"
> "$CPU_STATS_FILE"
> "$IO_STATS_FILE"
chmod 666 "$CPU_STATS_FILE" "$IO_STATS_FILE"
echo -e "timestamp\tphase\thostname\tcpu_percent" >> "$CPU_STATS_FILE"
echo -e "timestamp\tphase\thostname\tio_read_bytes\tio_write_bytes" >> "$IO_STATS_FILE"

PHASE_FILE="/tmp/epigraph_current_phase"
echo "A" > "$PHASE_FILE"

echo "=========================================="
echo "  IMPORTANTE: Muestreo de CPU"
echo "  Abre una terminal en el HOST:"
echo "    bash ~/Escritorio/TFG/xpn-docker/sample_cpu_host.sh"
echo "=========================================="

# =============================================================================
# PASO 2.7: CONTROLADOR FLEXMPI
# =============================================================================
CONTROLLER_DIR="/shared/install-src/FlexMPIDeveloper/controller"
echo ""
echo "=========================================="
echo "2.7 Iniciando controlador FlexMPI..."
echo "=========================================="

echo "$CTRL_NODE" > "$CONTROLLER_DIR/controller.dat"
mkdir -p "$CONTROLLER_DIR/../run"
cp /shared/nodefile2.dat "$CONTROLLER_DIR/../run/nodefile2.dat"

WORKLOAD_LINE="epigraph:0:0:0:0:0.000000:93600"
for ((i=0; i<N_APP_NODES; i++)); do
    WORKLOAD_LINE="${WORKLOAD_LINE}:${ALL_HOSTS[$i]}:1"
done
echo "$WORKLOAD_LINE" > "$CONTROLLER_DIR/workload.dat"
echo "✓ workload.dat regenerado"

cd "$CONTROLLER_DIR"
./controller &
CONTROLLER_PID=$!
cd - > /dev/null
sleep 2

echo "✓ Controlador FlexMPI arrancado (PID $CONTROLLER_PID, nodo: $CTRL_NODE)"

# =============================================================================
# PASO 3: EJECUCIÓN — DMR nativo 1 switch (4p→8p)
# =============================================================================
cd "$EPIGRAPH_DIR"

echo ""
echo "=========================================="
echo "3. Ejecución DMR nativa — 1 switch (día 41)"
echo "   Patrón: 8p→16p"
echo "=========================================="

# Construir el comando DMR: "11:<iter>:<host>:<delta>:..."
# sw0 usa nodos SPAWN_START[0]..SPAWN_END[0]-1
PHASE_LABELS=("B")
TRIGGER_PIDS=()

for sw in 0; do
    ITER="${DMR_ITERS[$sw]}"
    DELTA="${DMR_DELTAS[$sw]}"
    DELAY="${DMR_DELAYS[$sw]}"
    DAY="${DMR_DAYS[$sw]}"

    DMR_CMD="11:${ITER}"
    for ((i=SPAWN_START[sw]; i<SPAWN_END[sw]; i++)); do
        DMR_CMD="${DMR_CMD}:${ALL_HOSTS[$i]}:${DELTA}"
    done
    echo "  Switch $((sw+1))/1 — día $DAY (iter $ITER), delta=$DELTA — envío en ${DELAY}s: $DMR_CMD"

    (
        sleep "$DELAY"
        echo "  [DMR sw$((sw+1)) @ $(date +%T)] Enviando: $DMR_CMD"
        nping --udp -p 6668 -c 1 "${ALL_HOSTS[0]}" --data-string "$DMR_CMD" > /dev/null 2>&1
        echo "  [DMR sw$((sw+1)) @ $(date +%T)] Comando enviado."
    ) &
    TRIGGER_PIDS+=($!)
done

# Monitor: actualiza PHASE_FILE cuando EpiGraph ejecuta cada Spawn DMR real
(
    sw=0
    while [ ! -f "$LOG_FILE" ]; do sleep 0.5; done
    while IFS= read -r line && [ "$sw" -lt 1 ]; do
        echo "$line" | grep -qE '^(Spawn|Remove) [0-9]+ at ' || continue
        echo "${PHASE_LABELS[$sw]}" > "$PHASE_FILE"
        echo "  [Monitor sw$((sw+1)) @ $(date +%T)] Fase -> ${PHASE_LABELS[$sw]}"
        sw=$((sw+1))
    done < <(tail -n +1 -f "$LOG_FILE" 2>/dev/null)
) &
MONITOR_PID=$!

# --- Ejecución única (sin checkpoint/restore) ---
echo "EXECUTION A" >> "$LOG_FILE"
T_GLOBAL_START=$(date +%s%N)

unset EPIGRAPH_CHECKPOINT EPIGRAPH_CHECKPOINTDAY EPIGRAPH_RESTORE EPIGRAPH_RESTOREDAY

set +e
run_epigraph $NUM_PROCS_INIT /shared/hostfile_dmr_init.txt
RC=$?
set -e

for pid in "${TRIGGER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

if [[ $RC -eq 0 || $RC -eq 255 ]]; then
    echo "✓ Ejecución DMR completada (RC=$RC)"
else
    echo "ERROR: epiGraph terminó con RC=$RC" >&2
    exit $RC
fi

T_TOTAL=$(( ($(date +%s%N) - T_GLOBAL_START) / 1000000 ))
echo ""
echo "  Tiempo total (DMR 1 switch d41): ${T_TOTAL} ms ($(( T_TOTAL / 1000 ))s)"

# =============================================================================
# PASO 5: XPN SHUTDOWN
# =============================================================================
cd /shared/install-src
echo ""
echo "=========================================="
echo "5. Apagando XPN..."
echo "=========================================="
rm -f "$PHASE_FILE"
if [ -n "${MONITOR_PID+x}" ]; then
    kill $MONITOR_PID 2>/dev/null || true
fi
if [ -n "${CONTROLLER_PID+x}" ]; then
    kill $CONTROLLER_PID 2>/dev/null || true
    echo "✓ Controlador FlexMPI detenido"
fi
$XPN_SCRIPT -w /shared -d /shared/xpn_nodes_ips.txt stop

echo ""
echo "=========================================="
echo "✅ Completado"
echo "=========================================="
echo "Log: $LOG_FILE"
echo "=========================================="
