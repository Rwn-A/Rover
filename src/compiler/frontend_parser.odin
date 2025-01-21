package compiler

import "core:mem"
import "core:fmt"

AST :: []Declaration_Node

Declaration_Node :: union {
    Function_Node,
    Foreign_Function_Node,
    Foreign_Global_Node,
}

Statement :: union {
    Variable_Node,
    Expression_Node,
    Return_Node,
    If_Node,
    While_Node,
}

Foreign_Function_Node :: struct {
    name: Token,
    param_types: []Type_Node,
    return_type: Maybe(Type_Node),
}

Foreign_Global_Node :: distinct Variable_Node

Function_Node :: struct {
    name: Token,
    params: []Variable_Node,
    return_type: Maybe(Type_Node),
    body: []Statement,
}

If_Node :: struct {
    comparison: Expression_Node,
    body: []Statement,
    else_body: []Statement,
}

While_Node :: struct {
    condition: Expression_Node,
    body: []Statement,
}

Variable_Node :: struct {
    name: Token,
    type: Type_Node,
}

Symbol_Type :: Token
Pointer_Type :: struct {
    pointing_at: ^Type_Node,
}
Array_Type :: struct {
    length: int,
    element: ^Type_Node,
}
Type_Node :: union {
    Symbol_Type, //types defined by a single symbol
    Pointer_Type,
    Array_Type,
}

Return_Node :: distinct Maybe(Expression_Node)
Expression_Node :: union {
    Literal_Int,
    Literal_Bool,
    Literal_String,
    Literal_Float,
    Identifier_Node,
    Array_Literal_Node,
    ^Binary_Expression_Node,
    ^Unary_Expression_Node,
    Function_Call_Node,
}

Literal_Int :: distinct Token
Literal_Bool ::  distinct Token
Literal_String ::  distinct Token
Literal_Float :: distinct Token
Identifier_Node :: distinct Token

Binary_Expression_Node :: struct {
    lhs: Expression_Node,
    rhs: Expression_Node,
    operator: Token,
}

Unary_Expression_Node :: struct {
    rhs: Expression_Node,
    operator: Token,
}

Function_Call_Node :: struct {
    name: Token,
    args: []Expression_Node,
}

Array_Literal_Node :: struct {
    entries: []Expression_Node,
}

Parser :: struct {
    lexer: ^Lexer,
    token: Token,
    peek: Token,
}

parser_init :: proc(parser: ^Parser, lexer: ^Lexer) -> bool {
    parser.token = lexer_next(lexer) or_return
    parser.peek = lexer_next(lexer) or_return
    parser.lexer = lexer
    return true
}

@(private="file")
parser_advance :: proc(using parser: ^Parser) -> (ok: bool) {
    token = peek
    peek = lexer_next(lexer) or_return
    return true
}

@(private="file")
parser_assert :: proc(using parser: ^Parser, expected: ..TokenKind) ->  bool{
    for expect in expected{
        if token.kind != expect {
            error("Unexpected token %v expected %v", token.location, token.kind, expected)
            return false
        }
        if parser_advance(parser) == false do return false
    }
    return true
}   

//common use-case of assert is for identifiers but they are usually stored so this is handy
@(private="file")
parser_assert_identifier :: proc(using parser: ^Parser) -> (tk: Token, ok: bool) {
    initial := token
    if token.kind != .Identifier{
        error("Expected identifier found %s", token.location, token.kind)
        return Token{}, false
    }
    parser_advance(parser) or_return
    return initial, true
}

parser_parse :: proc(using parser: ^Parser, node_allocator: mem.Allocator) -> (ast: AST, ok: bool) {
    context.allocator = node_allocator

    ast_builder := make([dynamic]Declaration_Node)
    for token.kind != .EOF{
        #partial switch token.kind {
            case .Fn: append(&ast_builder, parse_function_node(parser) or_return)
            case .Foreign:
                if peek.kind == .Fn do append(&ast_builder, parse_foreign_function(parser) or_return)
                else do append(&ast_builder, parse_foreign_global(parser) or_return)
            case: 
                error("Top-Level statement cannot begin with %v", token.location, token.kind)
                return nil, false
        }
    }
    return ast_builder[:], true
}

@(private="file")
parse_foreign_function :: proc(using parser: ^Parser) -> (node: Foreign_Function_Node, ok: bool) {
    parser_assert(parser, .Foreign, .Fn) or_return
    node.name = parser_assert_identifier(parser) or_return
    parser_assert(parser, .Lparen) or_return
    
    param_builder := make([dynamic]Type_Node)
    for token.kind != .Rparen {
        append(&param_builder, parse_type(parser) or_return)
        if token.kind == .Comma do parser_advance(parser) or_return
    }
    node.param_types = param_builder[:]

    rparen_token := token
    parser_assert(parser, .Rparen) or_return
    if !line_end(rparen_token, token) do node.return_type = parse_type(parser) or_return

    return node, true
}

@(private="file")
parse_foreign_global :: proc(using parser: ^Parser) -> (node: Foreign_Global_Node, ok: bool) {
    parser_advance(parser) or_return 
    node.name = parser_assert_identifier(parser) or_return
    parser_assert(parser, .Colon) or_return
    node.type = parse_type(parser) or_return
    return node, true
}

@(private="file")
parse_function_node :: proc(using parser: ^Parser) -> (node: Function_Node, ok: bool) {
    parser_advance(parser) or_return
    node.name = parser_assert_identifier(parser) or_return
    parser_assert(parser, .Lparen) or_return

    param_builder := make([dynamic]Variable_Node)
    for token.kind != .Rparen{
        param_decl := parse_statement(parser) or_return
        if param, is_param := param_decl.(Variable_Node); is_param {
            append(&param_builder, param)
        }else{
            error("Expected parameter definition, got %v", node.name.location, param_decl)
            return {}, false
        }
        if token.kind == .Comma do parser_advance(parser) or_return
    }
    parser_assert(parser, .Rparen) or_return
    node.params = param_builder[:]

    if token.kind != .Lbrace do node.return_type = parse_type(parser) or_return
    parser_assert(parser, .Lbrace) or_return
    
    body_builder := make([dynamic]Statement)
    for token.kind != .Rbrace do append(&body_builder, parse_statement(parser) or_return)
    parser_assert(parser, .Rbrace)
    node.body = body_builder[:]

    return node, true
}

@(private="file")
parse_type :: proc(using parser: ^Parser) -> (type: Type_Node, ok:bool) {
    initial := token
    #partial switch initial.kind {
        case .Identifier:
            parser_advance(parser) or_return
            return Symbol_Type(initial), true 
        case .Ampersand:
            parser_advance(parser) or_return
            pointing_at := new(Type_Node)
            pointing_at^ = parse_type(parser) or_return
            return Pointer_Type{pointing_at = pointing_at}, true
        case .Lbracket:
            parser_advance(parser) or_return
            length := token
            parser_assert(parser, .Integer, .Rbracket) or_return
            pointing_at := new(Type_Node)
            pointing_at^ = parse_type(parser) or_return
            return Array_Type{length = int(length.data.(i64)), element = pointing_at}, true
        case:
            error("Expected a type got %s", initial.location, initial.kind)
            return nil, false
    }
}

@(private="file")
parse_statement :: proc(using parser: ^Parser) -> (stmt: Statement, ok: bool) {
    initial := token
    #partial switch initial.kind {
        case .While, .If:
            parser_advance(parser) or_return

            condition := parse_primary_expression(parser, .Lowest) or_return
            parser_advance(parser) or_return
            parser_assert(parser, .Lbrace) or_return

            body_builder := make([dynamic]Statement)
            for token.kind != .Rbrace do append(&body_builder, parse_statement(parser) or_return)
            parser_assert(parser, .Rbrace) or_return

            if initial.kind == .While do return While_Node{condition = condition, body = body_builder[:]}, true
            if token.kind != .Else do return If_Node{comparison = condition, body = body_builder[:]}, true
            
            parser_advance(parser) or_return
            parser_assert(parser, .Lbrace) or_return
            else_builder := make([dynamic]Statement)
            for token.kind != .Rbrace do append(&else_builder, parse_statement(parser) or_return)
            parser_assert(parser, .Rbrace) or_return
            return If_Node{comparison = condition, body = body_builder[:], else_body = else_builder[:]}, true
        case .Identifier:
            if peek.kind != .Colon do return parse_expression(parser)
            parser_advance(parser) or_return //skip name
            parser_advance(parser) or_return //skip colon
            var_decl := Variable_Node{}
            var_decl.name = initial
            var_decl.type = parse_type(parser) or_return
            if token.kind == .Equal{
                //trick the lexer to re-parse only the assignment portion
                parser.lexer.position = uint(token.location.position + 1)
                parser.lexer.current_file_location.col = token.location.col + 1
                parser.lexer.current_file_location.position = int(parser.lexer.position)
                peek = token
                token = initial
            }
            return var_decl, true
        case .Return:
            if !line_end(token, peek) && peek.kind != .Rbrace {
                parser_advance(parser) or_return
                expr := parse_expression(parser) or_return
                return cast(Return_Node)expr, true
            }
            parser_advance(parser) or_return
            return cast(Return_Node)nil, true
        case: return parse_expression(parser)
    }
}

Operator_Precedence :: enum {
    Lowest,
    Equals,
    LessGreater,
    Sum,
    Product,
    Prefix,
    Highest,
}

TokenKindSet :: bit_set[TokenKind]
Operator_Token: TokenKindSet : {
    .Dash, .DashEqual, .Dot, .DoubleEqual,
    .Equal, .NotEqual, .Plus, .PlusEqual, .Equal,
    .Asterisk, .AsteriskEqual, .SlashForward, .SlashEqual,
    .LessThan, .LessThanEqual, .GreaterThan, .GreaterThanEqual,
}

@(private="file")
operator_precedence :: proc(kind: TokenKind) -> Operator_Precedence {
    #partial switch kind {
        case .NotEqual: return .Equals
        case .LessThan: return .LessGreater
        case .GreaterThan: return .LessGreater
        case .DoubleEqual: return .Equals
        case .Equal: return .Equals
        case .LessThanEqual: return .LessGreater
        case .GreaterThanEqual: return .LessGreater
        case .Plus: return .Sum
        case .Dash: return .Sum
        case .Asterisk: return .Product
        case .SlashForward: return .Product
        case .Dot: return .Highest
        case: return .Lowest
    }
}

@(private="file")
parse_expression :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    expr = parse_primary_expression(parser, .Lowest) or_return
    if !line_end(token, peek) {
        error("Unexpected Token %v, Expected newline or ;", peek.location, peek.kind)
        return expr, false
    }
    if peek.kind == .SemiColon do parser_advance(parser) or_return //optional semicolon handling
    parser_advance(parser) or_return
    return expr, true
}

@(private="file")
parse_primary_expression :: proc(using parser: ^Parser, prec: Operator_Precedence) -> (expr: Expression_Node, ok: bool) {
    #partial switch token.kind {
        case .Integer: expr = cast(Literal_Int)token
        case .Float: expr = cast(Literal_Float)token
        case .True,. False: expr = cast(Literal_Bool)token
        case .String: expr = cast(Literal_String)token
        case .Lparen: expr = parse_grouped(parser) or_return
        case .Lbracket: expr = parse_array_literal(parser) or_return
        case .Hat, .ExclamationMark, .Ampersand, .Dash: expr = parse_prefix(parser) or_return
        case .Identifier:
            #partial switch peek.kind {
                case .Lparen: 
                    expr = parse_call(parser) or_return
                case: expr = cast(Identifier_Node)token
            }
        case: {
            error("Expression cannot start with %v", token.location, token.kind)
            return nil, false
        }
    }

    for !line_end(token, peek) && prec < operator_precedence(peek.kind) {
        if peek.kind not_in Operator_Token do return expr, true
        parser_advance(parser) or_return
        expr = parse_infix(parser, expr) or_return
    }

    return expr, true
}

@(private="file")
parse_grouped :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool){
    parser_advance(parser) or_return
    expr = parse_primary_expression(parser, .Lowest) or_return
    if peek.kind != .Rparen {
        error("Unexpected token %v expected )", token.location, token.kind)
        return nil, false
    }
    parser_advance(parser) or_return
    return expr, true
}

@(private="file")
parse_array_literal :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    parser_advance(parser) or_return
    entry_builder := make([dynamic]Expression_Node)

    for token.kind != .Rbracket{
        append(&entry_builder, parse_primary_expression(parser, .Lowest) or_return)
        parser_advance(parser) or_return
        if token.kind == .Comma{
            parser_advance(parser) or_return
            continue
        }
    }

    return Array_Literal_Node{entries = entry_builder[:]}, true
}

@(private="file")
parse_call :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    name := parser_assert_identifier(parser) or_return
    parser_advance(parser) or_return

    arg_builder := make([dynamic]Expression_Node)
    for token.kind != .Rparen{
        append(&arg_builder, parse_primary_expression(parser, .Lowest) or_return)
        parser_advance(parser) or_return
        if token.kind == .Comma{
            parser_advance(parser) or_return
            continue
        }
    }
    //parser_assert(parser, .Rparen) or_return
    return Function_Call_Node{name = name, args = arg_builder[:]}, true
}

@(private="file")
parse_infix :: proc(using parser: ^Parser, lhs: Expression_Node) -> (expr: Expression_Node, ok: bool) {
    bin_expr := new(Binary_Expression_Node)
    bin_expr.lhs = lhs 
    bin_expr.operator = token

    prec := operator_precedence(token.kind)
    parser_advance(parser)

    //dot is right associative, subtracting 1 from the precedence seems to work for that
    if bin_expr.operator.kind == .Dot {
        bin_expr.rhs = parse_primary_expression(parser, Operator_Precedence(int(prec) - 1)) or_return
    } else {
        bin_expr.rhs = parse_primary_expression(parser, prec) or_return
    }

    return bin_expr, true
}

@(private="file")
parse_prefix :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    un_expr := new(Unary_Expression_Node);
    un_expr.operator = token
    parser_advance(parser) or_return
    un_expr.rhs = parse_primary_expression(parser, .Prefix) or_return
    return un_expr, true
}

@(private="file")
line_end :: proc(tk: Token, peek: Token) -> bool {
    return peek.location.row > tk.location.row || peek.kind == .EOF || peek.kind == .SemiColon
}