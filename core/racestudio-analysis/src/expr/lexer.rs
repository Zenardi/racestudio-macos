//! Lexer (issue 3.5): turns expression source text into [`Token`]s.
//!
//! Whitespace-insensitive. Numeric literals accept an optional fractional part
//! and scientific notation (`1e-3`, `2.5E2`). Identifiers are C-style
//! (`[A-Za-z_][A-Za-z0-9_]*`) and cover both function names and channel
//! references. Any other character is a typed [`ExprError::LexError`] with its
//! 1-based position; the lexer never panics.

use super::error::ExprError;

/// A lexical token with its 1-based source position.
#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    /// The token kind.
    pub kind: TokenKind,
    /// 1-based line.
    pub line: usize,
    /// 1-based column.
    pub col: usize,
}

/// The kinds of token the expression grammar recognises.
#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    /// A numeric literal (decimal, optional scientific notation).
    Number(f64),
    /// An identifier (function name or channel reference).
    Ident(String),
    /// `+`
    Plus,
    /// `-`
    Minus,
    /// `*`
    Star,
    /// `/`
    Slash,
    /// `(`
    LParen,
    /// `)`
    RParen,
    /// `,`
    Comma,
    /// End of input (always the final token).
    Eof,
}

/// Tokenize `src`, always ending with a [`TokenKind::Eof`] token.
///
/// # Errors
/// [`ExprError::LexError`] on a character that cannot begin a token (or a
/// malformed numeric literal), carrying its 1-based `(line, col)`.
pub fn tokenize(src: &str) -> Result<Vec<Token>, ExprError> {
    let chars: Vec<char> = src.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    let mut line = 1;
    let mut col = 1;

    while i < chars.len() {
        let c = chars[i];
        let single = |kind| Token { kind, line, col };
        match c {
            ' ' | '\t' | '\r' => {
                i += 1;
                col += 1;
            }
            '\n' => {
                i += 1;
                line += 1;
                col = 1;
            }
            '+' => push(&mut tokens, single(TokenKind::Plus), &mut i, &mut col),
            '-' => push(&mut tokens, single(TokenKind::Minus), &mut i, &mut col),
            '*' => push(&mut tokens, single(TokenKind::Star), &mut i, &mut col),
            '/' => push(&mut tokens, single(TokenKind::Slash), &mut i, &mut col),
            '(' => push(&mut tokens, single(TokenKind::LParen), &mut i, &mut col),
            ')' => push(&mut tokens, single(TokenKind::RParen), &mut i, &mut col),
            ',' => push(&mut tokens, single(TokenKind::Comma), &mut i, &mut col),
            '0'..='9' | '.' => {
                let end = scan_number(&chars, i);
                let text: String = chars[i..end].iter().collect();
                let value =
                    text.parse::<f64>()
                        .map_err(|_| ExprError::LexError { line, col, ch: c })?;
                tokens.push(Token {
                    kind: TokenKind::Number(value),
                    line,
                    col,
                });
                col += end - i;
                i = end;
            }
            c if c.is_ascii_alphabetic() || c == '_' => {
                let end = scan_ident(&chars, i);
                let text: String = chars[i..end].iter().collect();
                tokens.push(Token {
                    kind: TokenKind::Ident(text),
                    line,
                    col,
                });
                col += end - i;
                i = end;
            }
            other => {
                return Err(ExprError::LexError {
                    line,
                    col,
                    ch: other,
                })
            }
        }
    }

    tokens.push(Token {
        kind: TokenKind::Eof,
        line,
        col,
    });
    Ok(tokens)
}

/// Push a single-character token and advance one column.
fn push(tokens: &mut Vec<Token>, token: Token, i: &mut usize, col: &mut usize) {
    tokens.push(token);
    *i += 1;
    *col += 1;
}

/// The end index of the numeric literal starting at `start`
/// (`[0-9]*('.'[0-9]*)?([eE][+-]?[0-9]+)?`). Validity is confirmed by the caller
/// via `f64::from_str`, so a lone `.` is rejected there.
fn scan_number(chars: &[char], start: usize) -> usize {
    let mut j = start;
    while j < chars.len() && chars[j].is_ascii_digit() {
        j += 1;
    }
    if j < chars.len() && chars[j] == '.' {
        j += 1;
        while j < chars.len() && chars[j].is_ascii_digit() {
            j += 1;
        }
    }
    // Exponent, only if it is well-formed (`e`/`E`, optional sign, ≥1 digit);
    // otherwise the `e` is left for the next token.
    if j < chars.len() && (chars[j] == 'e' || chars[j] == 'E') {
        let mut k = j + 1;
        if k < chars.len() && (chars[k] == '+' || chars[k] == '-') {
            k += 1;
        }
        if k < chars.len() && chars[k].is_ascii_digit() {
            while k < chars.len() && chars[k].is_ascii_digit() {
                k += 1;
            }
            j = k;
        }
    }
    j
}

/// The end index of the identifier starting at `start` (`[A-Za-z0-9_]*`).
fn scan_ident(chars: &[char], start: usize) -> usize {
    let mut j = start;
    while j < chars.len() && (chars[j].is_ascii_alphanumeric() || chars[j] == '_') {
        j += 1;
    }
    j
}
