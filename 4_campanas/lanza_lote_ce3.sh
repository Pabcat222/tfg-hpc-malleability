#!/bin/bash
# =============================================================================
# lanza_lote_ce3.sh   (14-ago)
#
# Cierra los pendientes experimentales de CE3, que hoy son la parte peor medida
# de la memoria: las cinco celdas de tab:ce3_magnitud estan a n=1, la estatica
# de 8 procesos multinodo NO EXISTE (la tabla no tiene cota inferior) y dos de
# las tres celdas del barrido de dias tambien estan a n=1.
#
# POR QUE, celda a celda:
#   - El +1,5 % de 8->16 frente a la estatica de 16 esta por debajo del umbral
#     del 2 % de la seccion de variabilidad: hoy se declara indistinguible y con
#     n=2 dentro de un mismo despliegue puede resolverse en cualquier sentido.
#   - El +5,0 % de 8->64 frente a la estatica de 64 cae en la banda de reserva y
#     es el numero que sostiene "la maleabilidad cuesta poco tiempo".
#   - La estatica de 8p multinodo es la referencia natural -lo que costaria no
#     expandir nunca- y no puede tomarse prestada de CE2: aquellas son de UN
#     SOLO NODO fisico, esta lleva EpiGraph y los servidores en nodos distintos.
#   - En el barrido de dias, "adelantarse es indiferente" compara hoy UN punto
#     contra la distribucion de seis; con n=3 en d30 se comparan distribuciones.
#
# DOS FASES, PORQUE SON DOS DESPLIEGUES DISTINTOS:
#   FASE A  ./xpn_docker.sh start 64 2      66 contenedores, 2 servidores en el
#           otro nodo. Es la topologia de la campana de up-scaling.
#   FASE B  DIST=1 ./xpn_docker.sh start 80 8   88 contenedores, 8 servidores
#           repartidos 4+4. Es la topologia de la campana de co-maleabilidad.
# El cambio de despliegue lo hace arranca_lote_ce3.sh, que es quien orquesta;
# este script ejecuta las celdas de UNA fase, la que le diga $FASE.
#
# ORDEN DELIBERADO, igual que en el lote de CE2: r1 y r2 de cada configuracion
# van SEGUIDAS, para que un corte se lleve configuraciones enteras en vez de
# dejarlo todo a n=1, que es justo lo que ya tenemos. Dentro de eso, primero las
# parejas que deciden los dos numeros pequenos (16p y 64p con sus maleables), y
# al final 8->32, cuyo efecto -el salto de 16 a 32 procesos- es de un orden que
# ninguna repeticion ha movido nunca.
#
# ROBUSTEZ: heredada de lanza_lote_ce2_n2.sh.
#   - El guardian NO es "Spreading time" sino el RECUENTO DE LINEAS IOPerf. El
#     fallo del ultimo dia es una condicion de carrera que afecta a ~50 % de las
#     ejecuciones con independencia de la configuracion; la ejecucion completa el
#     99 % de la simulacion y es usable, y se compara a iteracion comun 185760.
#   - Vigilante por celda que corta por COMPLETA_COLGADA, ATASCADA o TIMEOUT y
#     PASA A LA SIGUIENTE. El progreso se mide con dos muestras del contador
#     separadas en el tiempo, nunca por mtime ni por marcas de hora: los
#     contenedores van en UTC y el nodo en CEST.
#   - Reanudable: una celda ya archivada con sus 1300 volcados se salta.
#
# Uso (dentro del contenedor app #1):
#   FASE=A bash /shared/install-src/lanza_lote_ce3.sh
#   FASE=B bash /shared/install-src/lanza_lote_ce3.sh
# =============================================================================

set -u

FASE=${FASE:-A}

EPIGRAPH_DIR=/shared/install-src/EpiGraphFlexMPI-XPN
LOG_DIR="$EPIGRAPH_DIR/mis_logs"
ARCHIVE="$LOG_DIR/lote_ce3"
DATA_DIR="$EPIGRAPH_DIR/src/data"
MACHINES=/work/machines_mpi
WRAP_LOG="$ARCHIVE/_resumen_lote.txt"

S_ESTATICO=/shared/install-src/lanza_xpn_estatico.sh
S_SPAWN=/shared/install-src/lanza_multinodo_spawn.sh
S_COMALL=/shared/install-src/lanza_comaleabilidad.sh

# --- Parametros del vigilante ------------------------------------------------
POLL_S=60         # cada cuanto se muestrea el contador de IOPerf
GRACIA_S=2400     # margen inicial antes de exigir progreso (cargar 3,5 M tarda)
STALL_S=1200      # sin avanzar mas de esto -> atascada
ESTABLE_S=240     # ya completa y sin moverse esto -> cuelgue del ultimo dia

# -----------------------------------------------------------------------------
# Celdas: "tag  tipo  arg  ioperf_esp  timeout_s"
#   tipo E = estatica  -> lanza_xpn_estatico.sh <arg> 2   (arg = nº de procesos)
#   tipo M = maleable  -> lanza_multinodo_spawn.sh        (arg = objetivo del spawn)
#   tipo C = co-maleab -> lanza_comaleabilidad.sh         (arg = dia de expansion)
#
# Los timeouts salen de los tiempos medidos en las campanas originales, con
# holgura: est16 5586 s, 8->16 5670 s, est64 3354 s, 8->64 3523 s, 8->32 3887 s,
# d30 3395 s, d50 3825 s. La estatica de 8p no tiene precedente en esta
# topologia; se le da el presupuesto mas ancho porque es la mas lenta de todas
# (las maleables ya tardan 5670 s recorriendo con 8 procesos solo los primeros
# 45 dias, y esta los recorre los 130).
# -----------------------------------------------------------------------------
if [ "$FASE" = "A" ]; then
CELDAS=(
    # --- La pareja que decide el +1,5 % --------------------------------------
    "ce3_est16_r1   E  16  1300   9000"
    "ce3_est16_r2   E  16  1300   9000"
    "ce3_m8a16_r1   M  16  1300   9000"
    "ce3_m8a16_r2   M  16  1300   9000"
    # --- La pareja que decide el +5,0 % --------------------------------------
    "ce3_est64_r1   E  64  1300   7000"
    "ce3_est64_r2   E  64  1300   7000"
    "ce3_m8a64_r1   M  64  1300   7000"
    "ce3_m8a64_r2   M  64  1300   7000"
    # --- La celda que falta por crear: cota inferior de la tabla -------------
    "ce3_est8_r1    E   8  1300  15000"
    "ce3_est8_r2    E   8  1300  15000"
    # --- 8->32: el efecto grande, el menos expuesto --------------------------
    "ce3_m8a32_r1   M  32  1300   7000"
    "ce3_m8a32_r2   M  32  1300   7000"
)
else
CELDAS=(
    # --- Barrido de dias de la campana de co-maleabilidad (perfil 8->40, 8
    #     servidores que encogen a 4 el mismo dia). r1 de cada uno ya existe.
    "ce3_d30_r2     C  30  1300   8000"
    "ce3_d30_r3     C  30  1300   8000"
    "ce3_d50_r2     C  50  1300   8000"
    "ce3_d50_r3     C  50  1300   8000"
)
fi

mkdir -p "$ARCHIVE"
log(){ echo "[$(date -u '+%F %T') UTC] $*" | tee -a "$WRAP_LOG"; }

# -----------------------------------------------------------------------------
# La poblacion NO se conmuta aqui: se exige encontrar la grande ya puesta y se
# aborta si no. Conmutarla en silencio es justo como se mide una campana contra
# la poblacion equivocada.
# -----------------------------------------------------------------------------
comprueba_poblacion_grande(){
    cd "$EPIGRAPH_DIR" || exit 1
    local pop dir
    pop=$(grep -o 'PopSize[^"]*"[0-9]*' "$DATA_DIR/XMLGraphConfigFile.xml" | grep -o '[0-9]*$')
    dir=$(basename "$(readlink -f "$EPIGRAPH_DIR/cities")")
    log "poblacion activa: PopSize=$pop  cities -> $dir"
    if [ "$pop" != "3511110" ] || [ "$dir" = "cities.small" ]; then
        log "ERROR: se esperaba la poblacion grande (3511110 + cities/cities.large)."
        log "       Ejecuta primero: bash /shared/install-src/ce4_pop.sh large"
        exit 1
    fi
}

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

cuenta_ioperf(){  # $1 = fichero; devuelve 0 si no existe
    [ -f "$1" ] || { echo 0; return; }
    grep -c "IOPerf" "$1" 2>/dev/null || echo 0
}

# -----------------------------------------------------------------------------
# vigila_celda <pid_del_lanzador> <log_en_curso> <ioperf_esp> <timeout_s>
# Imprime el motivo de terminacion por stdout. No mata nada el mismo salvo el
# lanzador: la limpieza fina la hace limpiar_restos en la celda siguiente.
# -----------------------------------------------------------------------------
vigila_celda(){
    local pid=$1 flog=$2 esp=$3 tmax=$4
    local t0 ahora n_ant n_now t_ultimo_avance t_completa
    t0=$(date +%s); n_ant=0; t_ultimo_avance=$t0; t_completa=0

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$POLL_S"
        ahora=$(date +%s)
        n_now=$(cuenta_ioperf "$flog")

        # Progreso: dos muestras del contador separadas en el tiempo.
        if [ "$n_now" -gt "$n_ant" ]; then
            t_ultimo_avance=$ahora
            n_ant=$n_now
        fi

        # Ya tiene todos los volcados: se le da una ventana por si cierra sola;
        # si se queda ahi parada, es el cuelgue del ultimo dia.
        if [ "$n_now" -ge "$((esp - 1))" ]; then
            [ "$t_completa" -eq 0 ] && t_completa=$ahora
            if [ $((ahora - t_completa)) -ge "$ESTABLE_S" ]; then
                kill -9 "$pid" 2>/dev/null
                echo "COMPLETA_COLGADA"; return
            fi
        fi

        # Atascada: no avanza y ya paso la gracia inicial.
        if [ $((ahora - t0)) -gt "$GRACIA_S" ] && [ $((ahora - t_ultimo_avance)) -ge "$STALL_S" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "ATASCADA_${n_now}"; return
        fi

        # Presupuesto agotado.
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
log "Nodos en machines_mpi: $N_TOTAL"
for s in "$S_ESTATICO" "$S_SPAWN" "$S_COMALL"; do
    [ -f "$s" ] || { log "ERROR: no existe $s"; exit 1; }
done

comprueba_poblacion_grande

# El baseline y los lanzadores dan por preparado el entorno; la imagen no trae
# libglpk/libgsl/libpapi y cada 'start' recrea los contenedores vacios.
log "comprobando dependencias en los $N_TOTAL contenedores..."
bash /shared/deps_par.sh 2>&1 | tail -3 | while read -r l; do log "  deps: $l"; done

log "===== INICIO LOTE CE3 FASE $FASE — ${#CELDAS[@]} celdas ====="
declare -a RESUMEN
i=0
for celda in "${CELDAS[@]}"; do
    i=$((i+1))
    set -- $celda
    TAG=$1; TIPO=$2; ARG=$3; IOPERF_ESP=$4; TMAX=$5

    # Nodos necesarios. Las maleables arrancan con 8 procesos pero necesitan el
    # despliegue entero: el spawn reparte un proceso por contenedor app.
    case "$TIPO" in
        E) NEED=$(( ARG + 2 )) ;;
        M) NEED=$(( ARG + 2 )) ;;
        C) NEED=48 ;;   # 40 procesos de EpiGraph + 8 servidores
    esac
    if [ "$N_TOTAL" -lt "$NEED" ]; then
        log ">>> [$i/${#CELDAS[@]}] SALTADA (nodos insuficientes: $N_TOTAL < $NEED): $TAG"
        RESUMEN+=("SALTADA  $TAG  nodos $N_TOTAL<$NEED")
        continue
    fi

    # Nombre del log tal y como lo construye cada lanzador. Solo el estatico
    # admite LOG_TAG; los otros dos escriben siempre en el mismo fichero, asi
    # que las dos pasadas se distinguen AL ARCHIVAR y el rm -f de mas abajo
    # evita que la r2 herede el contenido de la r1.
    case "$TIPO" in
        E) LOG_NAME="001_xpn_estatico_excl_${ARG}app_2xpn_${ARG}p_${TAG}" ;;
        M) LOG_NAME="001_xpn_dmr_multinodo_8_${ARG}p_1sw_d45" ;;
        C) LOG_NAME="001_comall_${TAG}_8i_${ARG}-40_xpn${ARG}-4" ;;
    esac
    ORIGEN="$LOG_DIR/${LOG_NAME}.log"
    DEST="$ARCHIVE/$TAG"
    ARCHIVADO="$DEST/${LOG_NAME}.log"

    # --- Reanudacion: esta celda ya esta archivada y completa? ---------------
    if [ -f "$ARCHIVADO" ]; then
        n_io=$(cuenta_ioperf "$ARCHIVADO")
        if [ "$n_io" -ge "$((IOPERF_ESP - 1))" ]; then
            log ">>> [$i/${#CELDAS[@]}] SALTADA (ya completa): $TAG  (IOPerf=$n_io/$IOPERF_ESP)"
            RESUMEN+=("SALTADA  $TAG  IOPerf=$n_io")
            continue
        fi
        log ">>> [$i/${#CELDAS[@]}] $TAG archivada pero incompleta (IOPerf=$n_io) -> la repito"
    fi

    log ">>> [$i/${#CELDAS[@]}] $TAG  tipo=$TIPO  arg=$ARG  esp=$IOPERF_ESP  tmax=${TMAX}s"
    limpiar_restos
    rm -f "$ORIGEN"

    T0=$(date +%s)
    case "$TIPO" in
        E)
            LOG_TAG="$TAG" bash "$S_ESTATICO" "$ARG" 2 >/dev/null 2>&1 &
            ;;
        M)
            SPAWN_TARGETS="$ARG" PEAK_DAY=45 SIM_DAYS=130 \
                bash "$S_SPAWN" >/dev/null 2>&1 &
            ;;
        C)
            N_A=8 N_MAX=64 WAYPOINTS="${ARG}:40" XPN_WAYPOINTS="${ARG}:4" \
                N_XPN_NODES=8 SIM_DAYS=130 RUN_TAG="$TAG" \
                bash "$S_COMALL" >/dev/null 2>&1 &
            ;;
    esac
    PID=$!

    MOTIVO=$(vigila_celda "$PID" "$ORIGEN" "$IOPERF_ESP" "$TMAX")
    wait "$PID" 2>/dev/null
    RC=$?
    DT=$(( $(date +%s) - T0 ))

    # --- Archivado + veredicto ----------------------------------------------
    mkdir -p "$DEST"
    if [ -f "$ORIGEN" ]; then
        cp -f "$ORIGEN" "$ARCHIVADO"
        [ -f "${ORIGEN%.log}_errores.log" ] && cp -f "${ORIGEN%.log}_errores.log" "$DEST/"
        n_io=$(cuenta_ioperf "$ARCHIVADO")
        spread=$(grep -m1 "Spreading time" "$ARCHIVADO" 2>/dev/null | grep -o "[0-9.]*$")
        pop=$(grep -m1 "IOPerf" "$ARCHIVADO" | awk '{print $9}')
        ranks=$(grep -o "NumRanks: [0-9]*" "$ARCHIVADO" | tail -1)
        if [ "$n_io" -ge "$((IOPERF_ESP - 1))" ]; then
            log "<<< [$i] OK  motivo=$MOTIVO rc=$RC ${DT}s  Spreading=${spread:-no impreso}  IOPerf=$n_io  pop=$pop  ${ranks:-sin NumRanks}"
            RESUMEN+=("OK       $TAG  IOPerf=$n_io  Spreading=${spread:-n/d}  pop=$pop  ${ranks}  ${DT}s  ($MOTIVO)")
        else
            log "<<< [$i] INCOMPLETA  motivo=$MOTIVO rc=$RC ${DT}s  IOPerf=$n_io/$IOPERF_ESP  -> sigo con la siguiente"
            RESUMEN+=("PARCIAL  $TAG  IOPerf=$n_io/$IOPERF_ESP  ${DT}s  ($MOTIVO)")
        fi
    else
        log "<<< [$i] FALLO: no se genero $ORIGEN  motivo=$MOTIVO rc=$RC ${DT}s -> sigo con la siguiente"
        RESUMEN+=("FALLO    $TAG  sin log  ${DT}s  ($MOTIVO)")
    fi
done

limpiar_restos
log "===== FIN LOTE CE3 FASE $FASE ====="
for r in "${RESUMEN[@]}"; do log "   $r"; done
