#!/usr/bin/env bash
set -euo pipefail

prefix() {
  sed -e "s|^|$1: |"
}

# Always run the script from the project root
cd "$(dirname "$0")/.."

export export RUST_VERSION=1.60.0 \
       LLVM_GIT_COMMIT=c9e2e89ed3aa5a3be77143aa0c86906b4138374a \
       MUSL_VERSION=1.1.24 \
       TARGET=x86_64-unknown-linux-musl \
       GNU_TARGET="" \
       LINUX_HEADERS_VERSION=5.16.0
       
export COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_BUILDKIT=1

# Build the other docker images
{ time docker-compose build; } |& prefix 'docker' &

# Wait on all builds to finish
wait

docker build -t manifoldfinance/rust-musl-toolchain:$RUST_VERSION-$TARGET \
  --build-arg RUST_VERSION="$RUST_VERSION" \
  --build-arg LLVM_GIT_COMMIT="$LLVM_GIT_COMMIT" \
  --build-arg MUSL_VERSION="$MUSL_VERSION" \
  --build-arg TARGET="$TARGET" \
  --build-arg GNU_TARGET="$GNU_TARGET" \
  --build-arg LINUX_HEADERS_VERSION="$LINUX_HEADERS_VERSION" \
  .
