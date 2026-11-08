#!/bin/bash
set -euo pipefail

SERVER="clnode341.clemson.cloudlab.us"
USER="jsoares"

echo "Waiting for ${SERVER} to respond to SSH after reboot..."
while ! ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no "${USER}@${SERVER}" "uptime" 2>/dev/null; do
    sleep 3
done

echo "Server is UP! Cleaning up and pulling latest code..."
ssh "${USER}@${SERVER}" bash -s << 'EOF'
set -x
tmux kill-session -t trex_bench 2>/dev/null || true
sudo pkill -9 -f "xhttp" 2>/dev/null || true
sudo rmmod xhttp_tso 2>/dev/null || true

cd /users/jsoares/xhttp
git fetch origin
git reset --hard origin/main
make clean
make -j$(nproc)

echo "Starting 8-core quick benchmark (1 run, 30s)..."
tmux new-session -d -s trex_bench 'cd /users/jsoares/xhttp && source tests/cloudlab.env && NUM_CORES=8 DURATION=30 RUNS=1 AUTO_RERUN=false bash tests/run_keepalive_suite_trex.sh results/cloudlab_trex_keepalive_8cores_quick 2>&1 | tee bench_8cores_quick.log'
EOF

echo "Benchmark launched in tmux on server!"
