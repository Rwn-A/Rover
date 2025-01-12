format ELF64

section '.text' executable

public print

print:
    push rbp
    mov rbp, rsp

    call .sys_write ; params for sys_write should still be in the registers

    lea rdi, [newline]

    call .sys_write

    mov rsp, rbp
    pop rbp
    ret


.sys_write:
    ; rdi contains the pointer to the null-terminated string
    push rbp             ; Save base pointer
    mov rbp, rsp         ; Establish new stack frame

    ; Prepare arguments for the write syscall
    mov rax, 1           ; syscall: write
    mov rsi, rdi         ; string pointer (passed in rdi)
    mov rdi, 1           ; file descriptor: stdout

    ; Calculate string length
    xor rcx, rcx         ; Clear rcx
.find_null:
    cmp byte [rsi + rcx], 0 ; Check for null terminator
    je .done_length       ; If null terminator found, exit loop
    inc rcx              ; Increment counter
    jmp .find_null
.done_length:
    mov rdx, rcx         ; Length of string

    ; Make the syscall
    syscall

    mov rsp, rbp
    pop rbp              ; Restore base pointer
    ret                  ; Return to caller

section '.data' writeable
    newline: db 10, 0