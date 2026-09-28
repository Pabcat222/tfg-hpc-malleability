#!/bin/bash

# =============================================================================
# lanza_xpn_sin_expand.sh
# EpiGraph SIN Expand — baseline estático
# Ejecutar desde DENTRO del contenedor principal
# =============================================================================

set -e

FLEXMPI_DIR="/shared/install-src/FlexMPIDeveloper"
EPIGRAPH_DIR="/shared/install-src/EpiGraphFlexMPI-XPN"
CONTROLLER_DIR="$FLEXMPI_DIR/controller"
MPIEXEC="/home/lab/bin/mpich/bin/mpiexec"

# Número de procesos: argumento obligatorio
if [ -z "$1" ]; then
    echo "Uso: $0 <num_procesos>"
    echo "Ejemplo: $0 8"
    exit 1
fi
NUM_PROCS=$1

LOG_DIR="$EPIGRAPH_DIR/mis_logs"
N_NODES=$NUM_PROCS
MAX_SLOTS_PER_NODE=12
LOG_NAME="001_epigraph_sin_expand_${N_NODES}n_${NUM_PROCS}p"
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
rm -f "$EPIGRAPH_DIR/output/"* 2>/dev/null || true
rm -f "$LOG_DIR/cpu_stats.tsv" "$LOG_DIR/io_stats.tsv"
pkill -9 epiGraph 2>/dev/null || true
pkill -9 mpiexec  2>/dev/null || true
sleep 1
echo "✓ Limpieza completada"

# =============================================================================
# PASO 1: SSH + DNS + HOSTFILES (igual que lanza_xpn.sh)
# =============================================================================
echo ""
echo "=========================================="
echo "1. SSH, DNS y hostfiles..."
echo "=========================================="

if ! command -v sshpass &>/dev/null; then
    sudo apt-get install -y -q sshpass
fi

rm -f /shared/ssh_authorized_keys_all
> /shared/ssh_authorized_keys_all

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

rm -f /shared/nodefile*.dat /shared/hostfile_fase*.txt
> /shared/global_hosts.txt
CONTROLLER_NAME=$(hostname)
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
            "pkill -9 epiGraph 2>/dev/null; pkill -9 hydra 2>/dev/null; true"
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

# Crear hostfile con los primeros NUM_PROCS nodos
for ((i=0; i<NUM_PROCS; i++)); do echo "${ALL_HOSTS[$i]}:1"; done > /shared/hostfile_sin_expand.txt

head -n $NUM_PROCS /shared/global_hosts.txt | awk '{print $2}' > $EPIGRAPH_DIR/data2start_hostfile

mkdir -p "$EPIGRAPH_DIR/output"

echo "✓ $N_NODES hostnames únicos"
echo "  Hostfile:"
cat /shared/hostfile_sin_expand.txt | sed 's/^/    /'
echo "  Controller: $CONTROLLER_NAME"

# =============================================================================
# PASO 1.5: CONTROLADOR FLEXMPI
# =============================================================================
echo ""
echo "=========================================="
echo "1.5 Iniciando controlador FlexMPI..."
echo "=========================================="

echo "$CONTROLLER_NAME" > "$CONTROLLER_DIR/controller.dat"

mkdir -p "$CONTROLLER_DIR/../run"
cp /shared/nodefile2.dat "$CONTROLLER_DIR/../run/nodefile2.dat"

WORKLOAD_LINE="epigraph:0:0:0:0:0.000000:93600"
for ((i=0; i<NUM_PROCS; i++)); do
    WORKLOAD_LINE="${WORKLOAD_LINE}:${ALL_HOSTS[$i]}:1"
done
echo "$WORKLOAD_LINE" > "$CONTROLLER_DIR/workload.dat"
echo "✓ workload.dat: $WORKLOAD_LINE"

cd "$CONTROLLER_DIR"
./controller &
CONTROLLER_PID=$!
cd -
sleep 2

echo "✓ Controlador FlexMPI arrancado (PID $CONTROLLER_PID)"

# =============================================================================
# PASO 2: EJECUCIÓN (SIN XPN)
# =============================================================================
echo ""
echo "=========================================="
echo "2. Ejecutando EpiGraph SIN Expand..."
echo "=========================================="

export MY_LD_LIB=$LD_LIBRARY_PATH:$FLEXMPI_DIR/lib:/home/lab/bin/mpich/lib:/shared/papi-install/lib:/shared/libpfm4-install/lib
export FI_PROVIDER=sockets
export PATH=/home/lab/bin/mpich/bin:$PATH
export LIBPFM_FORCE_PMU=icx
export PAPI_EVENTS_FILE=/shared/papi-install/share/papi/papi_events.csv
unset MOUNT_POINT

cd "$EPIGRAPH_DIR"

PHASE_FILE="/tmp/epigraph_current_phase"
echo "A" > "$PHASE_FILE"

echo -e "timestamp\tphase\thostname\tcpu_percent" >> "$LOG_DIR/cpu_stats.tsv"
echo -e "timestamp\tphase\thostname\tio_read_bytes\tio_write_bytes" >> "$LOG_DIR/io_stats.tsv"
chmod 666 "$LOG_DIR/cpu_stats.tsv" "$LOG_DIR/io_stats.tsv"

$MPIEXEC -genvall \
    -np $NUM_PROCS \
    -hostfile /shared/hostfile_sin_expand.txt \
    -genv LD_LIBRARY_PATH "$MY_LD_LIB" \
    -genv MPIR_CVAR_CH3_NETWORK_IFACE eth0 \
    -genv MPIR_CVAR_ALLTOALLV_INTRA_ALGORITHM pairwise_sendrecv_replace \
    -genv LIBPFM_FORCE_PMU icx \
    -genv PAPI_EVENTS_FILE /shared/papi-install/share/papi/papi_events.csv \
    ./epiGraph random ./ \
    -cfile /shared/nodefile2.dat \
    -policy-malleability-triggered \
    -lbpolicy-counts \
    -ni 1440 \
    -nilb 144 \
    -ports 6668 6669 \
    -controller "$CONTROLLER_NAME" 2>&1 | tee "$LOG_FILE"

rm -f "$PHASE_FILE"

if [ -n "${CONTROLLER_PID+x}" ]; then
    kill $CONTROLLER_PID 2>/dev/null || true
    echo "✓ Controlador FlexMPI detenido"
fi

echo ""
echo "=========================================="
echo "✅ EpiGraph SIN Expand completado"
echo "   Log: $LOG_FILE"
echo "=========================================="
