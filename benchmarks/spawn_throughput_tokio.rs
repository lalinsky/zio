use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use tokio::task::JoinSet;

const NUM_SPAWNS: u64 = 1_000_000;

static COUNTER: AtomicU64 = AtomicU64::new(0);

#[tokio::main]
async fn main() {
    println!("Running spawn throughput benchmark with {} spawns...", NUM_SPAWNS);

    let start = Instant::now();

    let mut set = JoinSet::new();

    for _ in 0..NUM_SPAWNS {
        set.spawn(async {
            COUNTER.fetch_add(1, Ordering::Relaxed);
        });
    }

    // Wait for all tasks to complete
    while set.join_next().await.is_some() {}

    let elapsed = start.elapsed();
    let elapsed_ns = elapsed.as_nanos() as u64;
    let elapsed_ms = elapsed_ns as f64 / 1_000_000.0;
    let elapsed_s = elapsed_ms / 1000.0;

    let spawns_per_sec = NUM_SPAWNS as f64 / elapsed_s;
    let ns_per_spawn = elapsed_ns as f64 / NUM_SPAWNS as f64;

    println!("\nResults:");
    println!("  Total spawns: {}", NUM_SPAWNS);
    println!("  Completed: {}", COUNTER.load(Ordering::Relaxed));
    println!("  Total time: {:.2} ms", elapsed_ms);
    println!("  Time per spawn: {:.0} ns", ns_per_spawn);
    println!("  Spawns/sec: {:.0}", spawns_per_sec);
}
