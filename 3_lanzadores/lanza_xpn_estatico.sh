#!/bin/bash

# =============================================================================
# lanza_xpn_estatico.sh
# EpiGraph CON XPN + FlexMPI LB, SIN malleabilidad — baseline estático con XPN
# Ejecutar desde DENTRO del contenedor principal
# =============================================================================

set -e

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
XPN_SCRIPT="/home/lab/src/xpn/scripts/execute/xpn.sh"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"
CONTROLLER_DIR="$FLEXMPI_DIR/controller"

LOG_DIR="$EPIGRAPH_DIR/mis_logs"

# Argumentos:
#   $1 num_procesos  — procesos EpiGraph (obligatorio)
#   $2 n_xpn_nodes   — nodos dedicados solo a XPN (opcional, default 0 = colocalizado)
if [ -z "$1" ]; then
    echo "Uso: $0 <num_procesos> [n_xpn_nodes]"
    echo "Ejemplo colocalizado: $0 16"
    echo "Ejemplo exclusivo:    $0 16 2   # 16 cómputo + 2 XPN dedicados"
    exit 1
fi
NUM_PROCS=$1
N_XPN_NODES=${2:-0}

N_APP_NODES=$NUM_PROCS
N_TOTAL_NODES=$(wc -l < /work/machines_mpi)
MAX_SLOTS_PER_NODE=12

# --- XPN: integración real (igual que lanza_xpn.sh) ---
XPN_PREFIX="/tmp/expand/xpn"
XML_FILE="$EPIGRAPH_DIR/src/data/XMLConfigFile.xml"
export XPN_SCK_PORT=5555
SIM_DAYS=${SIM_DAYS:-130}          # overridable: test corto de validacion sin gastar un run entero
BYPASS_SO="/shared/xpn_bypass_patched.so"   # parcheado (MPI_Init->DISABLED), en /shared

# --- Overrides para el control de CE4 (defaults = campana historica) ---
# NILB gobierna DOS cosas a la vez (epidemiology_sync.c:340 y :403): la cadencia del
# volcado de estado y la del monitor del balanceador. 144 = 10 volcados/dia (campana de
# Tucan); 1440 = 1 volcado/dia (campana antigua del portatil).
NILB=${NILB:-144}
# counts = LB activo por conteo de columnas; disabled = sin rebalanceo.
LBPOLICY=${LBPOLICY:-counts}

if [ "$N_XPN_NODES" -gt 0 ]; then
    XPN_MODE="exclusivo"
    if [ "$N_TOTAL_NODES" -lt $(( N_APP_NODES + N_XPN_NODES )) ]; then
        echo "ERROR: machines_mpi tiene $N_TOTAL_NODES entradas, se necesitan al menos $((N_APP_NODES + N_XPN_NODES)) (${N_APP_NODES} cómputo + ${N_XPN_NODES} XPN)"
        exit 1
    fi
    LOG_NAME="001_xpn_estatico_excl_${N_APP_NODES}app_${N_XPN_NODES}xpn_${NUM_PROCS}p"
else
    XPN_MODE="colocalizado"
    LOG_NAME="001_xpn_estatico_${N_APP_NODES}n_${NUM_PROCS}p"
fi

# Etiqueta opcional para no colisionar con campanas anteriores que usan el mismo
# N_APP/N_XPN (p.ej. LOG_TAG=dist para la topologia distribuida entre los dos nodos).
LOG_NAME="${LOG_NAME}${LOG_TAG:+_$LOG_TAG}"

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

# Traza de la configuracion variable, para que el log sea autodescriptivo
_POP=$(grep -o 'PopSize[^"]*"[0-9]*' "$EPIGRAPH_DIR/src/data/XMLGraphConfigFile.xml" 2>/dev/null | grep -o '[0-9]*$' || true)
_CITIES=$(basename "$(readlink -f "$EPIGRAPH_DIR/cities" 2>/dev/null || echo desconocido)")
echo "### CONFIG: nilb=$NILB lbpolicy=$LBPOLICY PopSize=${_POP:-?} cities=$_CITIES" | tee "$LOG_FILE"
rm -f "$LOG_DIR/cpu_stats.tsv" "$LOG_DIR/io_stats.tsv"
rm -f "$EPIGRAPH_DIR/output/"* 2>/dev/null || true
rm -f /tmp/epigraph_current_phase
pkill -9 epiGraph   2>/dev/null || true
pkill -9 mpiexec    2>/dev/null || true
pkill -9 controller 2>/dev/null || true
sleep 1
echo "✓ Limpieza completada"

# =============================================================================
# CONFIGURACIÓN DE ENTORNO
# =============================================================================
export MY_LD_LIB=$LD_LIBRARY_PATH:$FLEXMPI_DIR/lib:/home/lab/bin/mpich/lib:/shared/papi-install/lib:/shared/libpfm4-install/lib
export FI_PROVIDER=sockets
export PATH=/home/lab/bin/mpich/bin:$PATH
export LIBPFM_FORCE_PMU=icx
export PAPI_EVENTS_FILE=/shared/papi-install/share/papi/papi_events.csv
unset MOUNT_POINT

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

        # En modo exclusivo los últimos N_XPN_NODES nodos no participan en el cómputo
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

# Ficheros de máquinas según modo
if [ "$XPN_MODE" = "exclusivo" ]; then
    head -n $N_APP_NODES /work/machines_mpi > /shared/app_nodes_ips.txt
    tail -n $N_XPN_NODES /work/machines_mpi > /shared/xpn_nodes_ips.txt
    echo "✓ Modo EXCLUSIVO: ${N_APP_NODES} nodos cómputo + ${N_XPN_NODES} nodos XPN dedicados"
else
    # Colocalizado: servidores XPN en los MISMOS primeros N_APP_NODES nodos de
    # cómputo. Hay que recortar (no copiar toda la lista): si el clúster tiene
    # más nodos que N_APP_NODES, pasar la lista completa con -n N_APP_NODES hace
    # que el cliente intente resolver servidores que no existen y XPN aborta.
    head -n $N_APP_NODES /work/machines_mpi > /shared/xpn_nodes_ips.txt
    echo "✓ Modo COLOCALIZADO: ${N_APP_NODES} nodos cómputo+XPN"
fi

# Hostfile EpiGraph: solo los primeros N_APP_NODES nodos
for ((i=0; i<N_APP_NODES; i++)); do echo "${ALL_HOSTS[$i]}:1"; done > /shared/hostfile_estatico.txt
head -n $N_APP_NODES /shared/global_hosts.txt | awk '{print $2}' > $EPIGRAPH_DIR/data2start_hostfile

mkdir -p "$EPIGRAPH_DIR/output"

CTRL_NODE="${ALL_HOSTS[0]}"
echo "  Hostfile cómputo:"
cat /shared/hostfile_estatico.txt | sed 's/^/    /'
if [ "$XPN_MODE" = "exclusivo" ]; then
    echo "  Nodos XPN dedicados:"
    cat /shared/xpn_nodes_ips.txt | sed 's/^/    /'
fi
echo "  Controller: $CTRL_NODE"

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

XPN_N=$( [ "$XPN_MODE" = "exclusivo" ] && echo $N_XPN_NODES || echo $N_APP_NODES )
# Locality: en colocalizado cada rank tiene servidor XPN local (=1, óptimo). En
# EXCLUSIVO no hay servidor colocalizado -> locality=1 rompe el MPI_File_open
# (WRONLY|CREATE) de MPI-IO/ADIO-PVFS (abort 911 en el 1er checkpoint). =0 lo arregla.
# Overridable: en la topologia DISTRIBUIDA (app y servidores XPN en AMBOS nodos) si hay
# servidor en el mismo nodo fisico, asi que locality=1 vuelve a tener sentido en exclusivo
# y es justo el mecanismo que permitiria esquivar la red. Ver H3 de la campana distribuida.
XPN_LOC=${XPN_LOC:-$( [ "$XPN_MODE" = "exclusivo" ] && echo 0 || echo 1 )}
# Limpiar el storage de los servidores XPN antes de arrancar: si queda un fichero
# de un run anterior con MÁS servidores, su metadato data_nserv[0] (nº servidores
# al crearlo) es mayor que el num_servers actual -> XpnCalculateBlockMdata devuelve
# serv fuera de rango -> io[serv] desborda la matriz (num_servers filas) -> SIGSEGV
# en XpnWriteBlocksBlockByBlock (xpn_policy_rw.c:498). Ver CAMBIOS_FLEXMPI.md.
while IFS= read -r __ip; do
    [ -n "$__ip" ] && ssh -n -o StrictHostKeyChecking=no "$__ip" "rm -rf /tmp/struct /tmp/expand" 2>/dev/null
done < /shared/xpn_nodes_ips.txt
echo "✓ Storage XPN limpiado en los servidores (evita metadato obsoleto data_nserv)"
$XPN_SCRIPT -e sck -w /shared -l /shared/xpn_nodes_ips.txt -x /tmp/ -n $XPN_N start
sleep 5

# xpn.sh start REGENERA /shared/config.txt (con las IPs reales de los servidores)
# y un bsize por defecto. Si se quiere otro tamaño de bloque hay que reescribirlo
# AQUÍ (después de start, antes del mpiexec); editarlo antes de start no sirve.
if [ -n "${XPN_BSIZE:-}" ]; then
    sed -i -E "s/^[[:space:]]*bsize[[:space:]]*=.*/bsize = ${XPN_BSIZE}/" /shared/config.txt
    echo "✓ bsize fijado a ${XPN_BSIZE} (post-start):" | tee -a "$LOG_FILE"
    grep -E "^[[:space:]]*bsize" /shared/config.txt | tee -a "$LOG_FILE"
fi

# Apuntar la E/S de estructura (tPersonalInfo.dat, escrito cada nilb iters por
# StoreStructSingleFile aun sin checkpoint) a la partición XPN. El bypass solo
# intercepta rutas bajo este prefijo; backend sck (mpi_server da SIGFPE con el bypass).
sed -i 's#PathStructure\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#PathStructure\1=\2"'"$XPN_PREFIX"'/struct/"#' "$XML_FILE"
echo "✓ XML PathStructure -> $XPN_PREFIX/struct/ ; SimDays -> $SIM_DAYS"
grep -E "PathDest|PathStructure|SimDays" "$XML_FILE"
# Crear los directorios de la partición XPN (vía bypass) antes de ejecutar
$MPIEXEC -np 1 -hostfile /shared/hostfile_estatico.txt \
    -genv XPN_CONF /shared/config.txt -genv XPN_LOCALITY $XPN_LOC -genv XPN_SCK_PORT $XPN_SCK_PORT \
    -genv LD_PRELOAD "$BYPASS_SO" -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
    perl -e "mkdir('$XPN_PREFIX/struct'); mkdir('$XPN_PREFIX/struct/output');" || true
echo "✓ Directorios de la partición XPN creados ($XPN_PREFIX/struct/output)"

# =============================================================================
# PASO 2.5: CPU/IO STATS
# =============================================================================
CPU_STATS_FILE="$LOG_DIR/cpu_stats.tsv"
IO_STATS_FILE="$LOG_DIR/io_stats.tsv"
> "$CPU_STATS_FILE"
> "$IO_STATS_FILE"
echo -e "timestamp\tphase\thostname\tcpu_percent"      >> "$CPU_STATS_FILE"
echo -e "timestamp\tphase\thostname\tio_read_bytes\tio_write_bytes" >> "$IO_STATS_FILE"
chmod 666 "$CPU_STATS_FILE" "$IO_STATS_FILE"

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

cd "$CONTROLLER_DIR"
./controller &
CONTROLLER_PID=$!
cd - > /dev/null
sleep 2

echo "✓ Controlador FlexMPI arrancado (PID $CONTROLLER_PID)"

# =============================================================================
# PASO 3: EJECUCIÓN
# =============================================================================
cd "$EPIGRAPH_DIR"

echo ""
echo "=========================================="
echo "3. Ejecutando EpiGraph CON XPN + FlexMPI LB..."
echo "=========================================="

echo "EXECUTION A" >> "$LOG_FILE"

$MPIEXEC -genvall \
    -np $NUM_PROCS \
    -hostfile /shared/hostfile_estatico.txt \
    -genv XPN_CONF /shared/config.txt \
    -genv XPN_LOCALITY $XPN_LOC \
    -genv XPN_SCK_PORT $XPN_SCK_PORT \
    -genv LD_PRELOAD "$BYPASS_SO" \
    -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
    -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
    -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
    -genv LIBPFM_FORCE_PMU icx \
    -genv PAPI_EVENTS_FILE /shared/papi-install/share/papi/papi_events.csv \
    ./epiGraph random "" \
    -cfile /shared/nodefile2.dat \
    -policy-malleability-triggered \
    -lbpolicy-$LBPOLICY \
    -ni 1440 \
    -nilb $NILB \
    -ports 6668 6669 \
    -controller "$CTRL_NODE" \
    -IOaction 0 2>&1 | tee -a "$LOG_FILE"

# =============================================================================
# PASO 3.5: VERIFICACIÓN DE INTERCEPTACIÓN XPN
# =============================================================================
echo ""
echo "=========================================="
echo "3.5 ¿XPN interceptó la E/S de estructura?"
echo "=========================================="
echo "--- struct en el storage físico XPN (/tmp/struct) por nodo XPN ---"
while IFS= read -r ip; do
    [ -n "$ip" ] && { echo "[$ip]"; ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "find /tmp/struct -maxdepth 3 2>/dev/null | head"; }
done < /shared/xpn_nodes_ips.txt
echo "--- (control) ¿quedó algo en la ruta NFS de output? (debería estar vacío) ---"
find "$EPIGRAPH_DIR/output" -iname '*tPersonalInfo*' -o -iname '*Struct*' 2>/dev/null | head

# =============================================================================
# PASO 4: APAGADO
# =============================================================================
cd /shared/install-src

rm -f "$PHASE_FILE"
if [ -n "${CONTROLLER_PID+x}" ]; then
    kill $CONTROLLER_PID 2>/dev/null || true
    echo "✓ Controlador FlexMPI detenido"
fi

echo ""
echo "=========================================="
echo "5. Apagando XPN..."
echo "=========================================="
$XPN_SCRIPT -e sck -w /shared -d /shared/xpn_nodes_ips.txt stop
# xpn_server puede quedarse en bucle de EOF cuando EpiGraph termina con crash;
# lo matamos por la fuerza en todos los nodos XPN.
while IFS= read -r node_ip; do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$node_ip" \
        "pkill -9 xpn_server 2>/dev/null; true" &
done < /shared/xpn_nodes_ips.txt
wait

echo ""
echo "=========================================="
echo "✅ Completado — EpiGraph XPN + FlexMPI LB estático"
echo "   Log: $LOG_FILE"
echo "=========================================="
