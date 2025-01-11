package compiler

import "core:mem"
import "core:strings"
import "core:strconv"

Token :: struct {
    kind: TokenKind,
    data: TokenData,
    location: File_Location,
}

File_Location :: struct {
    row: int,
    col: int,
    filepath: string,
    position: int,
}

TokenKind :: enum {
    Identifier,
    Float,
    Integer,
    String,

    Lparen,
    Rparen,
    Lbrace,
    Rbrace,

    If,
    Else,
    While,
    Return,
    Fn,
    True,
    False,
    Struct,
    Foreign,

    Dot,
    Comma,
    Colon,
    SemiColon,
    Hat,
    Equal,
    Ampersand,

    DoubleEqual,
    NotEqual,
    LessThanEqual,
    GreaterThanEqual,
    LessThan,
    GreaterThan,
    ExclamationMark,
    Plus,
    Dash,
    Asterisk,
    SlashForward,
    PlusEqual,
    DashEqual,
    AsteriskEqual,
    SlashEqual,

    EOF,
}

TokenData :: union{
    string,
    i64,
    f64,
}

ident :: proc(t: Token) -> string {
    return t.data.(string)
}


Lexer :: struct {
    identifier_allocator: mem.Allocator,
    source: []byte,
    position: uint,

    current_file_location: File_Location,
}

lexer_init :: proc(lexer: ^Lexer, source: []byte, filename: string, allocator: mem.Allocator) {
    lexer.position = 0
    lexer.current_file_location = File_Location{row = 1, col = 1, filepath = filename, position = 0}
    lexer.identifier_allocator = allocator
    lexer.source = source
}

lexer_next :: proc(using lexer: ^Lexer) -> (token:Token, ok: bool) {
    eof := lexer_skip_whitespace(lexer)

    current_token := Token{kind = .EOF, location = current_file_location, data = nil}

    if eof do return current_token, true


    switch lexer_char(lexer) {
        case '.': current_token.kind = .Dot
        case ',': current_token.kind = .Comma
        case '^': current_token.kind = .Hat
        case '&': current_token.kind = .Ampersand
        case ':': current_token.kind = .Colon
        case ';': current_token.kind = .SemiColon
        case '(': current_token.kind = .Lparen
        case ')': current_token.kind = .Rparen
        case '{': current_token.kind = .Lbrace
        case '}': current_token.kind = .Rbrace
        case 'A'..='z': current_token.kind, current_token.data = lexer_lex_word(lexer)
        case '0'..='9': current_token.kind, current_token.data = lexer_lex_number(lexer)
        case '"':
            current_token.kind = .String
            lexer_adv(lexer)
            if current_token.data = lexer_lex_string(lexer); current_token.data == nil {
                error("String literal has no matching \"", current_file_location)
                return Token{}, false
            }
        case '=': current_token.kind = lexer_lex_followed_by_equal(lexer, .Equal, .DoubleEqual)
        case '!': current_token.kind = lexer_lex_followed_by_equal(lexer, .ExclamationMark, .NotEqual)
        case '<': current_token.kind = lexer_lex_followed_by_equal(lexer,  .LessThan, .LessThanEqual)
        case '>': current_token.kind = lexer_lex_followed_by_equal(lexer, .GreaterThan, .GreaterThanEqual)
        case '+': current_token.kind = lexer_lex_followed_by_equal(lexer, .Plus, .PlusEqual)
        case '-': current_token.kind = lexer_lex_followed_by_equal(lexer, .Dash, .DashEqual)
        case '/':
            //comments
            if lexer_peek(lexer) == '/' {
                for lexer_peek(lexer) != '\n' && lexer_peek(lexer) != 0 do lexer_adv(lexer)
                lexer_adv(lexer)
                return lexer_next(lexer)
            }else { // /= operator
                current_token.kind = lexer_lex_followed_by_equal(lexer, .SlashForward, .SlashEqual)
            }
        case '*': current_token.kind = lexer_lex_followed_by_equal(lexer, .Asterisk, .AsteriskEqual)

        case: {
            error("Unexpected Character %c", current_file_location, lexer_char(lexer))
            return Token{}, false
        }

    }
    lexer_adv(lexer)

    return current_token, true
}

//any token that matches ?= such as <=, +=, ==, !=
@(private="file")
lexer_lex_followed_by_equal :: proc(using lexer: ^Lexer, false_case: TokenKind, true_case: TokenKind) -> TokenKind {
    if lexer_peek(lexer) != '=' do return false_case
    lexer_adv(lexer)
    return true_case
}

@(private="file")
lexer_lex_word :: proc(using lexer: ^Lexer) -> (TokenKind, TokenData) {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case 'A'..='z', '0'..='9', '_': lexer_adv(lexer)
            case: break loop
        }
    }

    text := transmute(string)source[start_position:position + 1]
    kind: TokenKind = .Identifier

    //could replace with a map but this is fine for now
    switch text {
        case "if": kind = .If
        case "while": kind = .While
        case "return": kind = .Return
        case "else": kind = .Else
        case "struct": kind = .Struct
        case "fn": kind = .Fn
        case "true": kind = .True
        case "false": kind = .False
        case "foreign": kind = .Foreign
    }

    if kind != .Identifier do return kind, nil //keywords dont need data
    
    text = strings.clone(text, identifier_allocator)

    return kind, text
}

@(private="file")
lexer_lex_number :: proc(using lexer: ^Lexer) -> (TokenKind, TokenData) {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case '0'..='9', '_', '.': lexer_adv(lexer)
            case: break loop
        }
    }
    text := transmute(string)source[start_position:position + 1]

    if strings.contains_rune(text, '.')  {
        value, ok := strconv.parse_f64(text)
        if !ok {
            error("Could not generate floating point from %s", current_file_location, text)
        }
        return .Float, value
    }

    value, ok := strconv.parse_int(text)
    if !ok {
        error("Could not generate number from %s", current_file_location, text)
    }
    

    return .Integer, i64(value)
}

@(private="file")
lexer_lex_string :: proc(using lexer: ^Lexer) -> TokenData {
    start_position := position
    loop: for {
        switch lexer_peek(lexer) {
            case '"': break loop
            case 0, '\n': return nil
            case: lexer_adv(lexer)
        }
    }
    lexer_adv(lexer)

    text := transmute(string)source[start_position:position]

    text = strings.clone(text, identifier_allocator)

    return text
}

//lexer state control functions

@(private="file")
lexer_skip_whitespace :: proc(using lexer: ^Lexer) -> (eof:bool) {
    for {
        switch lexer_char(lexer) {
            case ' ', '\t', '\r': lexer_adv(lexer)
            case '\n': current_file_location.row += 1; current_file_location.col = 0; lexer_adv(lexer)
            case 0: return true
            case: return false
        }
    }
}

@(private="file")
lexer_char :: proc(using lexer: ^Lexer) -> byte {
    return position < len(source) ? source[position] : 0
}

@(private="file")
lexer_peek :: proc(using lexer: ^Lexer) -> byte {
    return position + 1 < len(source) ? source[position + 1] : 0
}

@(private="file")
lexer_adv :: proc(using lexer: ^Lexer) {
    current_file_location.col += 1; position += 1; current_file_location.position += 1
}