#!/bin/bash
# =============================================================================
# arranca_lote_ce4b.sh — orquestador de los lotes pendientes de UN SOLO NODO
#
#   FASE 1: LOTE CE4-B   12 celdas, ~8,2 h,  16 contenedores
#   FASE 2: LOTE CE2-B   18 celdas, ~29,5 h, 32 contenedores  (barrido de bsize)
#
# Conserva el nombre historico por las referencias de las notas, pero ya no
# lanza solo CE4-B. Total ~38 h: pedir la reserva en consecuencia (48 h; la cola
# 'normal' admite hasta 5 d 8 h). Los dos lotes son reanudables, asi que un
# corte no obliga a repetir lo ya archivado.
#
# ⚠️ Las dos fases NO pueden compartir despliegue: CE2-B necesita 32
# contenedores porque su celda «16 procesos + 16 servidores dedicados» es
# exclusiva, y CE4-B esta medido y pensado sobre 16. Se redespliega entre fases,
# lo que ademas mantiene cada lote dentro de un unico despliegue, que es lo que
# exigen sus comparaciones.
#
# Corre en el HOST del nodo de computo, desacoplado:
#   setsid nohup bash ~/xpn-docker/arranca_lote_ce4b.sh > ~/xpn-docker/arranque_ce4b.log 2>&1 < /dev/null &
#
# CE4 mide el balanceador, y el balanceador necesita FLOPs. En multinodo los
# contadores PAPI devuelven cero en el 100 % de las campanas medidas, asi que
# este lote va OBLIGATORIAMENTE sobre UN SOLO NODO. Lo primero que hace es
# deshacer el swarm que dejo el lote anterior: mientras exista el fichero
# .xpn_docker_swarm, 'start' se va por la rama multinodo (xpn_docker.sh:378) y
# las doce ejecuciones saldrian con FLOPs=0, validas de correr e inutiles de
# medir.
#
# Una sola fase: 16 contenedores colocalizados sirven para las celdas de 8p y
# para las de 16p, porque en colocalizado el lanzador usa los NUM_PROCS
# primeros nodos de machines_mpi para computo y almacenamiento.
# =============================================================================

set -u

DIR="$HOME/xpn-docker"
MIS_LOGS="$DIR/install-src/EpiGraphFlexMPI-XPN/mis_logs"
LOTE=/shared/install-src/lanza_lote_ce4b.sh
LOTE2=/shared/install-src/lanza_lote_ce2b.sh
N_CONT=16
N_CONT2=32          # CE2-B: 16 de computo + 16 de almacenamiento en la celda exclusiva

cd "$DIR" || exit 1
log(){ echo "[$(date '+%F %T %Z')] $*"; }
muere(){ log "ABORTA: $*"; exit 1; }

# -----------------------------------------------------------------------------
# El contenedor #1 es el de la PRIMERA IP de machines_mpi. En single-node suele
# llamarse xpn_docker-node-1, pero se localiza por IP para no depender del
# nombre ni del orden de 'docker ps'.
# -----------------------------------------------------------------------------
CID1=""
localiza_cid1(){
    CID1=""
    local ip1
    ip1=$(head -1 "$DIR/machines_mpi" 2>/dev/null)
    [ -n "$ip1" ] || return 1
    CID1=$(for C in $(docker ps -q); do
             I=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$C" \
                 | tr ' ' '\n' | grep -E '^(192\.168\.|10\.)' | head -1)
             echo "$I $C"
           done | awk -v ip="$ip1" '$1==ip{print $2; exit}')
    [ -n "$CID1" ]
}

# --- 1. Deshacer el swarm -----------------------------------------------------
log "########## DESPLIEGUE CE4-B — un solo nodo ##########"
log "parando el stack anterior..."
./xpn_docker.sh stop >/dev/null 2>&1
sleep 5

if [ -f .xpn_docker_swarm ]; then
    log "deshaciendo el swarm (CE4 exige un solo nodo: en multinodo PAPI da FLOPs=0)..."
    ./xpn_docker.sh swarm-destroy >/dev/null 2>&1
    sleep 5
fi
rm -f .xpn_docker_swarm .xpn_docker_worksession
docker swarm leave --force >/dev/null 2>&1
log "modo swarm: $([ -f .xpn_docker_swarm ] && echo ACTIVO || echo desactivado)"

# --- 2. Contenedores ----------------------------------------------------------
log "arrancando $N_CONT contenedores colocalizados..."
./xpn_docker.sh start "$N_CONT" >/dev/null 2>&1
sleep 15

VIVOS=$(docker ps -q | wc -l)
log "contenedores vivos: $VIVOS (esperados $N_CONT)"
[ "$VIVOS" -ge "$N_CONT" ] || muere "solo $VIVOS de $N_CONT contenedores"

MODO=$(cat .xpn_docker_worksession 2>/dev/null || echo '?')
log "modo de sesion: $MODO"
[ "$MODO" = "SINGLE_NODE" ] || muere "el despliegue NO es SINGLE_NODE ($MODO); CE4 no se puede medir asi"

# ⚠️ xpn_docker.sh:411 clava los contenedores a --cpuset-cpus 0-7 SOLO en la
# rama SINGLE_NODE. Es un apano del portatil (P-cores de Alder Lake) que aqui
# confinaria las 12 ejecuciones a 8 de las 80 CPUs logicas, sin dar ningun error.
log "deshaciendo el pin de CPU de la rama SINGLE_NODE..."
for c in $(docker ps -q); do docker update --cpuset-cpus 0-79 "$c" >/dev/null 2>&1; done
log "cpuset de una muestra: $(docker inspect -f '{{.HostConfig.CpusetCpus}}' $(docker ps -q | head -1))"

localiza_cid1 || muere "no encuentro el contenedor de la 1a IP de machines_mpi"
log "contenedor #1: $CID1"

# --- 3. Dependencias ----------------------------------------------------------
# Cada 'start' recrea los contenedores vacios y la imagen no trae libglpk,
# libgsl ni libpapi: epiGraph moriria con 'libglpk.so.40: cannot open shared
# object file'.
log "instalando dependencias en los $N_CONT contenedores..."
if [ -f "$DIR/deps_par.sh" ]; then
    docker exec "$CID1" bash /shared/deps_par.sh 2>&1 | tail -2 | while read -r l; do log "  deps: $l"; done
else
    docker exec "$CID1" bash /shared/install-src/ce4_deps.sh 2>&1 | tail -2 | while read -r l; do log "  deps: $l"; done
fi

# --- 4. Poblacion -------------------------------------------------------------
# El lote conmuta la poblacion celda a celda, pero se exige partir de la grande:
# si el layout quedo a medias de una campana anterior, cities.large no existe y
# el bloque de 16p no podria correr.
EST=$(docker exec "$CID1" bash /shared/install-src/ce4_pop.sh estado 2>&1)
log "poblacion: $(echo "$EST" | tr '\n' ' ')"
if ! echo "$EST" | grep -q 3511110; then
    log "no esta la grande; conmutando a large..."
    docker exec "$CID1" bash /shared/install-src/ce4_pop.sh large >/dev/null 2>&1 \
        || muere "no se pudo conmutar a la poblacion grande"
    EST=$(docker exec "$CID1" bash /shared/install-src/ce4_pop.sh estado 2>&1)
    log "poblacion tras conmutar: $(echo "$EST" | tr '\n' ' ')"
    echo "$EST" | grep -q 3511110 || muere "la poblacion sigue sin ser la grande"
fi

# --- 5. Prueba de humo --------------------------------------------------------
# Tres dias con la configuracion MAS exigente del lote (16 procesos, poblacion
# completa). Cuesta unos minutos y ha cazado ya dos fallos de entorno.
rm -f "$MIS_LOGS"/001_xpn_estatico_16n_16p_smoke_ce4b*.log
log "prueba de humo (16 procesos, poblacion completa, 3 dias)..."
timeout 2400 docker exec -e SIM_DAYS=3 -e LOG_TAG=smoke_ce4b "$CID1" \
    bash /shared/install-src/lanza_xpn_estatico.sh 16 > "$DIR/humo_ce4b.log" 2>&1
log "humo: rc=$? (traza en $DIR/humo_ce4b.log)"

HUMO_LOG=$(ls "$MIS_LOGS"/001_xpn_estatico_16n_16p_smoke_ce4b*.log 2>/dev/null | grep -v errores | head -1)
N_IO=0; N_F0=0
if [ -n "$HUMO_LOG" ]; then
    N_IO=$(grep -c IOPerf "$HUMO_LOG")
    N_F0=$(grep -c "FLOPs: 0" "$HUMO_LOG")
fi
log "humo: IOPerf=$N_IO  lineas con FLOPs=0: $N_F0"
[ "$N_IO" -ge 10 ] || muere "la prueba de humo no produjo volcados; no gasto el lote"

# ⭐ La comprobacion que de verdad importa en CE4: si el humo sale con FLOPs=0,
# las doce celdas saldrian igual y el lote entero no mediria nada del
# balanceador. Mas vale gastar 5 minutos aqui que 8 horas de reserva.
if [ "$N_F0" -gt 0 ]; then
    muere "el humo trae FLOPs=0 en $N_F0 lineas: el balanceador no tendria entrada. Revisa perf_event_paranoid y la libpapi de /shared/papi-install ANTES de lanzar."
fi

# --- 6. El lote ---------------------------------------------------------------
log "lanzando el LOTE CE4-B (12 celdas, ~8,2 h)..."
docker exec "$CID1" bash "$LOTE"
log "########## LOTE CE4-B TERMINADO (o cortado) ##########"

# El lote restaura la poblacion grande en su trap de salida; se verifica aqui
# porque dejarla en small hace abortar la siguiente campana que se lance, y la
# FASE 2 corre entera a poblacion completa.
EST=$(docker exec "$CID1" bash /shared/install-src/ce4_pop.sh estado 2>&1)
log "poblacion final CE4-B: $(echo "$EST" | tr '\n' ' ')"
if ! echo "$EST" | grep -q 3511110; then
    log "la poblacion no quedo en la grande; conmutando antes de la fase 2..."
    docker exec "$CID1" bash /shared/install-src/ce4_pop.sh large >/dev/null 2>&1 \
        || muere "no se pudo restaurar la poblacion grande; no lanzo la fase 2"
fi

# =============================================================================
# FASE 2 — LOTE CE2-B: barrido de tamano de bloque (18 celdas, ~29,5 h)
#
# Las dieciocho ejecuciones de `tab:ce2_bsize` estan a n=1, LAS DOS RAMAS (512 y
# 1024 KiB), de modo que el lote repite ambas dentro de este unico despliegue:
# medir solo 1024 y compararlo con los 512 de otra campana metería el ruido
# entre despliegues dentro de una comparacion cuyo efecto declarado es nulo.
#
# Redespliegue obligado a 32 contenedores por la celda exclusiva de 16p+16xpn.
# =============================================================================
log "########## DESPLIEGUE CE2-B — un solo nodo, $N_CONT2 contenedores ##########"
log "parando el stack de la fase 1..."
./xpn_docker.sh stop >/dev/null 2>&1
sleep 10

./xpn_docker.sh start "$N_CONT2" >/dev/null 2>&1
sleep 15

VIVOS=$(docker ps -q | wc -l)
log "contenedores vivos: $VIVOS (esperados $N_CONT2)"
[ "$VIVOS" -ge "$N_CONT2" ] || muere "solo $VIVOS de $N_CONT2 contenedores; sin ellos la celda 16p+16xpn no puede correr"

MODO=$(cat .xpn_docker_worksession 2>/dev/null || echo '?')
log "modo de sesion: $MODO"
[ "$MODO" = "SINGLE_NODE" ] || muere "el despliegue NO es SINGLE_NODE ($MODO)"

# El pin de CPU se vuelve a aplicar en cada 'start' de la rama SINGLE_NODE.
log "deshaciendo el pin de CPU..."
for c in $(docker ps -q); do docker update --cpuset-cpus 0-79 "$c" >/dev/null 2>&1; done
log "cpuset de una muestra: $(docker inspect -f '{{.HostConfig.CpusetCpus}}' $(docker ps -q | head -1))"

localiza_cid1 || muere "no encuentro el contenedor de la 1a IP de machines_mpi"
log "contenedor #1: $CID1"

log "instalando dependencias en los $N_CONT2 contenedores..."
if [ -f "$DIR/deps_par.sh" ]; then
    docker exec "$CID1" bash /shared/deps_par.sh 2>&1 | tail -2 | while read -r l; do log "  deps: $l"; done
else
    docker exec "$CID1" bash /shared/install-src/ce4_deps.sh 2>&1 | tail -2 | while read -r l; do log "  deps: $l"; done
fi

EST=$(docker exec "$CID1" bash /shared/install-src/ce4_pop.sh estado 2>&1)
log "poblacion: $(echo "$EST" | tr '\n' ' ')"
echo "$EST" | grep -q 3511110 || muere "CE2-B necesita la poblacion completa"

# --- Humo de la fase 2 --------------------------------------------------------
# Con la configuracion mas exigente del lote (16 procesos + 16 servidores
# dedicados) y con bsize=1024, que de paso comprueba lo unico que este lote
# puede perder en silencio: que XPN_BSIZE llegue a config.txt. xpn.sh lo
# regenera en cada arranque, y un bsize que no se aplica convierte las dieciocho
# celdas en dieciocho repeticiones de la misma configuracion.
rm -f "$MIS_LOGS"/001_xpn_estatico_excl_16app_16xpn_16p_smoke_ce2b*.log
log "prueba de humo (16 procesos + 16 xpn, bsize 1024, 3 dias)..."
timeout 2400 docker exec -e SIM_DAYS=3 -e LOG_TAG=smoke_ce2b -e XPN_BSIZE=1024 "$CID1" \
    bash /shared/install-src/lanza_xpn_estatico.sh 16 16 > "$DIR/humo_ce2b.log" 2>&1
log "humo: rc=$? (traza en $DIR/humo_ce2b.log)"

HUMO_LOG=$(ls "$MIS_LOGS"/001_xpn_estatico_excl_16app_16xpn_16p_smoke_ce2b*.log 2>/dev/null | grep -v errores | head -1)
N_IO=0; BS=""
if [ -n "$HUMO_LOG" ]; then
    N_IO=$(grep -c IOPerf "$HUMO_LOG")
    BS=$(grep -m1 "bsize fijado a" "$HUMO_LOG" | grep -o "[0-9]*" | head -1)
fi
log "humo: IOPerf=$N_IO  bsize efectivo='${BS:-ninguno}'"
[ "$N_IO" -ge 10 ] || muere "la prueba de humo no produjo volcados; no gasto el lote"
[ "${BS:-0}" = "1024" ] || muere "XPN_BSIZE no llego a config.txt (bsize='${BS:-ninguno}'): las 18 celdas medirian lo mismo"

log "lanzando el LOTE CE2-B (18 celdas, ~29,5 h)..."
docker exec "$CID1" bash "$LOTE2"
log "########## LOTE CE2-B TERMINADO (o cortado) ##########"

EST=$(docker exec "$CID1" bash /shared/install-src/ce4_pop.sh estado 2>&1)
log "poblacion final: $(echo "$EST" | tr '\n' ' ')"
echo "$EST" | grep -q 3511110 || log "⚠️  ATENCION: la poblacion NO quedo en la grande. Restaurala a mano."
log "PENDIENTE que este orquestador NO cubre: las 9 celdas multinodo de tab:ce2_multinodo,"
log "que exigen DOS nodos y red superpuesta (~12 h). Ver lanza_dist_batch.sh y lanza_multinodo_batch.sh."
