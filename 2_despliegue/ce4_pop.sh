#!/bin/bash
# ce4_pop.sh {small|large|estado} — conmuta la población de EpiGraph.
# Va en script y no en línea de órdenes porque el anidamiento ssh->ssh->docker exec
# rompe cualquier entrecomillado que lleve comillas dentro.
set -u
EPI="/shared/install-src/EpiGraphFlexMPI-XPN"
D="$EPI/src/data"
cd "$EPI" || exit 1

estado(){
    if [ -L cities ]; then echo "cities  -> ENLACE a $(readlink cities)"
    elif [ -d cities ]; then echo "cities  -> directorio REAL"
    else echo "cities  -> NO EXISTE (¡layout roto!)"; fi
    echo "PopSize -> $(grep -o 'PopSize[^"]*"[0-9]*' "$D/XMLGraphConfigFile.xml" | grep -o '[0-9]*$')"
    echo "hay     -> $(ls -d cities cities.small cities.large 2>/dev/null | tr '\n' ' ')"
}

case "${1:-estado}" in
    small)
        [ -d cities ] && [ ! -L cities ] && mv cities cities.large
        ln -sfn cities.small cities
        cp -f "$D/XMLGraphConfigFile.xml.test" "$D/XMLGraphConfigFile.xml"
        estado ;;
    large)
        if [ -L cities ]; then rm -f cities; [ -d cities.large ] && mv cities.large cities; fi
        cp -f "$D/XMLGraphConfigFile.xml.mad" "$D/XMLGraphConfigFile.xml"
        estado ;;
    estado) estado ;;
    *) echo "uso: $0 {small|large|estado}"; exit 1 ;;
esac
