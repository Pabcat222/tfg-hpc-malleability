#!/bin/bash

# =============================================================================
# lanza_xpn.sh
# EpiGraph CON XPN
# =============================================================================

set -e

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
XPN_SCRIPT="/home/lab/src/xpn/scripts/execute/xpn.sh"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"

SCRIPT_DIR="/home/pabcat/Escritorio/TFG/xpn-docker"
LOG_DIR="$EPIGRAPH_DIR/mis_logs"

# --- Configuración ---
# Tucán 3.5M: maleabilidad 8p→16p, switch en el inicio del pico epidémico (d41).
# (Nombres NUM_PROCS_4P/8P son históricos = fase A / fase B.)
NUM_PROCS_4P=8     # Fase A
NUM_PROCS_8P=16    # Fase B

# Día de checkpoint/switch (1-switch: expandir al arrancar la subida epidémica)
CHK_DAY_A=41    # Fase A→B: 8p días 1–41, 16p días 42–130

NUM_CHANGES=1

N_NODES=16
MAX_SLOTS_PER_NODE=12

# Modo XPN: "colocalizado" → todos los nodos son app+storage
#           "exclusivo"    → últimos N_XPN_NODES dedicados solo a XPN
XPN_MODE="colocalizado"
N_XPN_NODES=1

# --- XPN: partición virtual donde se escribe/lee el checkpoint binario
#     (StoreStructSingleFile / ReadStructSingleFile). El bypass solo intercepta
#     rutas bajo este prefijo; backend sck (mpi_server da SIGFPE con el bypass). ---
XPN_PREFIX="/tmp/expand/xpn"
XML_FILE="$EPIGRAPH_DIR/src/data/XMLConfigFile.xml"
export XPN_SCK_PORT=5555
# Días de simulación (forzado en el XML para no depender de estado dejado por
# lanza_xpn_validar.sh, que lo pone a 5 y puede no restaurarlo si se mata con kill -9).
SIM_DAYS=130

# Bypass parcheado (MPI_Init renombrado para no chocar con libempi). En /shared
# para que persista a reinicios de contenedor y esté visible en todos los nodos.
# Regenerarlo: ver xpn_bypass.c (sed 's/int MPI_Init (/int MPI_Init_DISABLED (/') + make.
BYPASS_SO="/shared/xpn_bypass_patched.so"

# Interruptor: USE_XPN=1 (def) corre con XPN/bypass; USE_XPN=0 = control NFS sin
# bypass (mismo flujo maleabilidad 4->8 + restore) para aislar si un cuelgue es
# de XPN o de FlexMPI/red.  Uso: USE_XPN=0 bash lanza_xpn.sh
USE_XPN="${USE_XPN:-1}"
XPN_TAG=$([ "$USE_XPN" = "1" ] && echo "xpn" || echo "noxpn")

# Log naming
LOG_NAME="001_${XPN_TAG}_mall_${N_NODES}n_${NUM_PROCS_4P}p${NUM_PROCS_8P}p_1sw_d${CHK_DAY_A}_1"
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
pkill -9 mpiexec 2>/dev/null || true
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

# =============================================================================
# FUNCIÓN: run_epigraph
# =============================================================================
run_epigraph() {
    local NP=$1
    local HOSTFILE=$2

    local ENV_PREFIX=""
    [ -n "${EPIGRAPH_CHECKPOINT+x}" ]    && ENV_PREFIX="$ENV_PREFIX EPIGRAPH_CHECKPOINT=$EPIGRAPH_CHECKPOINT"
    [ -n "${EPIGRAPH_CHECKPOINTDAY+x}" ] && ENV_PREFIX="$ENV_PREFIX EPIGRAPH_CHECKPOINTDAY=$EPIGRAPH_CHECKPOINTDAY"
    [ -n "${EPIGRAPH_RESTORE+x}" ]       && ENV_PREFIX="$ENV_PREFIX EPIGRAPH_RESTORE=$EPIGRAPH_RESTORE"
    [ -n "${EPIGRAPH_RESTOREDAY+x}" ]    && ENV_PREFIX="$ENV_PREFIX EPIGRAPH_RESTOREDAY=$EPIGRAPH_RESTOREDAY"

    echo "  Variables EPIGRAPH activas:${ENV_PREFIX:-ninguna}"

    local XPN_ENV=()
    if [ "$USE_XPN" = "1" ]; then
        XPN_ENV=(-genv XPN_CONF /shared/config.txt -genv XPN_LOCALITY 1 \
                 -genv XPN_SCK_PORT $XPN_SCK_PORT -genv LD_PRELOAD "$BYPASS_SO")
    fi

    env $ENV_PREFIX \
    $MPIEXEC -genvall \
        -np $NP \
        -hostfile "$HOSTFILE" \
        "${XPN_ENV[@]}" \
        -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
        -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
        -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
        -genv LIBPFM_FORCE_PMU icx \
        ./epiGraph random "" \
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
# FUNCIÓN: restart_controller
# =============================================================================
restart_controller() {
    if [ -n "${CONTROLLER_PID+x}" ] && kill -0 $CONTROLLER_PID 2>/dev/null; then
        kill $CONTROLLER_PID 2>/dev/null || true
        sleep 1
    fi
    cd "$CONTROLLER_DIR"
    ./controller &
    CONTROLLER_PID=$!
    cd - > /dev/null
    sleep 2
    echo "  ✓ Controlador reiniciado (PID $CONTROLLER_PID)"
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

if [ "$XPN_MODE" = "exclusivo" ]; then
    N_APP_NODES=$((N_NODES - N_XPN_NODES))
else
    N_APP_NODES=$N_NODES
fi

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

        if [ "$XPN_MODE" != "exclusivo" ] || [ $_node_idx -lt $N_APP_NODES ]; then
            echo "${REAL_HOST}:${MAX_SLOTS_PER_NODE}:${REAL_HOST}:100:5000" >> /shared/nodefile2.dat
            echo "${REAL_HOST}:1:${REAL_HOST}" >> /shared/nodefile.dat
        fi
        _node_idx=$((_node_idx + 1))
    fi
done < /work/machines_mpi

while IFS= read -r ip; do
    [ -n "$ip" ] && cat /shared/global_hosts.txt | ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "sudo tee -a /etc/hosts > /dev/null"
done < /work/machines_mpi

cp /work/machines_mpi /shared/xpn_machines_ips.txt

# Generar hostfiles de nodos XPN y app según modo
if [ "$XPN_MODE" = "exclusivo" ]; then
    head -n $N_APP_NODES /work/machines_mpi > /shared/app_nodes_ips.txt
    tail -n $N_XPN_NODES /work/machines_mpi > /shared/xpn_nodes_ips.txt
    NUM_PROCS_4P=$N_APP_NODES
    NUM_PROCS_8P=$N_APP_NODES
    echo "✓ Modo EXCLUSIVO: ${N_APP_NODES} nodos app + ${N_XPN_NODES} nodos XPN dedicados"
else
    cp /work/machines_mpi /shared/xpn_nodes_ips.txt
    echo "✓ Modo COLOCALIZADO: ${N_NODES} nodos app+XPN"
fi

# Crear hostfiles para configuraciones 4p y 8p (round-robin)
for ((i=0; i<NUM_PROCS_4P; i++)); do echo "${ALL_HOSTS[$((i % N_NODES))]}:1"; done > /shared/hostfile_4p.txt
for ((i=0; i<NUM_PROCS_8P; i++)); do echo "${ALL_HOSTS[$((i % N_NODES))]}:1"; done > /shared/hostfile_8p.txt

head -n $NUM_PROCS_4P /shared/global_hosts.txt | awk '{print $2}' > $EPIGRAPH_DIR/data2start_hostfile
head -n $NUM_PROCS_8P /shared/global_hosts.txt | awk '{print $2}' > $EPIGRAPH_DIR/data2change_hostfile

mkdir -p "$EPIGRAPH_DIR/output"

# Nodo controlador (primer nodo por defecto; ajustar si se activa maleabilidad real)
CTRL_NODE="${ALL_HOSTS[0]}"

echo "✓ $N_NODES hostnames únicos"

# =============================================================================
# PASO 2: XPN
# =============================================================================
echo ""
echo "=========================================="
echo "2. Iniciando XPN..."
echo "=========================================="
# Backup + restauración del XML pase lo que pase
cp -f "$XML_FILE" "${XML_FILE}.bak_xpn"
restore_xml() { [ -f "${XML_FILE}.bak_xpn" ] && mv -f "${XML_FILE}.bak_xpn" "$XML_FILE" && echo "✓ XML restaurado"; }
trap restore_xml EXIT
sed -i 's#SimDays\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#SimDays\1=\2"'"$SIM_DAYS"'"#' "$XML_FILE"

if [ "$USE_XPN" = "1" ]; then
    XPN_N=$( [ "$XPN_MODE" = "exclusivo" ] && echo $N_XPN_NODES || echo $N_NODES )
    $XPN_SCRIPT -e sck -w /shared -l /shared/xpn_nodes_ips.txt -x /tmp/ -n $XPN_N start
    sleep 5
    # Apuntar la E/S de estructura (checkpoint binario) a la partición XPN.
    sed -i 's#PathStructure\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#PathStructure\1=\2"'"$XPN_PREFIX"'/struct/"#' "$XML_FILE"
    echo "✓ XML PathStructure -> $XPN_PREFIX/struct/ ; SimDays -> $SIM_DAYS"
    grep -E "PathDest|PathStructure|SimDays" "$XML_FILE"
    # Crear los directorios de la partición XPN (vía bypass) antes de ejecutar
    $MPIEXEC -np 1 -hostfile /shared/hostfile_4p.txt \
        -genv XPN_CONF /shared/config.txt -genv XPN_LOCALITY 1 -genv XPN_SCK_PORT $XPN_SCK_PORT \
        -genv LD_PRELOAD "$BYPASS_SO" -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
        perl -e "mkdir('$XPN_PREFIX/struct'); mkdir('$XPN_PREFIX/struct/output');" || true
    echo "✓ Directorios de la partición XPN creados ($XPN_PREFIX/struct/output)"
else
    echo "2. (USE_XPN=0) CONTROL SIN XPN — E/S a NFS, sin bypass"
    sed -i 's#PathStructure\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#PathStructure\1=\2"."#' "$XML_FILE"
    echo "✓ XML PathStructure -> . (NFS) ; SimDays -> $SIM_DAYS"
    grep -E "PathDest|PathStructure|SimDays" "$XML_FILE"
fi

# =============================================================================
# PASO 2.5: CPU STATS
# =============================================================================
CPU_STATS_FILE="$LOG_DIR/cpu_stats.tsv"
IO_STATS_FILE="$LOG_DIR/io_stats.tsv"
> "$CPU_STATS_FILE"
> "$IO_STATS_FILE"
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
echo "✓ workload.dat regenerado con hostnames actuales: ${ALL_HOSTS[*]}"

cd "$CONTROLLER_DIR"
./controller &
CONTROLLER_PID=$!
cd - > /dev/null
sleep 2

echo "✓ Controlador FlexMPI arrancado (PID $CONTROLLER_PID, nodo: $CTRL_NODE)"

# =============================================================================
# PASO 3: EJECUCIÓN — Maleabilidad 2 fases (1 switch)
# Estrategia: 4p(1-20) → 8p(21-130)
# =============================================================================
cd "$EPIGRAPH_DIR"

echo ""
echo "=========================================="
echo "3. Ejecución — Maleabilidad 2 fases (1 switch)"
echo "=========================================="

# Helper: ejecuta run_epigraph tolerando exit(2) de checkpoint
run_phase() {
    local LABEL=$1
    local NP=$2
    local HOSTFILE=$3
    echo "***************************************"
    echo "FASE $LABEL — $NP procesos"
    echo "***************************************"
    echo "EXECUTION $LABEL" >> "$LOG_FILE"
    set +e
    run_epigraph $NP "$HOSTFILE"
    local RC=$?
    set -e
    if [[ $RC -eq 2 || $RC -eq 255 ]]; then
        echo "  ✓ Fase $LABEL completada (checkpoint guardado, mpiexec RC=$RC)"
    elif [[ $RC -eq 0 ]]; then
        echo "  ✓ Fase $LABEL completada (fin de simulación)"
    else
        echo "ERROR: Fase $LABEL falló con código $RC" >&2
        exit $RC
    fi
}

T_GLOBAL_START=$(date +%s%N)

# --- FASE A: 4p, días 1–20, guarda checkpoint en día 20 ---
echo "A" > "$PHASE_FILE"
unset EPIGRAPH_RESTORE EPIGRAPH_RESTOREDAY
export EPIGRAPH_CHECKPOINT=1
export EPIGRAPH_CHECKPOINTDAY=$CHK_DAY_A
T_A=$(date +%s%N)
run_phase "A" $NUM_PROCS_4P /shared/hostfile_4p.txt
echo "  Tiempo Fase A: $(( ($(date +%s%N) - T_A) / 1000000 )) ms"

restart_controller

# --- FASE B: 8p, días 21–130, restaura día 20, fin de simulación ---
echo "B" > "$PHASE_FILE"
export EPIGRAPH_RESTORE=1
export EPIGRAPH_RESTOREDAY=$CHK_DAY_A
unset EPIGRAPH_CHECKPOINT EPIGRAPH_CHECKPOINTDAY
T_B=$(date +%s%N)
run_phase "B" $NUM_PROCS_8P /shared/hostfile_8p.txt
echo "  Tiempo Fase B: $(( ($(date +%s%N) - T_B) / 1000000 )) ms"

T_TOTAL=$(( ($(date +%s%N) - T_GLOBAL_START) / 1000000 ))
echo ""
echo "  Tiempo total (2 fases + 1 switch): ${T_TOTAL} ms ($(( T_TOTAL / 1000 ))s)"

# =============================================================================
# PASO 4.5: VERIFICACIÓN DE INTERCEPTACIÓN XPN
# =============================================================================
if [ "$USE_XPN" = "1" ]; then
echo ""
echo "=========================================="
echo "4.5 ¿XPN interceptó el checkpoint?"
echo "=========================================="
echo "--- struct en el storage físico XPN (/tmp/struct) por nodo XPN ---"
while IFS= read -r ip; do
    [ -n "$ip" ] && { echo "[$ip]"; ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "find /tmp/struct -maxdepth 3 2>/dev/null | head"; }
done < /shared/xpn_nodes_ips.txt
echo "--- (control) ¿quedó algo en la ruta NFS de output? (debería estar vacío) ---"
find "$EPIGRAPH_DIR/output" -iname '*tPersonalInfo*' -o -iname '*Struct*' 2>/dev/null | head
fi

# =============================================================================
# PASO 5: XPN SHUTDOWN
# =============================================================================
cd /shared/install-src
echo ""
echo "=========================================="
echo "5. Apagando XPN..."
echo "=========================================="
rm -f "$PHASE_FILE"
if [ -n "${CONTROLLER_PID+x}" ]; then
    kill $CONTROLLER_PID 2>/dev/null || true
    echo "✓ Controlador FlexMPI detenido"
fi
[ "$USE_XPN" = "1" ] && $XPN_SCRIPT -e sck -w /shared -d /shared/xpn_nodes_ips.txt stop

echo ""
echo "=========================================="
echo "✅ Completado"
echo "=========================================="
echo "Log: $LOG_FILE"
echo "=========================================="
