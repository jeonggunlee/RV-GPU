#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHON=${PYTHON:-python3}
"$PYTHON" scripts/gen_vectors.py
rtl=(rtl/*.v rtl/*.sv)
if command -v iverilog >/dev/null 2>&1; then
    compiler=(iverilog); runtime=(vvp)
elif [[ -x /tmp/gpu-iverilog/usr/bin/iverilog ]]; then
    compiler=(/tmp/gpu-iverilog/usr/bin/iverilog -B /tmp/gpu-iverilog/usr/lib/x86_64-linux-gnu/ivl)
    runtime=(/tmp/gpu-iverilog/usr/bin/vvp -M /tmp/gpu-iverilog/usr/lib/x86_64-linux-gnu/ivl)
else
    echo "Icarus Verilog is required. Install iverilog and vvp on PATH." >&2
    exit 1
fi
for tb in tb_core tb_simt_isa tb_simt_control tb_simt_csr tb_gpu tb_uart; do
    "${compiler[@]}" -g2012 -s "$tb" -o "build/$tb" "${rtl[@]}" "sim/$tb.sv"
    "${runtime[@]}" "build/$tb"
    if [[ $tb == tb_gpu ]]; then
        "$PYTHON" scripts/frame.py --hex build/frame.hex --output build/render.ppm --verify
    fi
done
