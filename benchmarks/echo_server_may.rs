use std::time::Instant;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use may::go;
use may::coroutine;
use may::net::{TcpListener, TcpStream};

const NUM_CLIENTS: usize = 10;
const MESSAGES_PER_CLIENT: usize = 50_000;
const MESSAGE_SIZE: usize = 64;
const SERVER_ADDR: &str = "127.0.0.1:45682";

fn handle_client(mut stream: TcpStream) {
    let mut buffer = [0u8; MESSAGE_SIZE];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                if stream.write_all(&buffer[..n]).is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}

fn main() {
    may::config().set_workers(num_cpus::get());

    println!("Echo Server Benchmark (May coroutines)");
    println!("  Clients: {}", NUM_CLIENTS);
    println!("  Messages per client: {}", MESSAGES_PER_CLIENT);
    println!("  Message size: {} bytes", MESSAGE_SIZE);
    println!("  Total messages: {}\n", NUM_CLIENTS * MESSAGES_PER_CLIENT);

    let total_messages = NUM_CLIENTS * MESSAGES_PER_CLIENT;
    let clients_done = Arc::new(AtomicUsize::new(0));

    coroutine::scope(|scope| {
        // Start server
        go!(scope, || {
            let listener = TcpListener::bind(SERVER_ADDR).unwrap();

            for stream in listener.incoming() {
                match stream {
                    Ok(s) => {
                        go!(move || handle_client(s));
                    }
                    Err(e) => eprintln!("err = {:?}", e),
                }
            }
        });

        // Give server time to start
        coroutine::sleep(std::time::Duration::from_millis(10));

        let start = Instant::now();

        // Spawn all clients
        for _ in 0..NUM_CLIENTS {
            let clients_done = clients_done.clone();
            go!(scope, move || {
                let mut stream = TcpStream::connect(SERVER_ADDR).unwrap();
                stream.set_nodelay(true).unwrap();

                let mut send_buffer = [0u8; MESSAGE_SIZE];
                let mut recv_buffer = [0u8; MESSAGE_SIZE];

                for (i, byte) in send_buffer.iter_mut().enumerate() {
                    *byte = (i % 256) as u8;
                }

                for _ in 0..MESSAGES_PER_CLIENT {
                    stream.write_all(&send_buffer).unwrap();
                    stream.read_exact(&mut recv_buffer).unwrap();
                }

                clients_done.fetch_add(1, Ordering::Relaxed);
            });
        }

        // Wait for all clients
        while clients_done.load(Ordering::Relaxed) < NUM_CLIENTS {
            coroutine::sleep(std::time::Duration::from_millis(1));
        }

        let elapsed = start.elapsed();
        let elapsed_ns = elapsed.as_nanos() as u64;
        let elapsed_ms = elapsed_ns as f64 / 1_000_000.0;
        let elapsed_s = elapsed_ms / 1000.0;

        let messages_per_sec = total_messages as f64 / elapsed_s;
        let throughput_mbps = (total_messages * MESSAGE_SIZE * 2) as f64 / elapsed_s / (1024.0 * 1024.0);

        println!("Results:");
        println!("  Total time: {:.2} ms ({:.3} s)", elapsed_ms, elapsed_s);
        println!("  Messages/sec: {:.0}", messages_per_sec);
        println!("  Throughput: {:.2} MB/s (rx+tx)", throughput_mbps);

        // Exit the scope (kills server)
        std::process::exit(0);
    });
}
