package main

import (
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	NUM_CLIENTS          = 10
	MESSAGES_PER_CLIENT  = 50_000
	MESSAGE_SIZE         = 64
	SERVER_ADDR          = "127.0.0.1:45679"
)

func handleClient(conn net.Conn) {
	defer conn.Close()

	buffer := make([]byte, MESSAGE_SIZE)

	for {
		n, err := conn.Read(buffer)
		if err != nil {
			if err != io.EOF {
				fmt.Printf("Error reading: %v\n", err)
			}
			break
		}

		if n == 0 {
			break
		}

		_, err = conn.Write(buffer[:n])
		if err != nil {
			fmt.Printf("Error writing: %v\n", err)
			break
		}
	}
}

func serverTask(ready chan struct{}, done chan struct{}) {
	listener, err := net.Listen("tcp", SERVER_ADDR)
	if err != nil {
		panic(fmt.Sprintf("Failed to listen: %v", err))
	}
	defer listener.Close()

	close(ready)

	clientsHandled := 0
	for clientsHandled < NUM_CLIENTS {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Printf("Error accepting: %v\n", err)
			continue
		}

		go handleClient(conn)
		clientsHandled++
	}

	<-done
}

func clientTask(ready chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()

	<-ready

	conn, err := net.Dial("tcp", SERVER_ADDR)
	if err != nil {
		panic(fmt.Sprintf("Failed to connect: %v", err))
	}
	defer conn.Close()

	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)
	}

	sendBuffer := make([]byte, MESSAGE_SIZE)
	recvBuffer := make([]byte, MESSAGE_SIZE)

	// Fill send buffer with some data
	for i := range sendBuffer {
		sendBuffer[i] = byte(i % 256)
	}

	for i := 0; i < MESSAGES_PER_CLIENT; i++ {
		_, err := conn.Write(sendBuffer)
		if err != nil {
			panic(fmt.Sprintf("Failed to write: %v", err))
		}

		bytesReceived := 0
		for bytesReceived < MESSAGE_SIZE {
			n, err := conn.Read(recvBuffer[bytesReceived:])
			if err != nil {
				panic(fmt.Sprintf("Failed to read: %v", err))
			}
			if n == 0 {
				panic("Unexpected end of stream")
			}
			bytesReceived += n
		}
	}
}

func main() {
	fmt.Println("Echo Server Benchmark")
	fmt.Printf("  Clients: %d\n", NUM_CLIENTS)
	fmt.Printf("  Messages per client: %d\n", MESSAGES_PER_CLIENT)
	fmt.Printf("  Message size: %d bytes\n", MESSAGE_SIZE)
	fmt.Printf("  Total messages: %d\n\n", NUM_CLIENTS*MESSAGES_PER_CLIENT)

	serverReady := make(chan struct{})
	serverDone := make(chan struct{})

	totalMessages := NUM_CLIENTS * MESSAGES_PER_CLIENT

	// Start server
	go serverTask(serverReady, serverDone)

	// Wait for server to be ready
	<-serverReady

	start := time.Now()

	// Spawn all clients
	var wg sync.WaitGroup
	for i := 0; i < NUM_CLIENTS; i++ {
		wg.Add(1)
		go clientTask(serverReady, &wg)
	}

	// Wait for all clients to complete
	wg.Wait()

	end := time.Now()

	// Signal server to shut down
	close(serverDone)

	// Calculate statistics
	elapsed := end.Sub(start)
	elapsedNs := elapsed.Nanoseconds()
	elapsedMs := float64(elapsedNs) / 1_000_000.0
	elapsedS := elapsedMs / 1000.0

	messagesPerSec := float64(totalMessages) / elapsedS
	throughputMBps := (float64(totalMessages*MESSAGE_SIZE*2) / elapsedS) / (1024.0 * 1024.0)

	fmt.Println("Results:")
	fmt.Printf("  Total time: %.2f ms (%.3f s)\n", elapsedMs, elapsedS)
	fmt.Printf("  Messages/sec: %.0f\n", messagesPerSec)
	fmt.Printf("  Throughput: %.2f MB/s (rx+tx)\n", throughputMBps)
}
