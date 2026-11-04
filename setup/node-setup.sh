#!/bin/bash
# Prepares a CloudLab node for the xHTTP benchmark. Run as root by the
# profile's Execute service at every boot; each stage leaves a marker in
# /local/setup-state and is skipped once done, so a reboot resumes where the
# previous boot stopped.
#
#   node-setup.sh server [baselines]
#   node-setup.sh client
#
# Log: /local/logs/setup.log. Ready when /local/setup-state/done exists.

set -euo pipefail

ROLE="${1:?server or client}"
BASELINES="${2:-}"
STATE=/local/setup-state
LOGDIR=/local/logs
BASE=/local/baselines

# Forks used in the article's measurements; override when instantiating by
# editing these lines in your copy of the repository.
KHTTPD_REPO=https://github.com/ojoaosoares/khttpd.git
KHTTPD_REF=master
FASTPATH_REPO=https://github.com/ojoaosoares/hyper-fast-path.git
FASTPATH_REF=xhttp-bench
WRK_REPO=https://github.com/wg/wrk.git
WRK2_REPO=https://github.com/giltene/wrk2.git

mkdir -p "${STATE}" "${LOGDIR}" "${BASE}"
exec >>"${LOGDIR}/setup.log" 2>&1
echo "=== $(date -Is) node-setup ${ROLE} ${BASELINES} (kernel $(uname -r))"

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

done_() { touch "${STATE}/$1"; echo "--- stage $1 done"; }
has() { [ -e "${STATE}/$1" ]; }

# 1. Kernel 7.0 (Ubuntu 24.04 HWE). Reboots once; this script runs again.
if ! has kernel; then
    if [ "$(uname -r | cut -d. -f1)" -lt 7 ]; then
        ${APT} update
        ${APT} install linux-generic-hwe-24.04
        echo "--- rebooting into the HWE kernel"
        touch "${STATE}/kernel-installed"
        sync
        reboot
        exit 0
    fi
    done_ kernel
fi

# 2. Packages both nodes need.
if ! has packages; then
    ${APT} update
    ${APT} install build-essential git clang clang-20 llvm libelf-dev zlib1g-dev \
        libbpf-dev libssl-dev pkg-config dwarves bison flex \
        "linux-headers-$(uname -r)" "linux-tools-$(uname -r)" linux-tools-common \
        ethtool iproute2 tmux rsync jq curl numactl python3 python3-pip \
        python3-matplotlib python3-numpy
    systemctl disable --now irqbalance 2>/dev/null || true
    done_ packages
fi

# 3. resolve_btfids for the xHTTP kernel module. Ubuntu's headers package does
#    not ship it; it is built from the kernel's tools/ into the place
#    kmod/Makefile looks for it ($(KDIR)/tools/bpf/resolve_btfids).
if [ "${ROLE}" = server ] && ! has resolve_btfids; then
    kdir="/lib/modules/$(uname -r)/build"
    out="$(readlink -f "${kdir}")/tools/bpf/resolve_btfids"
    ver=$(uname -r | cut -d- -f1)           # 7.0.0
    tag="v${ver%.0}"                        # v7.0
    src="${BASE}/linux-tools"
    rm -rf "${src}"
    git clone --depth 1 --filter=blob:none --sparse --branch "${tag}" \
        https://github.com/torvalds/linux.git "${src}"
    git -C "${src}" sparse-checkout set tools scripts include/uapi include/linux
    mkdir -p "${out}"
    make -C "${src}/tools/bpf/resolve_btfids" OUTPUT="${out}/" -j"$(nproc)"
    test -x "${out}/resolve_btfids"
    done_ resolve_btfids
fi

# 4. Server software: nginx (driven by the benchmark, not by systemd), Go for
#    the test backend, and the baselines.
if [ "${ROLE}" = server ] && ! has server; then
    ${APT} install nginx golang-go
    systemctl disable --now nginx 2>/dev/null || true
    done_ server
fi

if [ "${ROLE}" = server ] && [ "${BASELINES}" = baselines ] && ! has baselines; then
    # khttpd (kernel module)
    rm -rf "${BASE}/khttpd"
    git clone "${KHTTPD_REPO}" "${BASE}/khttpd"
    git -C "${BASE}/khttpd" checkout "${KHTTPD_REF}"
    make -C "${BASE}/khttpd" -j"$(nproc)"

    # hyper-fast-path: Rust 2024 edition, newer than Ubuntu's rustc
    export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
    if [ ! -x /opt/rust/bin/cargo ]; then
        curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
    fi
    export PATH="/opt/rust/bin:${PATH}"
    rm -rf "${BASE}/hyper-fast-path"
    git clone "${FASTPATH_REPO}" "${BASE}/hyper-fast-path"
    git -C "${BASE}/hyper-fast-path" checkout "${FASTPATH_REF}"
    (cd "${BASE}/hyper-fast-path" && cargo build --release --bin example)
    chmod -R a+rX "${BASE}"
    done_ baselines
fi

# 5. Client software: wrk and wrk2 on PATH (wrk2 as "wrk2").
if [ "${ROLE}" = client ] && ! has client; then
    for r in wrk wrk2; do
        repo=WRK_REPO; [ "$r" = wrk2 ] && repo=WRK2_REPO
        rm -rf "${BASE}/${r}"
        git clone --depth 1 "${!repo}" "${BASE}/${r}"
        make -C "${BASE}/${r}" -j"$(nproc)"
        install -m 755 "${BASE}/${r}/wrk" "/usr/local/bin/${r}"
    done
    done_ client
fi

done_ done
echo "=== $(date -Is) node ready"
