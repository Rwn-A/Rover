package compiler

import "core:mem/virtual"
import "core:os"
import "core:fmt"

compile :: proc(filename: string) -> bool{
    //--compiler frontend--
    fmt.printfln("[Info]: Opening source file %s.", filename)
    source, ok := os.read_entire_file(filename)
    if !ok {
        fatal("Failed to open file %s", filename)
    }

    //file is closed after lexing, identifiers need to stick around
    identifier_arena := virtual.Arena{}
    if err := virtual.arena_init_growing(&identifier_arena); err != .None{
        fatal("Unable to allocate memory")
    }
    defer virtual.arena_destroy(&identifier_arena)

    //all ast nodes have the same lifetime
    node_arena := virtual.Arena{}
    if err := virtual.arena_init_growing(&node_arena); err != .None{
        fatal("Unable to allocate memory")
    }

    lexer := Lexer{}
    parser := Parser{}
    lexer_init(&lexer, source, filename, virtual.arena_allocator(&identifier_arena))
    parser_init(&parser, &lexer) or_return

    fmt.printfln("[Info]: Parsing...")
    
    ast := parser_parse(&parser, virtual.arena_allocator(&node_arena)) or_return

    //fmt.printfln("%#v", ast)

    delete(source) //ast is complete, file is no longer needed

    ir_arena := virtual.Arena{}
    if err := virtual.arena_init_growing(&ir_arena); err != .None{
        fatal("Unable to allocate memory")
    }
    defer virtual.arena_destroy(&ir_arena)
    ir_allocator := virtual.arena_allocator(&ir_arena)

    symbol_pool := make(Symbol_Pool, ir_allocator)
    ir_context := IR_Builder{}
    ir_init(&ir_context, &symbol_pool, ir_allocator)

    fmt.printfln("[Info]: Generating IR...")

    program := ir_build_program(&ir_context, ast) or_return

    dump_ir(program, &symbol_pool)

    virtual.arena_destroy(&node_arena)

    fmt.printfln("[Info]: Generating Assembly...")

    x86_64_linux_fasm(&symbol_pool, program)

    fmt.printfln("[Info]: Compilation Complete.")

    return true
}