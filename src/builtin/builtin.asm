format ELF64

; Builtin Functions for Rover
;--------------------
; Mainly a wrapper around system calls.
; Adhere to System V calling convention not the Kernel one
;--------------------


section '.text' executable

public print

print:
    call .sys_write ; params for sys_write should still be in the registers
    lea rdi, [newline]
    call .sys_write
    ret

.sys_write:
    mov rax, 1           ; syscall: write
    mov rsi, rdi         ; string pointer (passed in rdi)
    mov rdi, 1           ; file descriptor: stdout
    xor rdx, rdx    ; Clear rcx, holds string length
.find_null:
    cmp byte [rsi + rdx], 0 ; Check for null terminator
    je .done_length       ; If null terminator found, exit loop
    inc rdx              ; Increment counter
    jmp .find_null
.done_length:
    syscall 
    ret                  

section '.data' writeable
    newline: db 10, 0