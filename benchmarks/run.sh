#!/bin/bash
set -e

cd "$(dirname "$0")/.."

RUNS=${1:-3}
SLEEP=${2:-2}

echo "Building benchmarks..."
zig build benchmarks --release=fast
go build -o benchmarks/ping_pong_go benchmarks/ping_pong.go
go build -o benchmarks/echo_server_go benchmarks/echo_server.go
(cd benchmarks && cargo build --release --quiet)

echo ""
echo "=== Ping-Pong Benchmark ==="
echo ""
echo "--- Zig (zio) ---"
for i in $(seq 1 $RUNS); do
    ./zig-out/bin/ping_pong_benchmark 2>&1 | grep "Time per round"
    sleep $SLEEP
done

echo ""
echo "--- Go ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/ping_pong_go 2>&1 | grep "Time per round"
    sleep $SLEEP
done

echo ""
echo "--- Rust (tokio) ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/target/release/ping_pong_tokio 2>&1 | grep "Time per round"
    sleep $SLEEP
done

echo ""
echo "--- Rust (may) ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/target/release/ping_pong_may 2>&1 | grep "Time per round"
    sleep $SLEEP
done

echo ""
echo "=== Echo Server Benchmark ==="
echo ""
echo "--- Zig (zio) ---"
for i in $(seq 1 $RUNS); do
    ./zig-out/bin/echo_server_benchmark 2>&1 | grep "Messages/sec"
    sleep $SLEEP
done

echo ""
echo "--- Go ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/echo_server_go 2>&1 | grep "Messages/sec"
    sleep $SLEEP
done

echo ""
echo "--- Rust (tokio) ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/target/release/echo_server_tokio 2>&1 | grep "Messages/sec"
    sleep $SLEEP
done

echo ""
echo "--- Rust (may) ---"
for i in $(seq 1 $RUNS); do
    ./benchmarks/target/release/echo_server_may 2>&1 | grep "Messages/sec"
    sleep $SLEEP
done
