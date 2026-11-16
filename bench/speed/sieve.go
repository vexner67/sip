package main

import "fmt"

func main() {
	n := 20_000_000
	isP := make([]bool, n+1)
	for i := range isP {
		isP[i] = true
	}
	isP[0], isP[1] = false, false
	for i := 2; i*i <= n; i++ {
		if isP[i] {
			for j := i * i; j <= n; j += i {
				isP[j] = false
			}
		}
	}
	c := 0
	for _, x := range isP {
		if x {
			c++
		}
	}
	fmt.Println(c)
}
