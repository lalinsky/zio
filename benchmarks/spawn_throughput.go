package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

const NUM_SPAWNS = 1_000_000

var counter atomic.Uint64

func main() {
	fmt.Printf("Running spawn throughput benchmark with %d spawns...\n", NUM_SPAWNS)

	start := time.Now()

	var wg sync.WaitGroup

	for i := 0; i < NUM_SPAWNS; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			counter.Add(1)
		}()
	}

	wg.Wait()

	elapsed := time.Since(start)
	elapsedNs := elapsed.Nanoseconds()
	elapsedMs := float64(elapsedNs) / 1_000_000.0
	elapsedS := elapsedMs / 1000.0

	spawnsPerSec := float64(NUM_SPAWNS) / elapsedS
	nsPerSpawn := float64(elapsedNs) / float64(NUM_SPAWNS)

	fmt.Printf("\nResults:\n")
	fmt.Printf("  Total spawns: %d\n", NUM_SPAWNS)
	fmt.Printf("  Completed: %d\n", counter.Load())
	fmt.Printf("  Total time: %.2f ms\n", elapsedMs)
	fmt.Printf("  Time per spawn: %.0f ns\n", nsPerSpawn)
	fmt.Printf("  Spawns/sec: %.0f\n", spawnsPerSec)
}
