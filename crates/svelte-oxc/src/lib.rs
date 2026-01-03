//! OXC-based JavaScript/TypeScript parsing and transformation for Svelte.
//!
//! This crate provides utilities for parsing and transforming JavaScript/TypeScript
//! code within Svelte components using the OXC toolchain.
//!
//! ## Overview
//!
//! - [`parse_script`] - Parse JavaScript/TypeScript from Svelte script blocks
//! - [`transform_runes`] - Transform Svelte runes ($state, $derived, $props, etc.)
//! - [`validate`] - Validate scripts and expressions for syntax errors
//! - [`codegen`] - Generate TypeScript/TSX output

pub mod codegen;
pub mod expression;
pub mod parse;
pub mod runes;
pub mod utils;
pub mod validate;

pub use codegen::{generate_code, CodegenOptions, CodegenResult};
pub use expression::{
    parse_expression, ExpressionInfo, ExpressionKind, ParsedExpression, VariableRef,
};
pub use parse::{parse_script, ParseOptions, ParseResult};
pub use runes::{transform_runes, RuneTransformOptions, RuneTransformResult};
pub use validate::{validate_expression, validate_script, ValidationError, ValidationResult};
