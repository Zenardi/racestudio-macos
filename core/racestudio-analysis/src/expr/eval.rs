//! Evaluator (issue 3.5): compute an [`Ast`] to a scalar against an [`Env`], or
//! to a per-sample series against a [`ChannelResolver`].
//!
//! Both share one recursion parameterised by how a channel name resolves to a
//! value. Arithmetic is IEEE-754: **division by zero yields `±∞` or `NaN`, never
//! an error or a panic** (a documented policy). Functions are total — `clamp`
//! is `x.max(lo).min(hi)` (not `f64::clamp`, which panics when `lo > hi`), and a
//! call whose arity was somehow violated reads missing arguments as `NaN` rather
//! than panicking.

use std::collections::HashMap;

use super::error::ExprError;
use super::parser::{Ast, BinOp, Func};

/// A scalar environment: channel-name → value bindings for [`eval_scalar`].
#[derive(Debug, Clone, Default)]
pub struct Env {
    vars: HashMap<String, f64>,
}

impl Env {
    /// An empty environment.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Bind `name` to `value`, returning `self` for chaining.
    pub fn bind(&mut self, name: impl Into<String>, value: f64) -> &mut Self {
        self.vars.insert(name.into(), value);
        self
    }

    /// The value bound to `name`, if any.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<f64> {
        self.vars.get(name).copied()
    }
}

/// Resolves a channel name to its per-sample series for [`eval_series`].
pub trait ChannelResolver {
    /// The samples for `name`, or `None` if the channel is unknown.
    fn resolve(&self, name: &str) -> Option<&[f64]>;
}

impl ChannelResolver for HashMap<String, Vec<f64>> {
    fn resolve(&self, name: &str) -> Option<&[f64]> {
        self.get(name).map(Vec::as_slice)
    }
}

/// Evaluate `ast` to a single value, resolving channel references through `env`.
///
/// # Errors
/// [`ExprError::UnknownIdent`] if the expression references a channel that
/// `env` does not bind.
pub fn eval_scalar(ast: &Ast, env: &Env) -> Result<f64, ExprError> {
    eval_node(ast, &|name, line, col| {
        env.get(name).ok_or_else(|| ExprError::UnknownIdent {
            name: name.to_string(),
            line,
            col,
        })
    })
}

/// Evaluate `ast` to a per-sample series, resolving channel references through
/// `resolver`. The result length is the shortest referenced channel; a
/// constant expression (no channel references) yields a single value.
///
/// # Errors
/// [`ExprError::UnknownIdent`] if the expression references a channel that
/// `resolver` does not know.
pub fn eval_series(ast: &Ast, resolver: &dyn ChannelResolver) -> Result<Vec<f64>, ExprError> {
    let mut refs = Vec::new();
    collect_channels(ast, &mut refs);

    // A constant expression has no timebase → a single value.
    if refs.is_empty() {
        return Ok(vec![eval_scalar(ast, &Env::new())?]);
    }

    // Resolve each distinct channel once (failing fast on an unknown one); the
    // series length is the shortest referenced channel.
    let mut resolved: Vec<(&str, &[f64])> = Vec::new();
    let mut length = usize::MAX;
    for (name, line, col) in &refs {
        if resolved.iter().any(|(seen, _)| *seen == name.as_str()) {
            continue;
        }
        let series = resolver
            .resolve(name)
            .ok_or_else(|| ExprError::UnknownIdent {
                name: name.clone(),
                line: *line,
                col: *col,
            })?;
        length = length.min(series.len());
        resolved.push((name.as_str(), series));
    }

    // Evaluate per sample by re-binding the referenced channels into one reused
    // scalar environment — the same evaluation path as `eval_scalar`.
    let mut env = Env::new();
    let mut out = Vec::with_capacity(length);
    for i in 0..length {
        for (name, series) in &resolved {
            env.bind(*name, series[i]);
        }
        out.push(eval_scalar(ast, &env)?);
    }
    Ok(out)
}

/// Recursively evaluate `ast`, resolving each channel reference through `lookup`
/// (called with the reference's name and 1-based position).
fn eval_node<F>(ast: &Ast, lookup: &F) -> Result<f64, ExprError>
where
    F: Fn(&str, usize, usize) -> Result<f64, ExprError>,
{
    Ok(match ast {
        Ast::Number(value) => *value,
        Ast::Channel { name, line, col } => lookup(name, *line, *col)?,
        Ast::Neg(inner) => -eval_node(inner, lookup)?,
        Ast::Binary(op, lhs, rhs) => {
            let a = eval_node(lhs, lookup)?;
            let b = eval_node(rhs, lookup)?;
            match op {
                BinOp::Add => a + b,
                BinOp::Sub => a - b,
                BinOp::Mul => a * b,
                BinOp::Div => a / b, // IEEE: ±∞ / NaN, never a panic.
            }
        }
        Ast::Call { func, args } => {
            let mut values = Vec::with_capacity(args.len());
            for arg in args {
                values.push(eval_node(arg, lookup)?);
            }
            apply(*func, &values)
        }
    })
}

/// Apply a built-in function. Total and panic-free: missing arguments (only
/// possible on a hand-built, arity-violating AST) read as `NaN`.
fn apply(func: Func, values: &[f64]) -> f64 {
    let a = values.first().copied().unwrap_or(f64::NAN);
    let b = values.get(1).copied().unwrap_or(f64::NAN);
    let c = values.get(2).copied().unwrap_or(f64::NAN);
    match func {
        Func::Abs => a.abs(),
        Func::Sqrt => a.sqrt(),
        Func::Sin => a.sin(),
        Func::Cos => a.cos(),
        Func::Tan => a.tan(),
        Func::Log => a.ln(),
        Func::Exp => a.exp(),
        Func::Min => a.min(b),
        Func::Max => a.max(b),
        Func::Pow => a.powf(b),
        Func::Clamp => a.max(b).min(c), // not f64::clamp: that panics when b > c.
    }
}

/// Collect every channel reference (name + position) in evaluation order.
fn collect_channels(ast: &Ast, out: &mut Vec<(String, usize, usize)>) {
    match ast {
        Ast::Number(_) => {}
        Ast::Channel { name, line, col } => out.push((name.clone(), *line, *col)),
        Ast::Neg(inner) => collect_channels(inner, out),
        Ast::Binary(_, lhs, rhs) => {
            collect_channels(lhs, out);
            collect_channels(rhs, out);
        }
        Ast::Call { args, .. } => {
            for arg in args {
                collect_channels(arg, out);
            }
        }
    }
}
