#!/bin/bash
# Run on YOUR machine once both CloudLab nodes are ready. It:
#   1. waits until both nodes finished setup (/local/setup-state/done);
#   2. clones xHTTP on the server (~/xhttp) and builds it. The repository is
#      private: the clone uses YOUR GitHub key through SSH agent forwarding
#      (ssh -A), so no key or token is ever stored on the node;
#   3. lets the server SSH into the client without a password;
#   4. finds the 100G interfaces and the NIC's largest RX ring;
#   5. writes ~/xhttp/tests/cloudlab.env on the server for the benchmarks.
#
#   scripts/bootstrap.sh <server-host> <client-host> [xhttp-ref]
#
# [xhttp-ref]: branch, tag or commit to check out (default feat/tc-crypto). It
# must be pushed: uncommitted or local-only changes do not reach the node.
# Run again to update: it fetches and checks out the ref again.
#
# <server-host>/<client-host>: the nodes' names from the experiment's
# "List View" (e.g. clnode123.clemson.cloudlab.us). CL_USER overrides the
# login (default: your local user name).

set -euo pipefail

SERVER="${1:?server host}"
CLIENT="${2:?client host}"
XHTTP_REF="${3:-feat/tc-crypto}"
XHTTP_REPO="${XHTTP_REPO:-git@github.com:ojoaosoares/xhttp.git}"
CL_USER="${CL_USER:-${USER}}"
SERVER_IP="${SERVER_IP:-10.10.1.1}"
CLIENT_IP="${CLIENT_IP:-10.10.1.2}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

s() { ssh "${SSH_OPTS[@]}" "${CL_USER}@${SERVER}" "$@"; }
sa() { ssh -A "${SSH_OPTS[@]}" "${CL_USER}@${SERVER}" "$@"; }   # with your agent
c() { ssh "${SSH_OPTS[@]}" "${CL_USER}@${CLIENT}" "$@"; }

if ! ssh-add -l >/dev/null 2>&1; then
    echo "Nenhuma chave no ssh-agent. Rode antes:"
    echo '  eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519'
    exit 1
fi

echo "-> 1/5 esperando o setup dos dois nós (até 60 min)"
for node in "${SERVER}" "${CLIENT}"; do
    for i in $(seq 1 120); do
        if ssh "${SSH_OPTS[@]}" "${CL_USER}@${node}" test -e /local/setup-state/done 2>/dev/null; then
            echo "   ${node}: pronto ($(ssh "${SSH_OPTS[@]}" "${CL_USER}@${node}" uname -r))"
            break
        fi
        [ "${i}" = 120 ] && { echo "   ${node}: setup não terminou; veja /local/logs/setup.log"; exit 1; }
        sleep 30
    done
done

echo "-> 2/5 clonando xHTTP (${XHTTP_REF}) em ${SERVER}:~/xhttp"
sa "export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'
    set -e
    [ -d ~/xhttp/.git ] || git clone -q ${XHTTP_REPO} ~/xhttp
    cd ~/xhttp
    git fetch -q origin
    git checkout -q ${XHTTP_REF}
    git merge -q --ff-only origin/${XHTTP_REF} 2>/dev/null || true
    echo \"   \$(git log -1 --format='%h %s')\"
    make -j\$(nproc) >/dev/null"
echo "   build ok"

echo "-> 3/5 chave SSH do servidor para o cliente"
s 'test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
pub=$(s cat '~/.ssh/id_ed25519.pub')
c "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '${pub}' ~/.ssh/authorized_keys || echo '${pub}' >> ~/.ssh/authorized_keys"
s "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes ${CL_USER}@${CLIENT} true"
echo "   servidor -> cliente sem senha ok"

echo "-> 4/5 interfaces de 100G"
iface_of() { awk -v ip="$1" '$4 ~ "^"ip"/" { print $2; exit }'; }
SIF=$(s ip -o -4 addr show | iface_of "${SERVER_IP}")
CIF=$(c ip -o -4 addr show | iface_of "${CLIENT_IP}")
[ -n "${SIF}" ] && [ -n "${CIF}" ] || { echo "   não achei ${SERVER_IP}/${CLIENT_IP}"; exit 1; }
SPEED=$(s cat "/sys/class/net/${SIF}/speed")
RING=$(s "ethtool -g ${SIF}" | awk '/^Pre-set/ { m = 1 } m && /^RX:/ { print $2; exit }')
echo "   servidor ${SIF} (${SPEED} Mbit/s, anel RX máx ${RING}), cliente ${CIF}"
[ "${SPEED}" -ge 100000 ] || echo "   AVISO: o link não está a 100 Gbit/s"
TLS_OFF=$(s "ethtool -k ${SIF}" | awk '/tls-hw-(tx|rx)-offload/ && $2 == "on"' | wc -l)

echo "-> 5/5 escrevendo ~/xhttp/tests/cloudlab.env"
s "cat > ~/xhttp/tests/cloudlab.env" <<EOF
# Gerado por xhttp-cloudlab/scripts/bootstrap.sh em $(date -Is)
export SERVER_INTERFACE=${SIF}
export SERVER_IP=${SERVER_IP}
export REMOTE_USER=${CL_USER}
export REMOTE_HOST=${CLIENT}
export REMOTE_CLIENT_INTERFACE=${CIF}
export REMOTE_CLIENT_IP=${CLIENT_IP}
export REMOTE_BASE_DIR=/users/${CL_USER}/xhttp-client
export BENCH_ENV_RX_RING=${RING}
export KHTTPD_KO=/local/baselines/khttpd/khttpd.ko
export FASTPATH_BIN=/local/baselines/hyper-fast-path/target/release/example
EOF
if [ "${TLS_OFF}" -gt 0 ]; then
    s "sudo ethtool -K ${SIF} tls-hw-tx-offload off tls-hw-rx-offload off" 2>/dev/null || true
    echo "   offload de TLS da placa desligado (vale até o próximo reboot)"
fi

cat <<EOF

Pronto. No servidor:
  ssh ${CL_USER}@${SERVER}
  tmux new -s bench
  cd ~/xhttp && source tests/cloudlab.env
  NUM_CORES=1 tests/run_comparison_suite.sh 10 results/cloudlab_plain_c16
EOF
