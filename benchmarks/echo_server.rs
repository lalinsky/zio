use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Barrier;
use std::sync::Arc;

const NUM_CLIENTS: usize = 10;
const MESSAGES_PER_CLIENT: usize = 10_000;
const MESSAGE_SIZE: usize = 64;
const SERVER_ADDR: &str = "127.0.0.1:45680";

async fn handle_client(mut stream: TcpStream) {
    let mut buffer = [0u8; MESSAGE_SIZE];

    loop {
        match stream.read(&mut buffer).await {
            Ok(0) => break,
            Ok(n) => {
                if let Err(e) = stream.write_all(&buffer[..n]).await {
                    eprintln!("Error writing: {}", e);
                    break;
                }
            }
            Err(e) => {
                eprintln!("Error reading: {}", e);
                break;
            }
        }
    }
}

async fn server_task(ready: Arc<Barrier>, done: Arc<Barrier>) {
    let listener = TcpListener::bind(SERVER_ADDR).await.unwrap();

    ready.wait().await;

    let mut clients_handled = 0;
    while clients_handled < NUM_CLIENTS {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle_client(stream));
                clients_handled += 1;
            }
            Err(e) => {
                eprintln!("Error accepting: {}", e);
            }
        }
    }

    done.wait().await;
}

async fn client_task(
    ready: Arc<Barrier>,
    latencies: Arc<tokio::sync::Mutex<Vec<u64>>>,
    client_id: usize,
) {
    ready.wait().await;

    let mut stream = TcpStream::connect(SERVER_ADDR).await.unwrap();

    let mut send_buffer = [0u8; MESSAGE_SIZE];
    let mut recv_buffer = [0u8; MESSAGE_SIZE];

    // Fill send buffer with some data
    for (i, byte) in send_buffer.iter_mut().enumerate() {
        *byte = (i % 256) as u8;
    }

    let start_idx = client_id * MESSAGES_PER_CLIENT;
    let mut client_latencies = Vec::with_capacity(MESSAGES_PER_CLIENT);

    for _ in 0..MESSAGES_PER_CLIENT {
        let msg_start = Instant::now();

        stream.write_all(&send_buffer).await.unwrap();

        let mut bytes_received = 0;
        while bytes_received < MESSAGE_SIZE {
            let n = stream.read(&mut recv_buffer[bytes_received..]).await.unwrap();
            if n == 0 {
                panic!("Unexpected end of stream");
            }
            bytes_received += n;
        }

        let msg_end = Instant::now();
        client_latencies.push(msg_end.duration_since(msg_start).as_nanos() as u64);
    }

    // Store latencies
    let mut latencies_guard = latencies.lock().await;
    for (i, lat) in client_latencies.iter().enumerate() {
        latencies_guard[start_idx + i] = *lat;
    }
}

fn calculate_percentile(sorted_latencies: &[u64], percentile: f64) -> u64 {
    let idx = (sorted_latencies.len() as f64 * percentile) as usize;
    sorted_latencies[idx.min(sorted_latencies.len() - 1)]
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    println!("Echo Server Benchmark");
    println!("  Clients: {}", NUM_CLIENTS);
    println!("  Messages per client: {}", MESSAGES_PER_CLIENT);
    println!("  Message size: {} bytes", MESSAGE_SIZE);
    println!("  Total messages: {}\n", NUM_CLIENTS * MESSAGES_PER_CLIENT);

    let server_ready = Arc::new(Barrier::new(NUM_CLIENTS + 2)); // +1 for server, +1 for main
    let server_done = Arc::new(Barrier::new(2)); // server and main

    // Allocate latency tracking
    let total_messages = NUM_CLIENTS * MESSAGES_PER_CLIENT;
    let latencies = Arc::new(tokio::sync::Mutex::new(vec![0u64; total_messages]));

    // Start server
    let server_ready_clone = server_ready.clone();
    let server_done_clone = server_done.clone();
    tokio::spawn(server_task(server_ready_clone, server_done_clone));

    // Spawn all clients
    let mut client_handles = Vec::new();
    for i in 0..NUM_CLIENTS {
        let ready = server_ready.clone();
        let lats = latencies.clone();
        client_handles.push(tokio::spawn(client_task(ready, lats, i)));
    }

    // Signal everyone is ready
    server_ready.wait().await;

    let start = Instant::now();

    // Wait for all clients to complete
    for handle in client_handles {
        handle.await.unwrap();
    }

    let end = Instant::now();

    // Signal server to shut down
    server_done.wait().await;

    // Calculate statistics
    let elapsed = end.duration_since(start);
    let elapsed_ns = elapsed.as_nanos() as u64;
    let elapsed_ms = elapsed_ns as f64 / 1_000_000.0;
    let elapsed_s = elapsed_ms / 1000.0;

    let messages_per_sec = total_messages as f64 / elapsed_s;
    let throughput_mbps = (total_messages * MESSAGE_SIZE * 2) as f64 / elapsed_s / (1024.0 * 1024.0);

    // Sort latencies for percentile calculation
    let mut latencies_vec = latencies.lock().await.clone();
    latencies_vec.sort_unstable();

    let p50 = calculate_percentile(&latencies_vec, 0.50);
    let p95 = calculate_percentile(&latencies_vec, 0.95);
    let p99 = calculate_percentile(&latencies_vec, 0.99);

    let sum: u64 = latencies_vec.iter().sum();
    let avg = sum / latencies_vec.len() as u64;

    println!("Results:");
    println!("  Total time: {:.2} ms ({:.3} s)", elapsed_ms, elapsed_s);
    println!("  Messages/sec: {:.0}", messages_per_sec);
    println!("  Throughput: {:.2} MB/s (rx+tx)", throughput_mbps);
    println!("\nLatency (round-trip):");
    println!("  Average: {:.1} µs", avg as f64 / 1000.0);
    println!("  p50: {:.1} µs", p50 as f64 / 1000.0);
    println!("  p95: {:.1} µs", p95 as f64 / 1000.0);
    println!("  p99: {:.1} µs", p99 as f64 / 1000.0);
}
