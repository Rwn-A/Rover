package compiler

last :: proc(arr: [dynamic]$T) -> ^T {
    return &arr[last_idx(arr)]
}

last_idx :: proc(arr: [dynamic]$T) -> int {
    return len(arr) - 1
}