//! Math-channel expression engine (issue 3.5).
//!
//! A small, panic-free expression language for user-defined math channels — e.g.
//! `sqrt(Ax*Ax + Ay*Ay)`. Three layers, each with a typed [`ExprError`]:
//!
//! - [`tokenize`] — the [`lexer`] turns source text into [`Token`]s
//!   (whitespace-insensitive; numeric literals accept scientific notation).
//! - [`parse`] — the precedence-climbing [`parser`] turns tokens into an [`Ast`]
//!   (`+ - * /` with correct precedence, parentheses, unary minus, the built-in
//!   [`Func`] set, and channel references), validating function arity.
//! - [`eval_scalar`] / [`eval_series`] — the [`eval`]uator computes a single
//!   value against an [`Env`], or a per-sample series against a
//!   [`ChannelResolver`].
//!
//! **Error policy.** Every malformed input returns an [`ExprError`] carrying a
//! 1-based `(line, col)`; nothing panics. **Division by zero** follows IEEE-754
//! (`±∞` or `NaN`), not an error — a documented, tested policy. Out of scope
//! (per the issue): assignment/statements, unit inference, and the UI editor.

mod error;
mod eval;
mod lexer;
mod parser;

pub use error::ExprError;
pub use eval::{eval_scalar, eval_series, ChannelResolver, Env};
pub use lexer::{tokenize, Token, TokenKind};
pub use parser::{parse, parse_str, Ast, BinOp, Func};
