package main

import (
	"fmt"
	"sort"
	"strconv"
)

func main() {
	seed := 42
	words := make([]string, 0)
	for i := 0; i < 2_000_000; i++ {
		seed = (seed*1103515245 + 12345) % 2147483648
		words = append(words, "w"+strconv.Itoa(seed%50000))
	}
	counts := map[string]int{}
	for _, w := range words {
		counts[w]++
	}
	type kv struct {
		k string
		v int
	}
	all := make([]kv, 0, len(counts))
	for k, v := range counts {
		all = append(all, kv{k, v})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].v > all[j].v })
	fmt.Println(len(counts), all[:3])
}
