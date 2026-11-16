fn binary_search(items [int], target int) int
    lo, hi = 0, len(items) - 1
    while lo <= hi
        mid = (lo + hi) / 2
        if items[mid] == target then return mid
        if items[mid] < target then lo = mid + 1 else hi = mid - 1
    -1

xs = [1, 3, 5, 7, 9, 11]
print binary_search(xs, 7), binary_search(xs, 4)
