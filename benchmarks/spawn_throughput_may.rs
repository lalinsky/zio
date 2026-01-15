use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use may::coroutine;
use may::go;

const NUM_SPAWNS: u64 = 1_000_000;

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn main() {
    may::config().set_workers(num_cpus::get());

    println!("Running spawn throughput benchmark with {} spawns...", NUM_SPAWNS);

    let start = Instant::now();

    coroutine::scope(|scope| {
        for _ in 0..NUM_SPAWNS {
            go!(scope, || {
                COUNTER.fetch_add(1, Ordering::Relaxed);
            });
        }
    });

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
