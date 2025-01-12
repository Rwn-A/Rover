package stdlib

import "base:intrinsics"

SYS_write :: uintptr(1)

@(export)
print :: proc "contextless" (cstr: cstring) {
    buf := transmute([]u8)string(cstr)
    newline_str := "\n"
    newline := transmute([]u8)newline_str
    intrinsics.syscall(SYS_write, 1, uintptr(raw_data(buf)), uintptr(len(buf)))
    intrinsics.syscall(SYS_write, 1, uintptr(raw_data(newline)), uintptr(len(newline)))

}