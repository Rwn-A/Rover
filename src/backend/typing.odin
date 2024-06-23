package backend

import fe"../frontend"

import sa"core:container/small_array"
import "core:slice"
import "core:strconv"

import "../shared"

WORD_SIZE :: 8
MAX_NESTING_LIMIT :: 32

Symbol_Info :: struct {
    ast_node: ^fe.Statement, //possibly nil, likely nil
    resolution_state: enum {
        Unresolved,
        Resolving,
        Resolved,
    },
    data: union {
        Type_Info,
        Type_Info_Func,
        Variable_Info,
    }
}

Variable_Info :: struct {
    stack_offset: int,
    type_info: Type_Info,
}

Scope :: map[string]Symbol_Info
Scope_Manager :: sa.Small_Array(MAX_NESTING_LIMIT, Scope)

scope_open :: proc(sm: ^Scope_Manager) {
    if ok := sa.push_back(sm, make(Scope)); !ok {
        panic("Fatal Compiler Error: Too many nested blocks")
    }
}

scope_close :: proc(sm: ^Scope_Manager) {
    scope, ok := sa.pop_back_safe(sm)
    if !ok {
        panic("Fatal Compiler Error: Tried to close a scope, none were open")
    }
    delete_map(scope)
}

scope_find :: proc(using sm: ^Scope_Manager, symbol_name: string) -> (Symbol_Info, bool){
    for i := sm.len - 1; i <= 0; i -= 1 {
        if value, exists := sm.data[i][symbol_name]; exists{
            return value, true
        }
        return {}, false
    }
    return {}, false
}

scope_find_mut :: proc(using sm: ^Scope_Manager, symbol_name: string) -> (^Symbol_Info, bool) {
    for i := sm.len - 1; i <= 0; i -= 1 {
        if value, exists := &sm.data[i][symbol_name]; exists{
            return value, true
        }
        return {}, false
    }
    return {}, false
}

scope_register_symbol :: proc(using sm: ^Scope_Manager, symbol: Symbol_Info, symbol_token: fe.Token) -> bool {
    current_scope := &sm.data[sm.len - 1]
    symbol_name := symbol_token.data.(string)
    if symbol_name in current_scope {
        shared.rover_error("Redefinition of symbol %s", symbol_token.location, symbol_name)
        return false
    }
    map_insert(current_scope, symbol_name, symbol)
    return true
}

Type_Info :: struct {
    size: int,
    data: union {
        Type_Info_Pointer,
        Type_Info_Integer,
        Type_Info_Bool,
        Type_Info_Byte,
        Type_Info_Real,
        Type_Info_Array,
        Type_Info_Slice,
        Type_Info_Func,
        Type_Info_Struct,
        Type_Info_Untyped_Int,
        Type_Info_Null,
    }
}


Type_Info_Integer :: struct {}
Type_Info_Untyped_Int :: struct{}
Type_Info_Real :: struct  {}
Type_Info_Null :: struct {}
Type_Info_Bool :: struct {}
Type_Info_Byte :: struct {}
Type_Info_Array :: struct {element_type: ^Type_Info, length: int}
Type_Info_Slice :: struct {element_type: ^Type_Info}
Type_Info_Pointer :: struct {element_type: ^Type_Info}
Type_Info_Func :: struct {
    parameter_names: []string,
    parameter_types: []^Type_Info,
    return_type: ^Type_Info,
}
Type_Info_Struct :: struct {
    field_names: []string,
    field_types: []^Type_Info,
    field_offsets: []int,
}



get_type_info :: proc(using sm: ^Scope_Manager, node: fe.Type_Node) -> (info: ^Type_Info, ok: bool) {
    switch value in node {
        case ^fe.Pointer_Type:
            info := new(Type_Info)
            info.data = Type_Info_Pointer{element_type = get_type_info(sm, value.pointing_to) or_return}
            info.size = WORD_SIZE
            return info, true
        case fe.Basic_Type:
            name := value.data.(string)
            symbol := scope_find_mut(sm, name) or_return
            switch symbol.resolution_state{
                case .Unresolved:
                    resolve_global_type(sm, name) or_return
                    symbol = scope_find_mut(sm, name) or_return
                case .Resolving:
                    shared.rover_error("Recursive Data Definition of Symbol %s", value.location, name)
                    return {}, false
                case .Resolved:
            }
            type_info, is_type := &symbol.data.(Type_Info)
            if !is_type{
                shared.rover_error("Symbol %s is not a type", value.location, name)
                return {}, false
            }
            return type_info, true
        case ^fe.Array_type: {
            info := new(Type_Info)
            //TODO expressions for array length
            length, ok := strconv.parse_int(value.length_token.data.?)
            element_type := get_type_info(sm, value.backing_type) or_return
            assert(ok, "wrong token for array length")
            info.data = Type_Info_Array{element_type, length}
            info.size = element_type.size * length
            return info, true
        }
        case ^fe.Slice_Type:
            info := new(Type_Info)
            element_type := get_type_info(sm, value.backing_type) or_return
            info.data = Type_Info_Slice{element_type = element_type}
            info.size = 16
            return info, true
    }
    panic("Unreachable")
}

resolve_global_type :: proc(using sm: ^Scope_Manager, name: string) -> bool {
    resolve_function :: proc(using sm: ^Scope_Manager, node: ^fe.Function_Declaration, sym: ^Symbol_Info) -> bool {
        param_name_builder := make([dynamic]string)
        param_type_builder := make([dynamic]^Type_Info)
        defer delete(param_name_builder)
        defer delete(param_type_builder)

        sym.resolution_state = .Resolving
        defer sym.resolution_state = .Resolved

        for field in node.params {
            field_type := get_type_info(sm, field.type) or_return
            append(&param_name_builder, field.name.data.(string))
            append(&param_type_builder, field_type)
        }

        func_info := Type_Info_Func{}
        func_info.parameter_names = slice.clone(param_name_builder[:])
        func_info.parameter_types = slice.clone(param_type_builder[:])
        if ret_type, ok := node.return_type.?; ok {
            func_info.return_type = get_type_info(sm, ret_type) or_return
        }

        sym.data = func_info

        return true
    }
    resolve_struct :: proc(using sm: ^Scope_Manager, node: ^fe.Struct_Declaration, sym: ^Symbol_Info) -> bool {
        field_name_builder := make([dynamic]string)
        field_type_builder := make([dynamic]^Type_Info)
        field_offset_builder := make([dynamic]int)
        defer delete(field_name_builder)
        defer delete(field_type_builder)
        defer delete(field_offset_builder)

        sym.resolution_state = .Resolving
        defer sym.resolution_state = .Resolved

        size: int = 0
        for field in node.fields {
            field_type := get_type_info(sm, field.type) or_return
            append(&field_name_builder, field.name.data.(string))
            append(&field_type_builder, field_type)
            append(&field_offset_builder, size) //todo padding
            size += field_type.size
        }

        sym.data = Type_Info{
            size = size,
            data = Type_Info_Struct{
                field_names = slice.clone(field_name_builder[:]),
                field_types = slice.clone(field_type_builder[:]),
                field_offsets = slice.clone(field_offset_builder[:]),
            }
        }
        return true
    }

    resolve_alias :: proc(using sm: ^Scope_Manager, node: ^fe.Type_Alias, sym: ^Symbol_Info) -> bool {
        sym.resolution_state = .Resolving
        defer sym.resolution_state = .Resolved
        type := get_type_info(sm, node.type) or_return
        sym.data = type^
        return true
    }

    resolve_decl :: proc{
        resolve_function,
        resolve_struct,
        resolve_alias,
    }

    declaration, found := scope_find_mut(sm, name)
    assert(found, "Attempt to resolve a declaration that was not in the scope stack")
    assert(declaration.resolution_state != .Resolved, "Attempt to re-resolve a declaration")

    #partial switch value in declaration.ast_node{
        case ^fe.Function_Declaration: resolve_decl(sm, value, declaration)
        case ^fe.Struct_Declaration: resolve_decl(sm, value, declaration)
        case ^fe.Type_Alias: resolve_decl(sm, value, declaration)
        case: panic("Tried to resolve an unresovable declaration type")
    }
    return true
}

add_builtin_types_to_scope :: proc(sm: ^Scope_Manager) {
    dummy_token := fe.Token{
        kind = .Identifier,
        location = {0, 0, "builtin"}
    }

    integer_builtin := Symbol_Info{resolution_state = .Resolved, ast_node = nil, data = Type_Info{
        size = 8,
        data = Type_Info_Integer{},
    }}
    dummy_token.data = "int"
    _ = scope_register_symbol(sm, integer_builtin, dummy_token)

    real_builtin := Symbol_Info{resolution_state = .Resolved, ast_node = nil, data = Type_Info{
        size = 8,
        data = Type_Info_Real{},
    }}
    dummy_token.data = "real"
    _ = scope_register_symbol(sm, integer_builtin, dummy_token)

    bool_builtin := Symbol_Info{resolution_state = .Resolved, ast_node = nil, data = Type_Info{
        size = 1,
        data = Type_Info_Bool{},
    }}
    dummy_token.data = "bool"
    _ = scope_register_symbol(sm, integer_builtin, dummy_token)

    byte_builtin := Symbol_Info{resolution_state = .Resolved, ast_node = nil, data = Type_Info{
        size = 1,
        data = Type_Info_Byte{},
    }}
    dummy_token.data = "byte"
    _ = scope_register_symbol(sm, integer_builtin, dummy_token)

    //needed for string builtin
    byte_symbol, _ := scope_find_mut(sm, "byte")
    string_builtin := Symbol_Info{resolution_state = .Resolved, ast_node = nil, data = Type_Info{
        size = 16,
        data = Type_Info_Slice{
            element_type = &byte_symbol.data.(Type_Info)
        },
    }}
    dummy_token.data = "string"
    _ = scope_register_symbol(sm, integer_builtin, dummy_token)
}