package main

import (
	"fmt"
	"sort"
)

func main() {
	seed := 7
	xs := make([]float64, 0)
	for i := 0; i < 3_000_000; i++ {
		seed = (seed*1103515245 + 12345) % 2147483648
		xs = append(xs, float64(seed%1_000_000)/1000.0)
	}
	sort.Float64s(xs)
	total := 0.0
	for i, x := range xs {
		total += x * float64(i%7)
	}
	fmt.Println(xs[0], xs[len(xs)/2], fmt.Sprintf("%.1f", total))
}
