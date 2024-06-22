package frontend

import "base:runtime"

import "../shared"

ast_from_bytes :: proc(source: []byte, filepath: string, sa, ua: runtime.Allocator) -> (ast: []Statement, ok: bool) {
    context.allocator = ua

    lexer := Lexer{
        sm = String_Manager{
            allocations = make([dynamic]string, sa),
            allocator = sa,
        },
        source = source,
        position = 0,
        cur_loc = shared.Rover_Location{
            row = 1,
            col = 1,
            filepath = filepath,
        },
    }

    token := lexer_next(&lexer) or_return
    peek := lexer_next(&lexer) or_return

    parser := Parser{
        lexer = &lexer,
        token = token,
        peek = peek,
    }

    roots := make([dynamic]Statement)

    for parser.token.kind != .EOF {
        if stmt, stmt_ok := parse_statement(&parser); stmt_ok {
            append(&roots, stmt)
        }else {
            return {}, false
        }
    }

    return roots[:], true
}


Parser :: struct {
    lexer: ^Lexer,

    token: Token,
    peek: Token,

    expression_buffer: [dynamic]Expression_Node
}

parser_advance :: proc(using parser: ^Parser) -> (ok: bool) {
    token = peek
    peek = lexer_next(lexer) or_return
    return true
}

parser_assert :: proc(using parser: ^Parser, expected: ..TokenType) ->  bool{
    for expect in expected{
        if token.kind != expect {
            shared.rover_error("Unexpected token %v expected %v", token.location, token.kind, expected)
            return false
        }
        if parser_advance(parser) == false do return false
    }
    return true
}

Statement :: Expression

parse_statement :: proc(parser: ^Parser) -> (stmt: Statement, ok: bool) {
    return parse_expression(parser)
}

Expression :: []Expression_Node

Expression_Ref :: distinct i16

Expression_Node :: union {
    Literal_Int,
    Literal_Bool,
    Literal_String,
    Literal_Float,
    Identifier,
    Binary_Expression,
    Unary_Expression,
    Assignment_Expression,
}

Literal_Int :: distinct Token
Literal_Bool ::  distinct Token
Literal_String ::  distinct Token
Literal_Float :: distinct Token
Identifier :: distinct Token

Binary_Expression :: struct {
    lhs: Expression_Ref,
    rhs: Expression_Ref,
    operator: Token,
}

Unary_Expression :: struct {
    expr: Expression_Ref,
    operator: Token,
}

Assignment_Expression :: struct {
    lhs: Expression_Ref,
    rhs: Expression_Ref,
}

Operator_Token: TokenTypeSet : {
    .Dash, .DashEqual, .Dot, .DoubleEqual,
    .Equal, .NotEqual, .Plus, .PlusEqual, .Equal,
    .Asterisk, .AsteriskEqual, .SlashForward, .SlashEqual,
    .LessThan, .LessThanEqual, .GreaterThan, .GreaterThanEqual,
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

operator_precedence :: proc(kind: TokenType) -> Operator_Precedence {
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

parse_expression :: proc(using parser: ^Parser) -> (expr: Expression, ok: bool) {
    expression_buffer = make([dynamic]Expression_Node)
    parse_primary_expression(parser, .Lowest) or_return
    if !line_end(token, peek) {
        shared.rover_error("Unexpected Token %v, Expected newline or ;",peek.location, peek.kind)
        return expr, false
    }
    if peek.kind == .SemiColon do parser_advance(parser) or_return
    parser_advance(parser) or_return
    return expression_buffer[:], true
}


parse_primary_expression :: proc(using parser: ^Parser, prec: Operator_Precedence) -> (ref: Expression_Ref, ok: bool) {
    ref = Expression_Ref(len(expression_buffer))

    #partial switch token.kind {
        case .Integer: append(&expression_buffer, cast(Literal_Int)token)
        case .Float: append(&expression_buffer, cast(Literal_Float)token)
        case .True,. False: append(&expression_buffer, cast(Literal_Bool)token)
        case .String: append(&expression_buffer, cast(Literal_String)token)
        case .Lparen: ref = parse_grouped(parser) or_return
        case .Lbrace: unimplemented("arrays")
        case .Hat, .ExclamationMark, .Ampersand, .Dash: 
            Expression_Ref(len(expression_buffer))
            append(&expression_buffer, parse_prefix(parser) or_return)
        case .Identifier:
           #partial switch peek.kind {
               case .Lparen: unimplemented("function calls")
               case .Lbrace: unimplemented("struct")
               case: append(&expression_buffer, cast(Identifier)token)
           }
        case: {
            shared.rover_error("Expression cannot start with %v", token.location, token.kind)
            return ref, false
        }
    }

   
    for !line_end(token, peek) && prec < operator_precedence(peek.kind) {
        if peek.kind not_in Operator_Token do return ref, true
        parser_advance(parser) or_return
        expr := parse_infix(parser, ref) or_return
        ref = Expression_Ref(len(expression_buffer))
        append(&expression_buffer, expr)
    }
    
    return ref, true
}

parse_infix :: proc(using parser: ^Parser, lhs: Expression_Ref) -> (expr: Expression_Node, ok: bool) {
    bin_expr := Binary_Expression{lhs = lhs, operator = token}

    prec := operator_precedence(token.kind)
    parser_advance(parser) or_return

    //dot is right associative subtracting 1 from the precedence seems to work for that
    if bin_expr.operator.kind == .Dot {
        bin_expr.rhs = parse_primary_expression(parser, Operator_Precedence(int(prec) - 1)) or_return
    } else {
        bin_expr.rhs = parse_primary_expression(parser, prec) or_return
    }

    if bin_expr.operator.kind == .Equal{
        assign_expr := Assignment_Expression{lhs = bin_expr.lhs, rhs = bin_expr.rhs}
        return assign_expr, true 
    }

    return bin_expr, true
}

parse_prefix :: proc(using parser: ^Parser) -> (expr: Expression_Node, ok: bool) {
    un_expr := Unary_Expression{operator = token}
    parser_advance(parser) or_return
    un_expr.expr = parse_primary_expression(parser, .Prefix) or_return
    return un_expr, true
}

parse_grouped :: proc(using parser: ^Parser) -> (ref: Expression_Ref, ok: bool){
    parser_advance(parser) or_return
    ref = parse_primary_expression(parser, .Lowest) or_return
    if peek.kind != .Rparen {
        shared.rover_error("Unexpected token %v expected )", token.location, token.kind)
        return ref, false
    }
    parser_advance(parser) or_return
    return ref, true
}

line_end :: proc(tk: Token, peek: Token) -> bool {
    return peek.location.row > tk.location.row || peek.kind == .EOF || peek.kind == .SemiColon
}
