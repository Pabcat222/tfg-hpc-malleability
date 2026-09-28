#!/bin/bash
# ce4_deps.sh — instala en TODOS los contenedores las librerías que la imagen no
# trae (libglpk, libgsl, libpapi). Sin ellas epiGraph muere nada más arrancar con
# "libglpk.so.40: cannot open shared object file". Idempotente.
# Ejecutar DENTRO del contenedor #1.
set -u
MACHINES="/work/machines_mpi"
pkgs="libglpk40 libglpk-dev libgsl-dev libpapi-dev"

command -v sshpass >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq sshpass; }

ok=0; fail=0
while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if sshpass -p lab ssh -n -o StrictHostKeyChecking=no -o PreferredAuthentications=password lab@"$ip" \
          "dpkg -s libglpk40 >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq $pkgs; }" >/dev/null 2>&1; then
        ok=$((ok+1))
    else
        fail=$((fail+1)); echo "  fallo en $ip"
    fi
done < "$MACHINES"
echo "deps: $ok OK, $fail fallos"
exit $(( fail > 0 ? 1 : 0 ))
