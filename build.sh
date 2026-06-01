#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin"
swiftc -O "$DIR/OpenLid.swift" -o "$DIR/bin/openlid"
echo "Built $DIR/bin/openlid"
