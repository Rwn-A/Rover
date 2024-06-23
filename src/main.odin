package main

import "core:fmt"
import "core:os"
import "core:mem/virtual"

import "shared"
import "frontend"
import "backend"

main :: proc() {
    if len(os.args) <= 1 do shared.rover_fatal("Not enough arguments: expected filepath")

    main_file := os.args[1]

    //this is static in a lifetime sense, not static in a size sense
    static_arena := virtual.Arena{}
    if err := virtual.arena_init_growing(&static_arena); err != .None {
        shared.rover_fatal("Allocator Error: %s", err)
    }

    unit_arena := virtual.Arena{}
    if err := virtual.arena_init_growing(&unit_arena); err != .None {
        shared.rover_fatal("Allocator Error: %s", err)
    }

    ok := compile_unit(main_file, &static_arena, &unit_arena)
}   


compile_unit :: proc(filepath: string, sa, ua: ^virtual.Arena) -> bool{
    defer virtual.arena_free_all(ua)
    context.allocator = virtual.arena_allocator(ua)

    data, ok := os.read_entire_file(filepath)
    if !ok do shared.rover_fatal("Unable to open file: %s", filepath)

    ast, ast_ok := frontend.ast_from_bytes(data, filepath, virtual.arena_allocator(sa))

    if !ast_ok do return false

    ir_ctx := backend.IR_Context{
        sm = backend.Scope_Manager{},
    }

    backend.scope_open(&ir_ctx.sm)
    
    backend.add_builtin_types_to_scope(&ir_ctx.sm)

    for root, idx in ast{
        symbol := backend.Symbol_Info{resolution_state = .Unresolved, ast_node = &ast[idx], data = nil}
        backend.scope_register_symbol(&ir_ctx.sm, symbol, frontend.symbol_name(root)) or_return
    }

    for name, &symbol in &ir_ctx.sm.data[ir_ctx.sm.len - 1] {
        if symbol.resolution_state == .Resolved do continue
        backend.resolve_global_type(&ir_ctx.sm, name) or_return
    }

    for root in ast{
        func, is_func := root.(^frontend.Function_Declaration)
        if !is_func do continue
        backend.generate_function(&ir_ctx, func) or_return
    }

    backend.scope_close(&ir_ctx.sm)
    backend.x86_64_fasm(ir_ctx.funcs) or_return
    return true
}

