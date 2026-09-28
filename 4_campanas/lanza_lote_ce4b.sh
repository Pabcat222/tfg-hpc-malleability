#!/bin/bash
# =============================================================================
# lanza_lote_ce4b.sh — LOTE CE4-B: dejar CE4 sin ninguna celda a n=1
#
# CE4 es una ablacion de un solo parametro (la politica de balanceo) recorrida
# sobre tres ejes: hardware, cadencia -nilb y tamano de poblacion. Hoy tres de
# sus celdas descansan en UNA sola ejecucion, y dos de ellas sostienen un eje
# entero:
#
#   celda                          n hoy   que sostiene
#   800k · nilb=1440 · con LB        1     el eje de CADENCIA, entero
#   800k · nilb=1440 · sin LB        1     idem
#   3,5M · 16p · con LB              1     la replica «no depende del nº de procesos»
#   3,5M · 16p · sin LB              1     idem
#
# ⭐ Por que el lote incluye tambien las cuatro celdas de nilb=144 a 800k, que
# YA estan a n=2: porque esas dos estan medidas en el despliegue del 9-ago y las
# de 1440 se van a medir aqui. Comparar unas con otras metaria el ruido ENTRE
# despliegues (1,0 %) dentro del eje de cadencia. Repetirlas aqui deja las
# cuatro celdas del eje en el MISMO despliegue, que es la unica forma de que la
# comparacion resuelva diferencias del orden que se pretende afirmar. Las del
# 9-ago se conservan como control entre despliegues.
#
# ⚠️ La pareja de 16p se repite ENTERA, las dos ramas. En el archivo hay mas
# ejecuciones de 16p con LB, pero son de otros despliegues y de otras campanas:
# valen para CE1, que promedia sobre despliegues, y NO para una ablacion
# emparejada, que exige que entre las dos ramas solo cambie el flag.
#
# Todas las celdas son COLOCALIZADAS y de UN SOLO NODO. Eso no es un detalle:
# en multinodo los contadores PAPI devuelven FLOPs=0, el balanceador se queda
# sin entrada y la ejecucion no informa sobre el rebalanceo. Ninguna celda de
# CE4 puede medirse en swarm.
#
# Despliegue unico, 16 contenedores:
#     ./xpn_docker.sh start 16
# y despues, en el HOST del nodo, deshacer el pin de CPU de la rama SINGLE_NODE
# (xpn_docker.sh:411 los clava a --cpuset-cpus 0-7, un apano del portatil):
#     for c in $(docker ps -q); do docker update --cpuset-cpus 0-79 $c; done
#
# ⭐ 16 contenedores sirven para los dos bloques: en modo colocalizado
# lanza_xpn_estatico.sh usa los NUM_PROCS PRIMEROS nodos de machines_mpi para
# computo y para almacenamiento (lineas 181 y 213), asi que una celda de 8p
# sobre este despliegue es identica a una sobre un despliegue de 8; los ocho
# contenedores restantes quedan ociosos y no compiten por CPU.
#
# Uso (desde el HOST del nodo, con el despliegue ya en pie):
#   docker exec -d <CID_1> bash /shared/install-src/lanza_lote_ce4b.sh
#
# Reanudable: salta toda celda ya archivada y completa. El fin del lote se
# comprueba por DESAPARICION DEL PROCESO, nunca buscando una marca en el log
# (el resumen se acumula entre relanzamientos).
# =============================================================================

set -u

EPIGRAPH_DIR=/shared/install-src/EpiGraphFlexMPI-XPN
LOG_DIR="$EPIGRAPH_DIR/mis_logs"
ARCHIVE="$LOG_DIR/lote_ce4b"
DATA_DIR="$EPIGRAPH_DIR/src/data"
MACHINES=/work/machines_mpi
WRAP_LOG="$ARCHIVE/_resumen_lote.txt"

S_ESTATICO=/shared/install-src/lanza_xpn_estatico.sh

# --- Parametros del vigilante ------------------------------------------------
POLL_S=30         # cada cuanto se muestrea el contador de IOPerf
GRACIA_S=1800     # margen inicial antes de exigir progreso (cargar 3,5 M tarda)
STALL_S=900       # sin avanzar mas de esto -> atascada
ESTABLE_S=240     # ya completa y sin moverse esto -> cuelgue del ultimo dia

# -----------------------------------------------------------------------------
# Celdas: "tag  procs  poblacion  nilb  lbpolicy  ioperf_esp  timeout_s"
#
# IOPerf esperadas en 130 dias: nilb=1440 -> 1 volcado/dia -> 130
#                               nilb=144  -> 10/dia        -> 1300
#
# Orden deliberado, de mas a menos en riesgo:
#   1-4   las dos celdas de nilb=1440, que son las que hoy estan a n=1 y de las
#         que cuelga el eje de cadencia entero;
#   5-8   la pareja de 16p a poblacion completa, tambien a n=1;
#   9-12  los controles de nilb=144 a 800k, que ya tienen n=2 en el despliegue
#         del 9-ago: son los unicos prescindibles si la reserva se acorta.
#
# Las repeticiones de una misma configuracion van SEGUIDAS, para que un corte se
# lleve configuraciones enteras y no medias parejas.
#
# Duraciones medidas el 9 y el 11-ago: 800k ~1400-1600 s, 16p a 3,5 M ~4400 s.
# Los timeout llevan holgura porque un TIMEOUT tira la celda entera.
# -----------------------------------------------------------------------------
CELDAS=(
    # --- Bloque 1: el eje de la cadencia, hoy a n=1 -------------------------
    "ce4b_p800k_nilb1440_lb_r2      8  small  1440  counts    130  4000"
    "ce4b_p800k_nilb1440_lb_r3      8  small  1440  counts    130  4000"
    "ce4b_p800k_nilb1440_nolb_r2    8  small  1440  disabled  130  4000"
    "ce4b_p800k_nilb1440_nolb_r3    8  small  1440  disabled  130  4000"
    # --- Bloque 2: la pareja de 16p a poblacion completa, hoy a n=1 ---------
    "ce4b_p35m_16p_lb_r2           16  large   144  counts   1300  9000"
    "ce4b_p35m_16p_lb_r3           16  large   144  counts   1300  9000"
    "ce4b_p35m_16p_nolb_r2         16  large   144  disabled 1300  9000"
    "ce4b_p35m_16p_nolb_r3         16  large   144  disabled 1300  9000"
    # --- Bloque 3: controles intradespliegue del eje de cadencia ------------
    "ce4b_p800k_nilb144_lb_r3       8  small   144  counts   1300  4000"
    "ce4b_p800k_nilb144_lb_r4       8  small   144  counts   1300  4000"
    "ce4b_p800k_nilb144_nolb_r3     8  small   144  disabled 1300  4000"
    "ce4b_p800k_nilb144_nolb_r4     8  small   144  disabled 1300  4000"
)

mkdir -p "$ARCHIVE"
log(){ echo "[$(date -u '+%F %T') UTC] $*" | tee -a "$WRAP_LOG"; }

# -----------------------------------------------------------------------------
# Conmutacion de poblacion. El binario abre './cities/' (ruta relativa fija) y
# lee PopSize de XMLGraphConfigFile.xml: los dos tienen que ir a juego o la
# ejecucion aborta a mitad. Se conmuta convirtiendo 'cities' en enlace
# simbolico; restaura_layout() lo deshace.
# -----------------------------------------------------------------------------
pon_poblacion(){
    local cual=$1
    cd "$EPIGRAPH_DIR" || exit 1

    if [ -d cities ] && [ ! -L cities ]; then
        log "    (primera vez) cities es directorio real -> lo renombro a cities.large"
        mv cities cities.large || { log "ERROR: no pude renombrar cities"; exit 1; }
    fi

    case "$cual" in
        small)
            [ -d cities.small ] || { log "ERROR: falta cities.small"; exit 1; }
            ln -sfn cities.small cities
            cp -f "$DATA_DIR/XMLGraphConfigFile.xml.test" "$DATA_DIR/XMLGraphConfigFile.xml" ;;
        large)
            [ -d cities.large ] || { log "ERROR: falta cities.large"; exit 1; }
            ln -sfn cities.large cities
            cp -f "$DATA_DIR/XMLGraphConfigFile.xml.mad" "$DATA_DIR/XMLGraphConfigFile.xml" ;;
        *) log "ERROR: poblacion desconocida '$cual'"; exit 1 ;;
    esac

    local pop dir
    pop=$(grep -o 'PopSize[^"]*"[0-9]*' "$DATA_DIR/XMLGraphConfigFile.xml" | grep -o '[0-9]*$')
    dir=$(basename "$(readlink -f "$EPIGRAPH_DIR/cities")")
    log "    poblacion activa: PopSize=$pop  cities -> $dir"

    if { [ "$cual" = "small" ] && [ "$pop" != "800826" ]; } || \
       { [ "$cual" = "large" ] && [ "$pop" != "3511110" ]; }; then
        log "ERROR: PopSize=$pop no corresponde a '$cual'. Abortando."
        exit 1
    fi
}

# ⚠️ SIEMPRE se sale restaurando la poblacion grande: es la que usan todas las
# demas campanas y dejarla en small hace abortar la siguiente que se lance.
restaura_layout(){
    cd "$EPIGRAPH_DIR" || return
    if [ -L cities ]; then
        rm -f cities
        [ -d cities.large ] && mv cities.large cities
    fi
    cp -f "$DATA_DIR/XMLGraphConfigFile.xml.mad" "$DATA_DIR/XMLGraphConfigFile.xml"
    echo "[$(date -u '+%F %T') UTC]     layout restaurado: cities = directorio real (3 511 110)" \
        | tee -a "$WRAP_LOG"
}
trap restaura_layout EXIT

limpiar_restos(){
    pkill -9 epiGraph   2>/dev/null || true
    pkill -9 mpiexec    2>/dev/null || true
    pkill -9 controller 2>/dev/null || true
    pkill -9 xpn_server 2>/dev/null || true
    while IFS= read -r ip; do
        [ -n "$ip" ] && ssh -q -n -o StrictHostKeyChecking=no "$ip" \
            "pkill -9 xpn_server 2>/dev/null; pkill -9 epiGraph 2>/dev/null; pkill -9 mpiexec 2>/dev/null; rm -f /tmp/xpn* 2>/dev/null; true" &
    done < "$MACHINES"
    wait
    sleep 5
}

# grep -c ya imprime 0 por si mismo: un '|| echo 0' detras devuelve "0\n0" y
# revienta las comparaciones numericas del vigilante.
cuenta_ioperf(){
    [ -f "$1" ] || { echo 0; return; }
    grep -c "IOPerf" "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# vigila_celda <pid> <log_en_curso> <ioperf_esp> <timeout_s>
# El progreso se decide con DOS muestras del contador de IOPerf separadas en el
# tiempo, nunca con mtime ni con marcas de reloj: los contenedores van en UTC y
# los nodos en CEST, y comparar unas con otras ha hecho dar por colgada una
# ejecucion que acababa de empezar.
# -----------------------------------------------------------------------------
vigila_celda(){
    local pid=$1 flog=$2 esp=$3 tmax=$4
    local t0 ahora n_ant n_now t_ultimo_avance t_completa
    t0=$(date +%s); n_ant=0; t_ultimo_avance=$t0; t_completa=0

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$POLL_S"
        ahora=$(date +%s)
        n_now=$(cuenta_ioperf "$flog")

        if [ "$n_now" -gt "$n_ant" ]; then
            t_ultimo_avance=$ahora
            n_ant=$n_now
        fi

        # Ya tiene todos los volcados: ventana por si cierra sola; si se queda
        # ahi parada es el cuelgue del ultimo dia y la run SIGUE SIENDO VALIDA.
        if [ "$n_now" -ge "$((esp - 1))" ]; then
            [ "$t_completa" -eq 0 ] && t_completa=$ahora
            if [ $((ahora - t_completa)) -ge "$ESTABLE_S" ]; then
                kill -9 "$pid" 2>/dev/null
                echo "COMPLETA_COLGADA"; return
            fi
        fi

        if [ $((ahora - t0)) -gt "$GRACIA_S" ] && [ $((ahora - t_ultimo_avance)) -ge "$STALL_S" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "ATASCADA_${n_now}"; return
        fi

        if [ $((ahora - t0)) -ge "$tmax" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "TIMEOUT_${n_now}"; return
        fi
    done
    echo "FIN_NORMAL"
}

# --- Pre-chequeos -------------------------------------------------------------
[ -f "$MACHINES" ] || { log "ERROR: no existe $MACHINES. Falta arrancar el cluster."; exit 1; }
N_TOTAL=$(wc -l < "$MACHINES")
log "Nodos en machines_mpi: $N_TOTAL (se necesitan >= 16, colocalizado)"
[ "$N_TOTAL" -ge 16 ] || { log "ERROR: nodos insuficientes -> ./xpn_docker.sh start 16"; exit 1; }
[ -f "$S_ESTATICO" ] || { log "ERROR: no existe $S_ESTATICO"; exit 1; }

# El lanzador tiene que ser la version parametrizada, o NILB/LBPOLICY se
# ignoran en silencio y las doce celdas saldrian con la configuracion por
# defecto: doce ejecuciones identicas y ninguna medida.
grep -q 'lbpolicy-\$LBPOLICY' "$S_ESTATICO" || {
    log "ERROR: $S_ESTATICO no admite LBPOLICY/NILB. Sube la version parametrizada."; exit 1; }

[ -d "$EPIGRAPH_DIR/cities.small" ] || {
    log "ERROR: falta $EPIGRAPH_DIR/cities.small; el bloque de 800k no puede correr."; exit 1; }

# La imagen no trae libglpk/libgsl/libpapi y cada 'start' recrea los
# contenedores vacios. Idempotente: si ya estan, es un no-op.
log "comprobando dependencias en los $N_TOTAL contenedores..."
if [ -f /shared/deps_par.sh ]; then
    bash /shared/deps_par.sh 2>&1 | tail -3 | while read -r l; do log "  deps: $l"; done
elif [ -f /shared/install-src/ce4_deps.sh ]; then
    bash /shared/install-src/ce4_deps.sh 2>&1 | tail -3 | while read -r l; do log "  deps: $l"; done
else
    log "  ⚠️  no encuentro deps_par.sh ni ce4_deps.sh; sigo y confio en el entorno"
fi

# =============================================================================
log "===== INICIO LOTE CE4-B — ${#CELDAS[@]} celdas ====="
declare -a RESUMEN
i=0
for celda in "${CELDAS[@]}"; do
    i=$((i+1))
    set -- $celda
    TAG=$1; NP=$2; POB=$3; NILB_C=$4; LBPOL=$5; IOPERF_ESP=$6; TMAX=$7

    # lanza_xpn_estatico.sh construye el nombre asi en modo colocalizado
    # (linea 59): 001_xpn_estatico_<N>n_<N>p_<LOG_TAG>
    LOG_NAME="001_xpn_estatico_${NP}n_${NP}p_${TAG}"
    ORIGEN="$LOG_DIR/${LOG_NAME}.log"
    DEST_DIR="$ARCHIVE/$TAG"
    ARCHIVADO="$DEST_DIR/${LOG_NAME}.log"

    # --- Reanudacion ---------------------------------------------------------
    # El guardian es el recuento de IOPerf, NO el 'Spreading time': el fallo del
    # ultimo dia impide imprimirlo en ~la mitad de las ejecuciones y aun asi la
    # run cubre el 99 % de la simulacion y es usable. Exigir Spreading haria
    # repetir runs perfectamente validas.
    if [ -f "$ARCHIVADO" ]; then
        n_io=$(cuenta_ioperf "$ARCHIVADO")
        if [ "$n_io" -ge "$((IOPERF_ESP - 1))" ]; then
            log ">>> [$i/${#CELDAS[@]}] SALTADA (ya completa): $TAG  (IOPerf=$n_io/$IOPERF_ESP)"
            RESUMEN+=("SALTADA  $TAG  IOPerf=$n_io")
            continue
        fi
        log ">>> [$i/${#CELDAS[@]}] $TAG archivada pero incompleta (IOPerf=$n_io) -> la repito"
    fi

    log ">>> [$i/${#CELDAS[@]}] $TAG  ${NP}p  pop=$POB  nilb=$NILB_C  lb=$LBPOL  esp=$IOPERF_ESP  tmax=${TMAX}s"
    pon_poblacion "$POB"
    limpiar_restos
    rm -f "$ORIGEN"

    T0=$(date +%s)
    NILB="$NILB_C" LBPOLICY="$LBPOL" LOG_TAG="$TAG" \
        bash "$S_ESTATICO" "$NP" >/dev/null 2>&1 &
    PID=$!

    MOTIVO=$(vigila_celda "$PID" "$ORIGEN" "$IOPERF_ESP" "$TMAX")
    wait "$PID" 2>/dev/null
    RC=$?
    DT=$(( $(date +%s) - T0 ))

    # --- Archivado + veredicto ----------------------------------------------
    mkdir -p "$DEST_DIR"
    if [ -f "$ORIGEN" ]; then
        cp -f "$ORIGEN" "$ARCHIVADO"
        [ -f "${ORIGEN%.log}_errores.log" ] && cp -f "${ORIGEN%.log}_errores.log" "$DEST_DIR/"
        n_io=$(cuenta_ioperf "$ARCHIVADO")
        spread=$(grep -m1 "Spreading time" "$ARCHIVADO" 2>/dev/null | grep -o "[0-9.]*$")
        cfg=$(head -1 "$ARCHIVADO" | sed 's/### CONFIG: *//')
        # Condicion de validez de CE4: sin FLOPs el balanceador no tiene entrada
        # y la ejecucion, aunque termine bien, no informa sobre el rebalanceo.
        nflops0=$(grep -c "FLOPs: 0" "$ARCHIVADO" 2>/dev/null)
        if [ "$n_io" -ge "$((IOPERF_ESP - 1))" ] && [ "${nflops0:-0}" -eq 0 ]; then
            log "<<< [$i] OK  motivo=$MOTIVO rc=$RC ${DT}s  IOPerf=$n_io  FLOPs0=$nflops0  Spreading=${spread:-no impreso}  [$cfg]"
            RESUMEN+=("OK       $TAG  IOPerf=$n_io  FLOPs0=$nflops0  ${DT}s  ($MOTIVO)  [$cfg]")
        elif [ "${nflops0:-0}" -gt 0 ]; then
            log "<<< [$i] INVALIDA  motivo=$MOTIVO ${DT}s  IOPerf=$n_io  pero FLOPs=0 en $nflops0 lineas -> NO sirve para CE4"
            RESUMEN+=("INVALIDA $TAG  FLOPs0=$nflops0  IOPerf=$n_io  ${DT}s  ($MOTIVO)")
        else
            log "<<< [$i] FALLO  motivo=$MOTIVO rc=$RC ${DT}s  IOPerf=$n_io/$IOPERF_ESP"
            RESUMEN+=("FALLO    $TAG  IOPerf=$n_io/$IOPERF_ESP  ${DT}s  ($MOTIVO)")
        fi
    else
        log "<<< [$i] FALLO  motivo=$MOTIVO rc=$RC ${DT}s  no se genero el log $ORIGEN"
        RESUMEN+=("FALLO    $TAG  sin log  ${DT}s  ($MOTIVO)")
    fi
done

limpiar_restos
log "===== FIN LOTE CE4-B ====="
for r in "${RESUMEN[@]}"; do log "   $r"; done
log "Archivo: $ARCHIVE"
log "Referencias ya medidas (otro despliegue): 800k/1440 lb 1408 s · nolb 1404 s ·"
log "                                          800k/144  lb 1266/1302 s · nolb 1614/1566 s ·"
log "                                          3,5M/16p  nolb 4399 s"
