package main

import "core:fmt"
import "core:os"
import "core:mem/virtual"

import "shared"
import "frontend"

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

    data, ok := os.read_entire_file(filepath, virtual.arena_allocator(ua))
    if !ok do shared.rover_fatal("Unable to open file: %s", filepath)

    ast, ast_ok := frontend.ast_from_bytes(data, filepath, virtual.arena_allocator(sa), virtual.arena_allocator(ua))

    if !ast_ok do return false

    for expr, idx in cast([]frontend.Expression_Node)frontend.Expression(ast[0]) {
        fmt.printf("idx: %d, expr: %v\n", idx, expr)
    }

    return true
}

