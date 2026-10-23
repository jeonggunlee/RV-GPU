#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/pdf
for pass in 1 2; do
    xelatex -interaction=nonstopmode -halt-on-error -output-directory=build/pdf \
        docs/simt_architecture_explained_ko.tex > "build/pdf/pass-${pass}.log"
done
cp build/pdf/simt_architecture_explained_ko.pdf docs/simt_architecture_explained_ko.pdf
printf 'PDF: docs/simt_architecture_explained_ko.pdf\n'
