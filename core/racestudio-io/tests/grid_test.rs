//! Tests for the uniform export grid (issue 5.1).

use racestudio_io::uniform_grid_ms;

#[test]
fn test_grid_starts_at_zero_and_steps_by_rate() {
    // 20 Hz over 500 ms → 50 ms steps: 0, 50, 100, …, 500 (11 samples).
    let grid = uniform_grid_ms(500.0, 20.0);
    assert_eq!(
        grid,
        vec![0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500]
    );
}

#[test]
fn test_grid_first_row_is_zero() {
    assert_eq!(uniform_grid_ms(1000.0, 20.0).first().copied(), Some(0));
}

#[test]
fn test_grid_sample_count_is_round_plus_one() {
    // n = round(duration/step) + 1. At 20 Hz (step 50 ms), 1000 ms → 21 samples.
    assert_eq!(uniform_grid_ms(1000.0, 20.0).len(), 21);
}

#[test]
fn test_grid_rounds_ties_to_even() {
    // 10 Hz → 100 ms step. duration 250 ms → 250/100 = 2.5 → round-half-to-even
    // → 2, so n = 3 and the grid is 0, 100, 200.
    assert_eq!(uniform_grid_ms(250.0, 10.0), vec![0, 100, 200]);
}

#[test]
fn test_grid_zero_duration_is_single_row() {
    assert_eq!(uniform_grid_ms(0.0, 20.0), vec![0]);
}

#[test]
fn test_grid_invalid_input_is_single_row() {
    // A non-positive/non-finite rate or non-finite duration degrades safely to a
    // single row rather than panicking (the writer rejects such rates up front).
    assert_eq!(uniform_grid_ms(500.0, 0.0), vec![0]);
    assert_eq!(uniform_grid_ms(500.0, -20.0), vec![0]);
    assert_eq!(uniform_grid_ms(500.0, f64::NAN), vec![0]);
    assert_eq!(uniform_grid_ms(f64::NAN, 20.0), vec![0]);
}

#[test]
fn test_grid_nonuniform_rate_rounds_each_time() {
    // 3 Hz → step 333.333… ms; each grid time is round(i·step): 0, 333, 667, 1000.
    assert_eq!(uniform_grid_ms(1000.0, 3.0), vec![0, 333, 667, 1000]);
}
