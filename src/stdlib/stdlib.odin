package stdlib

import l"core:sys/linux"

@(export)
print :: proc "contextless" (cstr: cstring) {
    buf := transmute([]u8)string(cstr)
    newline_str := "\n"
    newline := transmute([]u8)newline_str
    l.write(1, buf)
    l.write(1, newline)
}