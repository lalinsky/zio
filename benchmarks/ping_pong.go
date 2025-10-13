package main

import (
	"fmt"
	"time"
)

const NUM_ROUNDS = 1_000_000

func pinger(pingCh chan<- uint32, pongCh <-chan uint32, rounds uint32, done chan<- bool) {
	for i := uint32(0); i < rounds; i++ {
		pingCh <- i
		<-pongCh
	}
	done <- true
}

func ponger(pingCh <-chan uint32, pongCh chan<- uint32, rounds uint32, done chan<- bool) {
	for i := uint32(0); i < rounds; i++ {
		value := <-pingCh
		pongCh <- value
	}
	done <- true
}

func main() {
	// Create buffered channels with capacity 1 for ping-pong communication
	pingCh := make(chan uint32, 1)
	pongCh := make(chan uint32, 1)
	pingDone := make(chan bool)
	pongDone := make(chan bool)

	fmt.Printf("Running ping-pong benchmark with %d rounds...\n", NUM_ROUNDS)

	start := time.Now()

	// Spawn goroutines
	go pinger(pingCh, pongCh, NUM_ROUNDS, pingDone)
	go ponger(pingCh, pongCh, NUM_ROUNDS, pongDone)

	// Wait for both to complete
	<-pingDone
	<-pongDone

	elapsed := time.Since(start)
	elapsedNs := elapsed.Nanoseconds()
	elapsedMs := float64(elapsedNs) / 1_000_000.0
	elapsedS := elapsedMs / 1000.0

	totalMessages := NUM_ROUNDS * 2 // Each round involves 2 messages (ping + pong)
	messagesPerSec := float64(totalMessages) / elapsedS
	nsPerRound := float64(elapsedNs) / float64(NUM_ROUNDS)

	fmt.Println("\nResults:")
	fmt.Printf("  Total rounds: %d\n", NUM_ROUNDS)
	fmt.Printf("  Total time: %.2f ms (%.3f s)\n", elapsedMs, elapsedS)
	fmt.Printf("  Time per round: %.0f ns\n", nsPerRound)
	fmt.Printf("  Messages/sec: %.0f\n", messagesPerSec)
	fmt.Printf("  Rounds/sec: %.0f\n", messagesPerSec/2.0)
}
