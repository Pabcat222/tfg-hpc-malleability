#!/bin/bash

# =============================================================================
# lanza_xpn_sin_flexmpi.sh
# EpiGraph CON XPN, SIN load balancing FlexMPI (-lbpolicy-disabled)
# Sirve de baseline para cuantificar el beneficio del rebalanceo.
# Ejecutar desde DENTRO del contenedor principal
# =============================================================================

set -e

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
XPN_SCRIPT="/home/lab/src/xpn/scripts/execute/xpn.sh"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"
CONTROLLER_DIR="$FLEXMPI_DIR/controller"

SCRIPT_DIR="/home/pabcat/Escritorio/TFG/xpn-docker"
LOG_DIR="$EPIGRAPH_DIR/mis_logs"

# Número de procesos: argumento obligatorio
if [ -z "$1" ]; then
    echo "Uso: $0 <num_procesos>"
    echo "Ejemplo: $0 8"
    exit 1
fi
NUM_PROCS=$1

# 1 contenedor = 1 proceso MPI → tantos servidores XPN (colocalizado) como procesos
N_NODES=$NUM_PROCS
MAX_SLOTS_PER_NODE=12

# PMU para libpfm4: Tucán (Xeon Ice Lake)=icx, portátil (Alder Lake)=adl_glc
if lscpu 2>/dev/null | grep -qi "Xeon"; then PMU=icx; else PMU=adl_glc; fi

XPN_PREFIX="/tmp/expand/xpn"
XML_FILE="$EPIGRAPH_DIR/src/data/XMLConfigFile.xml"
export XPN_SCK_PORT=5555
SIM_DAYS=130
BYPASS_SO="/shared/xpn_bypass_patched.so"

LOG_NAME="001_xpn_stat_${N_NODES}n_${NUM_PROCS}p_nolb_1"
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
export LIBPFM_FORCE_PMU=$PMU
export PAPI_EVENTS_FILE=/shared/papi-install/share/papi/papi_events.csv

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
    fi
done < /work/machines_mpi

while IFS= read -r ip; do
    [ -n "$ip" ] && cat /shared/global_hosts.txt | ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "sudo tee -a /etc/hosts > /dev/null"
done < /work/machines_mpi

# Colocalizado: recortar a los primeros NUM_PROCS nodos (no copiar toda la lista).
# Con un clúster de más nodos que NUM_PROCS, pasar la lista entera con -n NUM_PROCS
# hace que XPN intente resolver servidores inexistentes y aborte (xpn_init error).
head -n $NUM_PROCS /work/machines_mpi > /shared/xpn_machines_ips.txt

# Hostfile con los primeros NUM_PROCS nodos
for ((i=0; i<NUM_PROCS; i++)); do echo "${ALL_HOSTS[$i]}:1"; done > /shared/hostfile_nolb.txt
head -n $NUM_PROCS /shared/global_hosts.txt | awk '{print $2}' > $EPIGRAPH_DIR/data2start_hostfile

mkdir -p "$EPIGRAPH_DIR/output"

CTRL_NODE="${ALL_HOSTS[0]}"
echo "✓ $N_NODES hostnames únicos"
echo "  Hostfile:"
cat /shared/hostfile_nolb.txt | sed 's/^/    /'
echo "  Controller: $CTRL_NODE"

# =============================================================================
# PASO 2: XPN
# =============================================================================
echo ""
echo "=========================================="
echo "2. Iniciando XPN..."
echo "=========================================="
cp -f "$XML_FILE" "${XML_FILE}.bak_xpn"
restore_xml() { [ -f "${XML_FILE}.bak_xpn" ] && mv -f "${XML_FILE}.bak_xpn" "$XML_FILE" && echo "✓ XML restaurado"; }
trap restore_xml EXIT
sed -i 's#SimDays\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#SimDays\1=\2"'"$SIM_DAYS"'"#' "$XML_FILE"

$XPN_SCRIPT -e sck -w /shared -l /shared/xpn_machines_ips.txt -x /tmp/ -n $N_NODES start
sleep 5

# xpn.sh start REGENERA /shared/config.txt con un bsize por defecto. Para usar
# otro tamaño de bloque hay que reescribirlo AQUÍ (post-start, antes del mpiexec).
if [ -n "${XPN_BSIZE:-}" ]; then
    sed -i -E "s/^[[:space:]]*bsize[[:space:]]*=.*/bsize = ${XPN_BSIZE}/" /shared/config.txt
    echo "✓ bsize fijado a ${XPN_BSIZE} (post-start):" | tee -a "$LOG_FILE"
    grep -E "^[[:space:]]*bsize" /shared/config.txt | tee -a "$LOG_FILE"
fi

sed -i 's#PathStructure\([[:space:]]*\)=\([[:space:]]*\)"[^"]*"#PathStructure\1=\2"'"$XPN_PREFIX"'/struct/"#' "$XML_FILE"
echo "✓ XML PathStructure -> $XPN_PREFIX/struct/ ; SimDays -> $SIM_DAYS"
grep -E "PathDest|PathStructure|SimDays" "$XML_FILE"
$MPIEXEC -np 1 -hostfile /shared/hostfile_nolb.txt \
    -genv XPN_CONF /shared/config.txt -genv XPN_LOCALITY 1 -genv XPN_SCK_PORT $XPN_SCK_PORT \
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
# (EpiGraph necesita conectarse al controlador al arrancar incluso con
#  -lbpolicy-disabled. El controlador arranca pero no redistribuye nada.)
# =============================================================================
echo ""
echo "=========================================="
echo "2.7 Iniciando controlador FlexMPI (sin LB)..."
echo "=========================================="

echo "$CTRL_NODE" > "$CONTROLLER_DIR/controller.dat"
mkdir -p "$CONTROLLER_DIR/../run"
cp /shared/nodefile2.dat "$CONTROLLER_DIR/../run/nodefile2.dat"

WORKLOAD_LINE="epigraph:0:0:0:0:0.000000:93600"
for ((i=0; i<NUM_PROCS; i++)); do
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
# PASO 3: EJECUCIÓN — Estática SIN load balancing
# =============================================================================
cd "$EPIGRAPH_DIR"

echo ""
echo "=========================================="
echo "3. Ejecutando EpiGraph SIN load balancing (-lbpolicy-disabled)..."
echo "=========================================="

echo "EXECUTION A" >> "$LOG_FILE"

$MPIEXEC -genvall \
    -np $NUM_PROCS \
    -hostfile /shared/hostfile_nolb.txt \
    -genv XPN_CONF /shared/config.txt \
    -genv XPN_LOCALITY 1 \
    -genv XPN_SCK_PORT $XPN_SCK_PORT \
    -genv LD_PRELOAD "$BYPASS_SO" \
    -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
    -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
    -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
    -genv LIBPFM_FORCE_PMU $PMU \
    -genv PAPI_EVENTS_FILE /shared/papi-install/share/papi/papi_events.csv \
    ./epiGraph random "" \
    -cfile /shared/nodefile2.dat \
    -policy-malleability-triggered \
    -lbpolicy-disabled \
    -ni 1440 \
    -nilb 144 \
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
echo "--- struct en el storage físico XPN (/tmp/struct) por nodo ---"
while IFS= read -r ip; do
    [ -n "$ip" ] && { echo "[$ip]"; ssh -q -n -o StrictHostKeyChecking=no "$ip" \
        "find /tmp/struct -maxdepth 3 2>/dev/null | head"; }
done < /shared/xpn_machines_ips.txt
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
$XPN_SCRIPT -e sck -w /shared -d /shared/xpn_machines_ips.txt stop

echo ""
echo "=========================================="
echo "✅ Completado — EpiGraph XPN sin FlexMPI LB"
echo "   Log: $LOG_FILE"
echo "=========================================="
