//! Parser + AST (issue 3.5): precedence-climbing (Pratt) parser over the token
//! stream.
//!
//! Grammar: `+ -` (binding power 1/2) below `* /` (3/4) below unary `-` (5)
//! below primaries (numbers, parenthesised expressions, channel references, and
//! function calls). Function names are resolved and their arity validated here,
//! so a returned [`Ast`] is always well-formed. Every failure is a typed
//! [`ExprError`] with a 1-based position; the parser never panics — even on a
//! token slice with no trailing [`TokenKind::Eof`].

use std::fmt;

use super::error::ExprError;
use super::lexer::{tokenize, Token, TokenKind};

/// A binary arithmetic operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `*`
    Mul,
    /// `/`
    Div,
}

/// A built-in function.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Func {
    /// `abs(x)`
    Abs,
    /// `sqrt(x)`
    Sqrt,
    /// `sin(x)`
    Sin,
    /// `cos(x)`
    Cos,
    /// `tan(x)`
    Tan,
    /// `log(x)` — natural logarithm.
    Log,
    /// `exp(x)`
    Exp,
    /// `min(a, b)`
    Min,
    /// `max(a, b)`
    Max,
    /// `pow(a, b)`
    Pow,
    /// `clamp(x, lo, hi)`
    Clamp,
}

impl Func {
    /// Every built-in function, in declaration order.
    ///
    /// Lets callers enumerate the whole function set — a UI palette of available
    /// functions, or the handbook's completeness check that no shipped built-in
    /// is left undocumented.
    pub const ALL: [Self; 11] = [
        Self::Abs,
        Self::Sqrt,
        Self::Sin,
        Self::Cos,
        Self::Tan,
        Self::Log,
        Self::Exp,
        Self::Min,
        Self::Max,
        Self::Pow,
        Self::Clamp,
    ];

    /// Resolve a function name, or `None` if it is not built in.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "abs" => Self::Abs,
            "sqrt" => Self::Sqrt,
            "sin" => Self::Sin,
            "cos" => Self::Cos,
            "tan" => Self::Tan,
            "log" => Self::Log,
            "exp" => Self::Exp,
            "min" => Self::Min,
            "max" => Self::Max,
            "pow" => Self::Pow,
            "clamp" => Self::Clamp,
            _ => return None,
        })
    }

    /// The function's canonical name.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Abs => "abs",
            Self::Sqrt => "sqrt",
            Self::Sin => "sin",
            Self::Cos => "cos",
            Self::Tan => "tan",
            Self::Log => "log",
            Self::Exp => "exp",
            Self::Min => "min",
            Self::Max => "max",
            Self::Pow => "pow",
            Self::Clamp => "clamp",
        }
    }

    /// The number of arguments the function requires.
    #[must_use]
    pub fn arity(self) -> usize {
        match self {
            Self::Abs | Self::Sqrt | Self::Sin | Self::Cos | Self::Tan | Self::Log | Self::Exp => 1,
            Self::Min | Self::Max | Self::Pow => 2,
            Self::Clamp => 3,
        }
    }
}

/// An abstract syntax tree node.
#[derive(Debug, Clone, PartialEq)]
pub enum Ast {
    /// A numeric literal.
    Number(f64),
    /// A channel reference, resolved at evaluation (carries its position for a
    /// precise [`ExprError::UnknownIdent`]).
    Channel {
        /// The channel name.
        name: String,
        /// 1-based line of the reference.
        line: usize,
        /// 1-based column of the reference.
        col: usize,
    },
    /// Unary negation.
    Neg(Box<Ast>),
    /// A binary operation.
    Binary(BinOp, Box<Ast>, Box<Ast>),
    /// A function call (arity validated at parse time).
    Call {
        /// The resolved function.
        func: Func,
        /// The argument expressions.
        args: Vec<Ast>,
    },
}

impl BinOp {
    fn symbol(self) -> char {
        match self {
            Self::Add => '+',
            Self::Sub => '-',
            Self::Mul => '*',
            Self::Div => '/',
        }
    }
}

impl fmt::Display for Ast {
    /// A fully parenthesised, canonical rendering. For any tree the parser
    /// produces it re-parses to the same tree (numbers use round-trippable
    /// `{:?}` formatting; literals are always finite and non-negative, with
    /// negation carried by [`Ast::Neg`]).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Number(n) => write!(f, "{n:?}"),
            Self::Channel { name, .. } => write!(f, "{name}"),
            Self::Neg(inner) => write!(f, "-{inner}"),
            Self::Binary(op, lhs, rhs) => write!(f, "({lhs} {} {rhs})", op.symbol()),
            Self::Call { func, args } => {
                write!(f, "{}(", func.name())?;
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{arg}")?;
                }
                write!(f, ")")
            }
        }
    }
}

/// A no-data end-of-input sentinel, so peeking past the tokens never panics.
const EOF: Token = Token {
    kind: TokenKind::Eof,
    line: 0,
    col: 0,
};

/// Parse a token slice into an [`Ast`].
///
/// # Errors
/// A typed [`ExprError`] — [`UnexpectedToken`](ExprError::UnexpectedToken),
/// [`UnbalancedParen`](ExprError::UnbalancedParen),
/// [`UnknownIdent`](ExprError::UnknownIdent) (unknown function), or
/// [`ArityMismatch`](ExprError::ArityMismatch) — with a 1-based position.
pub fn parse(tokens: &[Token]) -> Result<Ast, ExprError> {
    let mut parser = Parser { tokens, pos: 0 };
    let ast = parser.expr(0)?;
    match parser.peek().kind {
        TokenKind::Eof => Ok(ast),
        _ => {
            let token = parser.peek();
            Err(ExprError::UnexpectedToken {
                line: token.line,
                col: token.col,
            })
        }
    }
}

/// Tokenize then [`parse`] `src`.
///
/// # Errors
/// Any [`ExprError`] from [`tokenize`] or [`parse`].
pub fn parse_str(src: &str) -> Result<Ast, ExprError> {
    parse(&tokenize(src)?)
}

struct Parser<'a> {
    tokens: &'a [Token],
    pos: usize,
}

impl Parser<'_> {
    fn peek(&self) -> &Token {
        self.tokens.get(self.pos).unwrap_or(&EOF)
    }

    fn bump(&mut self) {
        self.pos += 1;
    }

    /// Precedence-climbing expression parser: parse a prefix, then fold binary
    /// operators whose left binding power is at least `min_bp`.
    fn expr(&mut self, min_bp: u8) -> Result<Ast, ExprError> {
        let mut lhs = self.prefix()?;
        loop {
            let (op, l_bp, r_bp) = match self.peek().kind {
                TokenKind::Plus => (BinOp::Add, 1, 2),
                TokenKind::Minus => (BinOp::Sub, 1, 2),
                TokenKind::Star => (BinOp::Mul, 3, 4),
                TokenKind::Slash => (BinOp::Div, 3, 4),
                _ => break,
            };
            if l_bp < min_bp {
                break;
            }
            self.bump();
            let rhs = self.expr(r_bp)?;
            lhs = Ast::Binary(op, Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    /// Unary minus (binding power 5), else a primary.
    fn prefix(&mut self) -> Result<Ast, ExprError> {
        if matches!(self.peek().kind, TokenKind::Minus) {
            self.bump();
            return Ok(Ast::Neg(Box::new(self.expr(5)?)));
        }
        self.primary()
    }

    fn primary(&mut self) -> Result<Ast, ExprError> {
        let token = self.peek().clone();
        let (line, col) = (token.line, token.col);
        match token.kind {
            TokenKind::Number(value) => {
                self.bump();
                Ok(Ast::Number(value))
            }
            TokenKind::LParen => {
                self.bump();
                let inner = self.expr(0)?;
                self.expect_rparen(line, col)?;
                Ok(inner)
            }
            TokenKind::Ident(name) => {
                self.bump();
                if matches!(self.peek().kind, TokenKind::LParen) {
                    self.call(&name, line, col)
                } else {
                    Ok(Ast::Channel { name, line, col })
                }
            }
            _ => Err(ExprError::UnexpectedToken { line, col }),
        }
    }

    /// Parse a function call `name '(' args ')'` (the `(` is the current token,
    /// the identifier at `line`/`col`), resolving the function and validating
    /// its arity.
    fn call(&mut self, name: &str, line: usize, col: usize) -> Result<Ast, ExprError> {
        let func = Func::from_name(name).ok_or_else(|| ExprError::UnknownIdent {
            name: name.to_string(),
            line,
            col,
        })?;
        self.bump(); // consume '('
        let args = self.args(line, col)?;
        if args.len() != func.arity() {
            return Err(ExprError::ArityMismatch {
                name: func.name().to_string(),
                expected: func.arity(),
                found: args.len(),
                line,
                col,
            });
        }
        Ok(Ast::Call { func, args })
    }

    /// Parse a comma-separated argument list up to and including the closing `)`;
    /// `line`/`col` locate the opening `(` for an unbalanced-paren error.
    fn args(&mut self, line: usize, col: usize) -> Result<Vec<Ast>, ExprError> {
        let mut args = Vec::new();
        if matches!(self.peek().kind, TokenKind::RParen) {
            self.bump();
            return Ok(args);
        }
        loop {
            args.push(self.expr(0)?);
            match self.peek().kind {
                TokenKind::Comma => self.bump(),
                TokenKind::RParen => {
                    self.bump();
                    return Ok(args);
                }
                TokenKind::Eof => return Err(ExprError::UnbalancedParen { line, col }),
                _ => {
                    let token = self.peek();
                    return Err(ExprError::UnexpectedToken {
                        line: token.line,
                        col: token.col,
                    });
                }
            }
        }
    }

    /// Consume the `)` closing the `(` at `line`/`col`, or report the imbalance.
    fn expect_rparen(&mut self, line: usize, col: usize) -> Result<(), ExprError> {
        match self.peek().kind {
            TokenKind::RParen => {
                self.bump();
                Ok(())
            }
            TokenKind::Eof => Err(ExprError::UnbalancedParen { line, col }),
            _ => {
                let token = self.peek();
                Err(ExprError::UnexpectedToken {
                    line: token.line,
                    col: token.col,
                })
            }
        }
    }
}
