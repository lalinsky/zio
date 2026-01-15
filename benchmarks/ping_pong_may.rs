use std::time::Instant;
use may::sync::mpsc;
use may::go;

const NUM_ROUNDS: u32 = 10_000_000;

fn pinger(ping_tx: mpsc::Sender<u32>, pong_rx: mpsc::Receiver<u32>, rounds: u32) {
    for i in 0..rounds {
        ping_tx.send(i).unwrap();
        pong_rx.recv().unwrap();
    }
}

fn ponger(ping_rx: mpsc::Receiver<u32>, pong_tx: mpsc::Sender<u32>, rounds: u32) {
    for _ in 0..rounds {
        let value = ping_rx.recv().unwrap();
        pong_tx.send(value).unwrap();
    }
}

fn main() {
    may::config().set_workers(num_cpus::get());

    let (ping_tx, ping_rx) = mpsc::channel();
    let (pong_tx, pong_rx) = mpsc::channel();

    println!("Running ping-pong benchmark with {} rounds...", NUM_ROUNDS);

    let start = Instant::now();

    let pinger_handle = go!(move || pinger(ping_tx, pong_rx, NUM_ROUNDS));
    let ponger_handle = go!(move || ponger(ping_rx, pong_tx, NUM_ROUNDS));

    pinger_handle.join().unwrap();
    ponger_handle.join().unwrap();

    let elapsed = start.elapsed();
    let elapsed_ns = elapsed.as_nanos() as u64;
    let elapsed_ms = elapsed_ns as f64 / 1_000_000.0;
    let elapsed_s = elapsed_ms / 1000.0;

    let total_messages = NUM_ROUNDS * 2;
    let messages_per_sec = total_messages as f64 / elapsed_s;
    let ns_per_round = elapsed_ns as f64 / NUM_ROUNDS as f64;

    println!("\nResults:");
    println!("  Total rounds: {}", NUM_ROUNDS);
    println!("  Total time: {:.2} ms ({:.3} s)", elapsed_ms, elapsed_s);
    println!("  Time per round: {:.0} ns", ns_per_round);
    println!("  Messages/sec: {:.0}", messages_per_sec);
    println!("  Rounds/sec: {:.0}", messages_per_sec / 2.0);
}
