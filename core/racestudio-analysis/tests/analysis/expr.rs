//! Math-channel expression-engine tests (issue 3.5).
//!
//! - **Precedence / parens** (`test_precedence_*`, `test_parentheses_*`): the
//!   arithmetic contract — `*`/`/` bind tighter than `+`/`-`, parentheses and
//!   unary minus override, all on hand-built expressions.
//! - **Functions** (`param_function_evaluation_table`): a table sweep over the
//!   whole function set (`abs min max sqrt sin cos tan log exp pow clamp`).
//! - **Channel series** (`test_channel_reference_resolves_series`): a bound
//!   resolver yields a per-sample series over the referenced channel's timebase.
//! - **Property** (`prop_*`): random *arbitrary* strings never panic (every
//!   failure is a typed `ExprError`), and pretty-print is idempotent through a
//!   parse cycle. Swept deterministically over a large input space (an in-test
//!   LCG) rather than with `proptest`, which perturbs this repo's CI coverage
//!   instrumentation (see issue 3.3); the coverage-gate intent is unchanged.
//! - **Errors** (`test_*_is_typed_error`, positions): every malformed input
//!   returns a typed `ExprError` carrying `(line, col)` — never a panic.

use std::collections::HashMap;

use racestudio_analysis::expr::{
    eval_scalar, eval_series, parse, parse_str, tokenize, Ast, Env, ExprError, Func,
};

// --------------------------------------------------------------------------- //
// Helpers
// --------------------------------------------------------------------------- //

/// Parse + scalar-evaluate `src` in an empty environment, panicking (test-only)
/// with the typed error if either step fails.
fn eval(src: &str) -> f64 {
    let ast = parse_str(src).unwrap_or_else(|e| panic!("parse `{src}`: {e:?}"));
    eval_scalar(&ast, &Env::new()).unwrap_or_else(|e| panic!("eval `{src}`: {e:?}"))
}

/// A tiny deterministic LCG so the sweeps cover a wide, reproducible input space
/// without a randomness / property-testing dependency.
fn lcg(state: &mut u64) -> u64 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1_442_695_040_888_963_407);
    *state >> 16
}

/// Generate a syntactically well-formed expression of bounded depth.
fn gen_expr(state: &mut u64, depth: u32) -> String {
    if depth == 0 || lcg(state) % 3 == 0 {
        return match lcg(state) % 2 {
            0 => (lcg(state) % 100).to_string(),
            _ => ["x", "y", "Ax", "Ay", "GPS_Speed"][(lcg(state) % 5) as usize].to_string(),
        };
    }
    match lcg(state) % 6 {
        0 => format!(
            "({} + {})",
            gen_expr(state, depth - 1),
            gen_expr(state, depth - 1)
        ),
        1 => format!(
            "({} - {})",
            gen_expr(state, depth - 1),
            gen_expr(state, depth - 1)
        ),
        2 => format!(
            "({} * {})",
            gen_expr(state, depth - 1),
            gen_expr(state, depth - 1)
        ),
        3 => format!(
            "({} / {})",
            gen_expr(state, depth - 1),
            gen_expr(state, depth - 1)
        ),
        4 => format!("-{}", gen_expr(state, depth - 1)),
        _ => match lcg(state) % 3 {
            0 => {
                let f =
                    ["abs", "sqrt", "sin", "cos", "tan", "log", "exp"][(lcg(state) % 7) as usize];
                format!("{f}({})", gen_expr(state, depth - 1))
            }
            1 => {
                let f = ["min", "max", "pow"][(lcg(state) % 3) as usize];
                format!(
                    "{f}({}, {})",
                    gen_expr(state, depth - 1),
                    gen_expr(state, depth - 1)
                )
            }
            _ => format!(
                "clamp({}, {}, {})",
                gen_expr(state, depth - 1),
                gen_expr(state, depth - 1),
                gen_expr(state, depth - 1)
            ),
        },
    }
}

// --------------------------------------------------------------------------- //
// Precedence & parentheses
// --------------------------------------------------------------------------- //

#[test]
fn test_precedence_mul_before_add() {
    assert_eq!(eval("2 + 3 * 4"), 14.0, "* binds tighter than +");
    assert_eq!(eval("2 * 3 + 4"), 10.0);
    assert_eq!(eval("10 - 2 * 3"), 4.0, "* binds tighter than -");
    assert_eq!(eval("12 / 3 + 1"), 5.0);
}

#[test]
fn test_parentheses_override_precedence() {
    assert_eq!(eval("(2 + 3) * 4"), 20.0);
    assert_eq!(eval("2 * (3 + 4)"), 14.0);
    assert_eq!(eval("((1 + 2) * (3 + 4))"), 21.0);
}

#[test]
fn test_left_associativity_of_subtraction_and_division() {
    assert_eq!(eval("10 - 3 - 2"), 5.0, "(10 - 3) - 2");
    assert_eq!(eval("100 / 5 / 2"), 10.0, "(100 / 5) / 2");
}

#[test]
fn test_unary_minus() {
    assert_eq!(eval("-5"), -5.0);
    assert_eq!(eval("-5 + 2"), -3.0);
    assert_eq!(eval("3 - -2"), 5.0, "binary minus then unary minus");
    assert_eq!(eval("-(2 + 3)"), -5.0);
    assert_eq!(eval("--4"), 4.0, "double negation");
    assert_eq!(eval("-2 * 3"), -6.0, "unary minus binds tighter than *");
}

// --------------------------------------------------------------------------- //
// Numeric literals: whitespace-insensitive, scientific notation
// --------------------------------------------------------------------------- //

#[test]
fn test_scientific_notation_literals() {
    assert!((eval("1e-3") - 0.001).abs() < 1e-15);
    assert!((eval("2.5E2") - 250.0).abs() < 1e-12);
    assert!((eval("1.5e0") - 1.5).abs() < 1e-12);
    assert!((eval("6.022e23") - 6.022e23).abs() < 1e10);
}

#[test]
fn test_lexer_is_whitespace_insensitive() {
    assert_eq!(eval("  2\t+\n  3  "), 5.0);
    assert_eq!(eval("2*3"), eval("2 * 3"));
    assert_eq!(eval("sqrt ( 16 )"), 4.0);
}

// --------------------------------------------------------------------------- //
// Functions
// --------------------------------------------------------------------------- //

#[test]
fn param_function_evaluation_table() {
    let cases: &[(&str, f64)] = &[
        ("abs(-3)", 3.0),
        ("abs(3)", 3.0),
        ("sqrt(9)", 3.0),
        ("sqrt(2)", std::f64::consts::SQRT_2),
        ("min(2, 5)", 2.0),
        ("max(2, 5)", 5.0),
        ("pow(2, 10)", 1024.0),
        ("clamp(5, 0, 3)", 3.0),
        ("clamp(-1, 0, 3)", 0.0),
        ("clamp(2, 0, 3)", 2.0),
        ("exp(0)", 1.0),
        ("log(1)", 0.0),
        ("log(exp(1))", 1.0),
        ("sin(0)", 0.0),
        ("cos(0)", 1.0),
        ("tan(0)", 0.0),
    ];
    for &(src, expected) in cases {
        let got = eval(src);
        assert!(
            (got - expected).abs() < 1e-12,
            "{src} evaluated to {got}, expected {expected}"
        );
    }
}

#[test]
fn test_nested_functions() {
    assert_eq!(eval("sqrt(pow(3, 2) + pow(4, 2))"), 5.0);
    assert_eq!(eval("max(min(1, 2), min(3, 4))"), 3.0);
}

// --------------------------------------------------------------------------- //
// Channel references & series evaluation
// --------------------------------------------------------------------------- //

#[test]
fn test_channel_reference_resolves_series() {
    let mut channels: HashMap<String, Vec<f64>> = HashMap::new();
    channels.insert("GPS_Speed".to_string(), vec![0.0, 4.0, 9.0, 16.0]);

    let ast = parse_str("sqrt(GPS_Speed)").expect("parse");
    let out = eval_series(&ast, &channels).expect("series");
    assert_eq!(out, vec![0.0, 2.0, 3.0, 4.0]);
}

#[test]
fn test_series_combines_two_channels() {
    // magnitude = sqrt(Ax*Ax + Ay*Ay), classic 3-4-5.
    let mut channels: HashMap<String, Vec<f64>> = HashMap::new();
    channels.insert("Ax".to_string(), vec![3.0, 0.0, 6.0]);
    channels.insert("Ay".to_string(), vec![4.0, 0.0, 8.0]);

    let ast = parse_str("sqrt(Ax * Ax + Ay * Ay)").expect("parse");
    let out = eval_series(&ast, &channels).expect("series");
    assert_eq!(out, vec![5.0, 0.0, 10.0]);
}

#[test]
fn test_series_constant_broadcasts_and_scales() {
    let mut channels: HashMap<String, Vec<f64>> = HashMap::new();
    channels.insert("v".to_string(), vec![1.0, 2.0, 3.0]);

    let ast = parse_str("2 * v + 1").expect("parse");
    let out = eval_series(&ast, &channels).expect("series");
    assert_eq!(out, vec![3.0, 5.0, 7.0]);
}

#[test]
fn test_series_handles_unary_minus_on_channel() {
    let mut channels: HashMap<String, Vec<f64>> = HashMap::new();
    channels.insert("v".to_string(), vec![1.0, -2.0, 3.0]);
    let ast = parse_str("-v").expect("parse");
    let out = eval_series(&ast, &channels).expect("series");
    assert_eq!(out, vec![-1.0, 2.0, -3.0]);
}

#[test]
fn test_scalar_env_channel_lookup() {
    let mut env = Env::new();
    env.bind("x", 5.0).bind("y", 3.0);
    let ast = parse_str("x * y - 1").expect("parse");
    assert_eq!(eval_scalar(&ast, &env).expect("eval"), 14.0);
}

// --------------------------------------------------------------------------- //
// Division-by-zero policy (IEEE, never a panic)
// --------------------------------------------------------------------------- //

#[test]
fn test_division_by_zero_is_inf_or_nan_not_panic() {
    assert!(eval("1 / 0").is_infinite() && eval("1 / 0") > 0.0);
    assert!(eval("-1 / 0").is_infinite() && eval("-1 / 0") < 0.0);
    assert!(eval("0 / 0").is_nan());
}

// --------------------------------------------------------------------------- //
// Property sweeps (deterministic)
// --------------------------------------------------------------------------- //

#[test]
fn prop_random_expr_never_panics() {
    // Arbitrary, mostly-malformed strings must never panic: every failure is a
    // typed ExprError. Then well-formed strings must parse AND evaluate without
    // panicking (division-by-zero yields Inf/NaN, not a crash).
    let alphabet: &[u8] = b"0123456789 +-*/(),.eE_xyzABCsqrtminmaxclamppowsincoslgabtn@#";

    let mut state = 0xF00D_1234_u64;
    for _ in 0..6000 {
        let len = (lcg(&mut state) % 24) as usize;
        let src: String = (0..len)
            .map(|_| alphabet[(lcg(&mut state) as usize) % alphabet.len()] as char)
            .collect();
        if let Ok(ast) = parse_str(&src) {
            let _ = eval_scalar(&ast, &Env::new());
        }
    }

    let mut env = Env::new();
    env.bind("x", 1.5)
        .bind("y", -2.0)
        .bind("Ax", 3.0)
        .bind("Ay", 4.0)
        .bind("GPS_Speed", 25.0);
    let mut state = 0x0BAD_CAFE_u64;
    for _ in 0..3000 {
        let src = gen_expr(&mut state, 4);
        let ast = parse_str(&src)
            .unwrap_or_else(|e| panic!("well-formed `{src}` failed to parse: {e:?}"));
        let _ = eval_scalar(&ast, &env);
    }
}

#[test]
fn prop_pretty_print_roundtrips() {
    // Pretty-print is idempotent through a parse cycle: parsing a printed AST and
    // re-printing yields the identical string.
    let mut state = 0x1234_5678_u64;
    for _ in 0..3000 {
        let src = gen_expr(&mut state, 4);
        let ast = parse_str(&src).unwrap_or_else(|e| panic!("parse `{src}`: {e:?}"));
        let printed = ast.to_string();
        let reparsed = parse_str(&printed)
            .unwrap_or_else(|e| panic!("reparse of pretty-print `{printed}`: {e:?}"));
        assert_eq!(
            printed,
            reparsed.to_string(),
            "pretty-print not stable through a parse cycle (from `{src}`)"
        );
    }
}

// --------------------------------------------------------------------------- //
// Typed errors with positions
// --------------------------------------------------------------------------- //

#[test]
fn test_unknown_ident_is_typed_error() {
    // Unknown channel surfaces at evaluation.
    let ast = parse_str("foo + 1").expect("parse");
    let err = eval_scalar(&ast, &Env::new()).expect_err("unknown channel");
    match err {
        ExprError::UnknownIdent { name, line, col } => {
            assert_eq!(name, "foo");
            assert_eq!((line, col), (1, 1), "position of `foo`");
        }
        other => panic!("expected UnknownIdent, got {other:?}"),
    }

    // Unknown function surfaces at parse.
    let err = parse_str("frobnicate(1)").expect_err("unknown function");
    assert!(matches!(err, ExprError::UnknownIdent { .. }), "got {err:?}");
}

#[test]
fn test_unbalanced_paren_is_typed_error() {
    let err = parse_str("(2 + 3").expect_err("missing rparen");
    assert!(
        matches!(err, ExprError::UnbalancedParen { .. }),
        "got {err:?}"
    );

    let err = parse_str("sqrt(1").expect_err("missing rparen in call");
    assert!(
        matches!(err, ExprError::UnbalancedParen { .. }),
        "got {err:?}"
    );
}

#[test]
fn test_unexpected_token_is_typed_error() {
    for src in ["2 +", "2 3", "* 2", "2 + 3)", ""] {
        let err = parse_str(src).expect_err("should not parse");
        assert!(
            matches!(err, ExprError::UnexpectedToken { .. }),
            "`{src}` gave {err:?}"
        );
    }
}

#[test]
fn test_arity_mismatch_is_typed_error() {
    for src in [
        "sqrt(1, 2)",
        "min(1)",
        "clamp(1, 2)",
        "pow(1, 2, 3)",
        "abs()",
    ] {
        let err = parse_str(src).expect_err("arity");
        match err {
            ExprError::ArityMismatch { .. } => {}
            other => panic!("`{src}` expected ArityMismatch, got {other:?}"),
        }
    }
}

#[test]
fn test_lex_error_is_typed_with_position() {
    let err = tokenize("2 @ 3").expect_err("invalid char");
    match err {
        ExprError::LexError { line, col, .. } => assert_eq!((line, col), (1, 3), "position of `@`"),
        other => panic!("expected LexError, got {other:?}"),
    }
}

#[test]
fn test_tokenize_then_parse_matches_parse_str() {
    let tokens = tokenize("1 + 2 * 3").expect("tokenize");
    let ast = parse(&tokens).expect("parse");
    assert_eq!(eval_scalar(&ast, &Env::new()).expect("eval"), 7.0);
}

#[test]
fn test_error_display_is_human_readable() {
    let err = parse_str("(1").expect_err("unbalanced");
    let text = err.to_string();
    assert!(!text.is_empty());
    assert!(
        text.contains("1"),
        "message mentions a position/line: {text}"
    );
}

#[test]
fn test_error_display_covers_all_variants() {
    let variants = [
        ExprError::LexError {
            line: 1,
            col: 3,
            ch: '@',
        },
        ExprError::UnexpectedToken { line: 2, col: 4 },
        ExprError::UnknownIdent {
            name: "foo".to_string(),
            line: 1,
            col: 1,
        },
        ExprError::ArityMismatch {
            name: "min".to_string(),
            expected: 2,
            found: 1,
            line: 1,
            col: 1,
        },
        ExprError::UnbalancedParen { line: 1, col: 1 },
    ];
    for err in &variants {
        let text = err.to_string();
        assert!(!text.is_empty(), "{err:?} has a message");
        assert!(
            text.contains(':'),
            "{err:?} message carries a position: {text}"
        );
    }
}

// --------------------------------------------------------------------------- //
// Series edge cases & defensive evaluation
// --------------------------------------------------------------------------- //

#[test]
fn test_eval_series_of_constant_is_single_value() {
    // No channel references → no timebase → one value.
    let channels: HashMap<String, Vec<f64>> = HashMap::new();
    let ast = parse_str("2 + 3 * 4").expect("parse");
    assert_eq!(eval_series(&ast, &channels).expect("series"), vec![14.0]);
}

#[test]
fn test_eval_series_unknown_channel_is_typed_error() {
    let channels: HashMap<String, Vec<f64>> = HashMap::new();
    let ast = parse_str("missing + 1").expect("parse");
    let err = eval_series(&ast, &channels).expect_err("unknown channel");
    assert!(matches!(err, ExprError::UnknownIdent { .. }), "got {err:?}");
}

#[test]
fn test_eval_series_truncates_to_shortest_channel() {
    let mut channels: HashMap<String, Vec<f64>> = HashMap::new();
    channels.insert("a".to_string(), vec![1.0, 2.0, 3.0]);
    channels.insert("b".to_string(), vec![10.0, 20.0]); // shorter
    let ast = parse_str("a + b").expect("parse");
    assert_eq!(
        eval_series(&ast, &channels).expect("series"),
        vec![11.0, 22.0]
    );
}

#[test]
fn test_apply_tolerates_malformed_arity_without_panic() {
    // A directly-built call whose arity is violated (the parser never emits one)
    // must not panic: missing arguments read as NaN.
    let zero_arg = Ast::Call {
        func: Func::Sqrt,
        args: vec![],
    };
    assert!(eval_scalar(&zero_arg, &Env::new()).expect("eval").is_nan());

    let under_arg = Ast::Call {
        func: Func::Clamp,
        args: vec![Ast::Number(5.0)],
    };
    // clamp(5, NaN, NaN) — no panic; f64 min/max drop the NaN operands.
    assert_eq!(eval_scalar(&under_arg, &Env::new()).expect("eval"), 5.0);
}

// --------------------------------------------------------------------------- //
// Parser error branches
// --------------------------------------------------------------------------- //

#[test]
fn test_parser_reports_bad_argument_separator() {
    // A non-comma, non-`)` token after an argument.
    let err = parse_str("min(1 2)").expect_err("missing comma");
    assert!(
        matches!(err, ExprError::UnexpectedToken { .. }),
        "got {err:?}"
    );
}

#[test]
fn test_parser_reports_missing_close_after_group() {
    // `(1 2)` — after the inner expression the next token is not `)`.
    let err = parse_str("(1 2)").expect_err("bad group");
    assert!(
        matches!(err, ExprError::UnexpectedToken { .. }),
        "got {err:?}"
    );
}

#[test]
fn test_parse_empty_token_slice_is_typed_error() {
    // `parse` is robust to a slice with no trailing Eof (never panics).
    let err = parse(&[]).expect_err("empty tokens");
    assert!(
        matches!(err, ExprError::UnexpectedToken { .. }),
        "got {err:?}"
    );
}
