// Package racy has a deliberate data race that only the race detector reports.
package racy

import "sync"

// Count increments a shared counter from two goroutines without synchronization.
func Count() int {
	n := 0
	var wg sync.WaitGroup
	wg.Add(2)
	for i := 0; i < 2; i++ {
		go func() {
			defer wg.Done()
			n++
		}()
	}
	wg.Wait()
	return n
}
