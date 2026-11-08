#!/bin/bash
# ==============================================================================
# Sincronizador Contínuo de Resultados do CloudLab para a Máquina Local
#
# Uso:
#   scripts/sync_trex_results.sh [server-host] [intervalo-segundos]
# Exemplo:
#   scripts/sync_trex_results.sh clnode341.clemson.cloudlab.us 3
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
LOCAL_RESULTS_DIR="$(cd "${REPO_ROOT}/../xhttp" 2>/dev/null && pwd)/results"

SERVER="${1:-clnode341.clemson.cloudlab.us}"
INTERVAL="${2:-3}"
CL_USER="${CL_USER:-jsoares}"

mkdir -p "${LOCAL_RESULTS_DIR}"

echo "=========================================================================="
echo "🔄 SINCRONIZADOR CONTÍNUO DE RESULTADOS DO CLOUDLAB"
echo "=========================================================================="
echo "  Servidor Remoto:  ${CL_USER}@${SERVER}"
echo "  Destino Local:    ${LOCAL_RESULTS_DIR}"
echo "  Intervalo Poll:   ${INTERVAL}s"
echo "=========================================================================="
echo "Pressione Ctrl+C para encerrar o sincronizador."
echo

LAST_COUNT=0

while true; do
    # Rsync silencioso apenas copiando arquivos novos ou alterados
    rsync -az --update -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes" \
        "${CL_USER}@${SERVER}:/users/${CL_USER}/xhttp/results/" "${LOCAL_RESULTS_DIR}/" 2>/dev/null || true
    
    CURRENT_COUNT=$(find "${LOCAL_RESULTS_DIR}" -name "*.csv" 2>/dev/null | wc -l)
    if [ "${CURRENT_COUNT}" -gt "${LAST_COUNT}" ]; then
        DIFF=$((CURRENT_COUNT - LAST_COUNT))
        if [ "${LAST_COUNT}" -gt 0 ]; then
            echo "[$(date +%T)] 💾 +${DIFF} novos arquivos de resultado sincronizados! (Total local: ${CURRENT_COUNT} CSVs)"
        else
            echo "[$(date +%T)] 💾 Sincronização inicial concluída. Total local: ${CURRENT_COUNT} CSVs."
        fi
        LAST_COUNT="${CURRENT_COUNT}"
    fi

    sleep "${INTERVAL}"
done
