#!/bin/bash
# =============================================================================
# guardian_antidrain.sh — evita que el nodo quede en DRAIN
#
# Vigila el tiempo que le queda a la reserva y, cuando baja del margen, para los
# contenedores ANTES de que SLURM mate el job. Ésa es la secuencia que evita el
# "Kill task failed" que deja el nodo en drain: primero se paran los
# contenedores, después termina la reserva. Al revés no hay salvación.
#
# VIVE EN EL NODO DE ACCESO (tucan), no en el portátil. Es deliberado: así
# sobrevive a que se caiga el túnel SSH o el VPN, que es justo cuando no puedes
# intervenir a mano.
#
# NO se dispara por la caída del túnel. Que el túnel se caiga es frecuente e
# inofensivo — el 2026-08-09 el VPN estuvo caído ~2,5 h con un lote corriendo
# sin problema. Atar el teardown a la conexión habría destruido el experimento.
# El único disparador es el tiempo restante de la reserva.
#
# USO (desde el portátil, una vez que existe la reserva):
#   ssh tucan 'setsid nohup bash ~/xpn-docker/guardian_antidrain.sh 167631 900 \
#              > ~/xpn-docker/guardian.log 2>&1 < /dev/null &'
#
#   $1 = JOBID de la reserva (obligatorio)
#   $2 = margen en segundos antes del final (por defecto 900 = 15 min)
#
# Comprobar:  ssh tucan 'tail ~/xpn-docker/guardian.log'
# Cancelar:   ssh tucan 'pkill -f "guardian_antidrain.sh <JOBID>"'
# =============================================================================
set -u

JOB="${1:?uso: $0 <jobid> [margen_segundos]}"
MARGEN="${2:-900}"
INTERVALO=60
LOG(){ echo "[$(date '+%F %T')] $*"; }

# "1-02:03:04" | "02:03:04" | "03:04" -> segundos
a_segundos(){
    local t="$1" d=0
    case "$t" in
        *-*) d="${t%%-*}"; t="${t#*-}" ;;
    esac
    local IFS=: ; set -- $t
    # 10# es OBLIGATORIO: squeue rellena con ceros ("4:08:35") y bash interpreta
    # 08 y 09 como octal inválido -> la función abortaba sin imprimir nada, el
    # test de más abajo fallaba con "integer expression expected" y el guardián
    # NUNCA disparaba el teardown. Fallo real observado el 2026-08-09.
    case $# in
        3) echo $(( d*86400 + 10#$1*3600 + 10#$2*60 + 10#$3 )) ;;
        2) echo $(( d*86400 + 10#$1*60 + 10#$2 )) ;;
        1) echo $(( d*86400 + 10#$1 )) ;;
        *) echo 0 ;;
    esac
}

LOG "guardián en marcha: job=$JOB margen=${MARGEN}s intervalo=${INTERVALO}s"

while true; do
    LEFT=$(squeue -h -j "$JOB" -o "%L" 2>/dev/null | tr -d ' ')
    NODOS=$(squeue -h -j "$JOB" -o "%N" 2>/dev/null | tr -d ' ')

    if [ -z "$LEFT" ]; then
        LOG "la reserva $JOB ya no existe — no hay nada que proteger. Salgo."
        exit 0
    fi
    if [ "$LEFT" = "UNLIMITED" ] || [ "$LEFT" = "INVALID" ]; then
        LOG "tiempo restante '$LEFT': no puedo calcular margen. Reintento."
        sleep "$INTERVALO"; continue
    fi

    SEGS=$(a_segundos "$LEFT")
    # Red de seguridad: si el parseo fallara, NO seguir en silencio. Un guardián
    # que no sabe cuánto queda es peor que ninguno, porque da falsa tranquilidad.
    if ! [ "${SEGS:-}" -eq "${SEGS:-}" ] 2>/dev/null; then
        LOG "⚠️  no pude interpretar el tiempo restante ('$LEFT'). Disparo el teardown por precaución."
        SEGS=0
    fi
    if [ "$SEGS" -le "$MARGEN" ]; then
        LOG "quedan ${SEGS}s (<= $MARGEN): TEARDOWN ANTI-DRAIN en [$NODOS]"
        for n in $(scontrol show hostnames "$NODOS" 2>/dev/null); do
            LOG "  -> $n: parando contenedores"
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 "$n" \
                'cd ~/xpn-docker 2>/dev/null && ./xpn_docker.sh stop; \
                 sleep 5; \
                 R=$(docker ps -q); [ -n "$R" ] && docker rm -f $R; \
                 docker swarm leave --force 2>/dev/null; \
                 echo "   quedan $(docker ps -q | wc -l) contenedores"' 2>&1 \
                | sed 's/^/     /'
        done
        LOG "teardown hecho. Ahora la reserva puede terminar sin drenar."
        LOG "si quieres soltarla ya: scancel $JOB (con env -i, ver notas de munge)"
        exit 0
    fi

    # Traza sólo cuando se acerca, para no llenar el log
    [ "$SEGS" -le $(( MARGEN * 4 )) ] && LOG "quedan ${SEGS}s"
    sleep "$INTERVALO"
done
