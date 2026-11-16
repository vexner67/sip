fn sum_even_squares(nums [int]) int = sum(n * n for n in nums if n % 2 == 0)

print sum_even_squares([1, 2, 3, 4, 5, 6])
