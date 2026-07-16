//! The typed error for the expression engine (issue 3.5).
//!
//! Every malformed input — a bad character, an unexpected or missing token, an
//! unknown identifier, or a function called with the wrong number of arguments —
//! funnels through [`ExprError`], which always carries a 1-based `(line, col)`
//! position. The engine never panics on caller input.

use std::fmt;

/// A recoverable expression-engine failure, with a 1-based source position.
#[derive(Debug, Clone, PartialEq)]
pub enum ExprError {
    /// The lexer hit a character that cannot begin any token.
    LexError {
        /// 1-based line of the offending character.
        line: usize,
        /// 1-based column of the offending character.
        col: usize,
        /// The offending character.
        ch: char,
    },
    /// The parser found a token where a different one (or the end of input) was
    /// required — a missing operand, a stray operator, or trailing input.
    UnexpectedToken {
        /// 1-based line of the token.
        line: usize,
        /// 1-based column of the token.
        col: usize,
    },
    /// An identifier that is neither a bound channel (at evaluation) nor a known
    /// function (at parse time).
    UnknownIdent {
        /// The identifier text.
        name: String,
        /// 1-based line of the identifier.
        line: usize,
        /// 1-based column of the identifier.
        col: usize,
    },
    /// A known function called with the wrong number of arguments.
    ArityMismatch {
        /// The function name.
        name: String,
        /// The arity the function requires.
        expected: usize,
        /// The number of arguments supplied.
        found: usize,
        /// 1-based line of the call.
        line: usize,
        /// 1-based column of the call.
        col: usize,
    },
    /// A `(` with no matching `)` (or a `)` consumed while a `(` was open).
    UnbalancedParen {
        /// 1-based line of the paren.
        line: usize,
        /// 1-based column of the paren.
        col: usize,
    },
}

impl fmt::Display for ExprError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LexError { line, col, ch } => {
                write!(f, "unexpected character {ch:?} at {line}:{col}")
            }
            Self::UnexpectedToken { line, col } => {
                write!(f, "unexpected token at {line}:{col}")
            }
            Self::UnknownIdent { name, line, col } => {
                write!(f, "unknown identifier `{name}` at {line}:{col}")
            }
            Self::ArityMismatch {
                name,
                expected,
                found,
                line,
                col,
            } => write!(
                f,
                "function `{name}` expects {expected} argument(s), got {found} at {line}:{col}"
            ),
            Self::UnbalancedParen { line, col } => {
                write!(f, "unbalanced parenthesis at {line}:{col}")
            }
        }
    }
}

impl std::error::Error for ExprError {}
