package compiler

import "core:mem"

Instruction :: struct {
    opcode: Opcode,
    result: Symbol_ID,
    arg_1: Argument,
    arg_2: Argument,
}

Temporary :: distinct int

Argument :: union {
    Symbol_ID,
    Temporary,
    string, //label
}

Opcode :: enum {
    Load,
    Store,
    Assign,
    Call,
    Add,
    Sub,
    Mul,
    Div,
    Function, //definition, not a call, basically a label with some meta-data
}

IR_Program :: []Instruction

IR_Context :: struct {
    sm: Scope_Manager,
    program_buffer: [dynamic]Instruction,
}

ir_init :: proc(ctx: ^IR_Context, pool: ^Symbol_Pool, allocator: mem.Allocator) {
    ctx.sm = Scope_Manager{
        pool = pool,
        symbol_allocator = allocator,
    }
    ctx.program_buffer = make([dynamic]Instruction, allocator)
}

ir_generate_program :: proc(using ctx: ^IR_Context, ast: AST) -> (program: IR_Program, ok: bool) {
    scope_open(&sm) //global scope
    defer scope_close(&sm)

    scope_register_builtin_types(&sm)

    //forward declare all symbols
    for decl_node in ast{
        switch decl in decl_node{
            case Function_Node: scope_register(&sm, Symbol{resolved = false, name = decl.name, data=nil}) or_return
        }
    }

    for decl_node in ast{
        scope_register_global_declaration(&sm, decl_node)
    }

    return program_buffer[:], true
}