use std::time::Instant;
use tokio::sync::mpsc;

const NUM_ROUNDS: u32 = 1_000_000;

async fn pinger(
    mut ping_tx: mpsc::Sender<u32>,
    mut pong_rx: mpsc::Receiver<u32>,
    rounds: u32,
) {
    for i in 0..rounds {
        ping_tx.send(i).await.unwrap();
        pong_rx.recv().await.unwrap();
    }
}

async fn ponger(
    mut ping_rx: mpsc::Receiver<u32>,
    mut pong_tx: mpsc::Sender<u32>,
    rounds: u32,
) {
    for _ in 0..rounds {
        let value = ping_rx.recv().await.unwrap();
        pong_tx.send(value).await.unwrap();
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    // Create buffered channels with capacity 1 for ping-pong communication
    let (ping_tx, ping_rx) = mpsc::channel(1);
    let (pong_tx, pong_rx) = mpsc::channel(1);

    println!("Running ping-pong benchmark with {} rounds (current_thread runtime)...", NUM_ROUNDS);

    let start = Instant::now();

    // Spawn tasks
    let pinger_handle = tokio::spawn(pinger(ping_tx, pong_rx, NUM_ROUNDS));
    let ponger_handle = tokio::spawn(ponger(ping_rx, pong_tx, NUM_ROUNDS));

    // Wait for both tasks to complete
    pinger_handle.await.unwrap();
    ponger_handle.await.unwrap();

    let elapsed = start.elapsed();
    let elapsed_ns = elapsed.as_nanos() as u64;
    let elapsed_ms = elapsed_ns as f64 / 1_000_000.0;
    let elapsed_s = elapsed_ms / 1000.0;

    let total_messages = NUM_ROUNDS * 2; // Each round involves 2 messages (ping + pong)
    let messages_per_sec = total_messages as f64 / elapsed_s;
    let ns_per_round = elapsed_ns as f64 / NUM_ROUNDS as f64;

    println!("\nResults:");
    println!("  Total rounds: {}", NUM_ROUNDS);
    println!("  Total time: {:.2} ms ({:.3} s)", elapsed_ms, elapsed_s);
    println!("  Time per round: {:.0} ns", ns_per_round);
    println!("  Messages/sec: {:.0}", messages_per_sec);
    println!("  Rounds/sec: {:.0}", messages_per_sec / 2.0);
}
