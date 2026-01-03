//! JavaScript/TypeScript parsing using OXC.
//!
//! This module provides utilities for parsing JavaScript/TypeScript code from
//! Svelte script blocks using the OXC parser.

use oxc_allocator::Allocator;
use oxc_ast::ast::Program;
use oxc_parser::{Parser, ParserReturn};
use oxc_span::SourceType;

/// Options for parsing JavaScript/TypeScript.
#[derive(Debug, Clone, Default)]
pub struct ParseOptions {
    /// Whether the script is TypeScript.
    pub typescript: bool,
    /// Whether to allow JSX syntax.
    pub jsx: bool,
    /// The filename for error messages.
    pub filename: Option<String>,
}

/// Result of parsing JavaScript/TypeScript.
pub struct ParseResult<'a> {
    /// The parsed program.
    pub program: Program<'a>,
    /// Any parse errors.
    pub errors: Vec<oxc_diagnostics::OxcDiagnostic>,
    /// Whether parsing was successful (no errors).
    pub is_valid: bool,
}

/// Parse JavaScript/TypeScript source code.
///
/// # Arguments
///
/// * `allocator` - The OXC allocator for AST nodes
/// * `source` - The source code to parse
/// * `options` - Parsing options
///
/// # Returns
///
/// A `ParseResult` containing the parsed program and any errors.
///
/// # Example
///
/// ```ignore
/// use oxc_allocator::Allocator;
/// use svelte_oxc::{parse_script, ParseOptions};
///
/// let allocator = Allocator::default();
/// let source = "let count = $state(0);";
/// let result = parse_script(&allocator, source, ParseOptions {
///     typescript: true,
///     ..Default::default()
/// });
/// assert!(result.is_valid);
/// ```
pub fn parse_script<'a>(
    allocator: &'a Allocator,
    source: &'a str,
    options: ParseOptions,
) -> ParseResult<'a> {
    // Determine source type based on options
    let source_type = if options.typescript {
        if options.jsx {
            SourceType::tsx()
        } else {
            SourceType::ts()
        }
    } else if options.jsx {
        SourceType::jsx()
    } else {
        SourceType::mjs()
    };

    // Parse the source
    let parser_return: ParserReturn = Parser::new(allocator, source, source_type).parse();

    let is_valid = parser_return.errors.is_empty();

    ParseResult {
        program: parser_return.program,
        errors: parser_return.errors,
        is_valid,
    }
}

/// Parse a single JavaScript/TypeScript expression.
///
/// This is useful for parsing expressions from Svelte template bindings.
pub fn parse_expression<'a>(
    allocator: &'a Allocator,
    source: &'a str,
    typescript: bool,
) -> ParseResult<'a> {
    // Wrap in parentheses to parse as expression statement
    let wrapped = allocator.alloc_str(&format!("({})", source));

    parse_script(
        allocator,
        wrapped,
        ParseOptions {
            typescript,
            jsx: false,
            filename: None,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_basic_js() {
        let allocator = Allocator::default();
        let source = "let x = 1;";
        let result = parse_script(&allocator, source, ParseOptions::default());
        assert!(result.is_valid);
        assert_eq!(result.program.body.len(), 1);
    }

    #[test]
    fn test_parse_typescript() {
        let allocator = Allocator::default();
        let source = "let x: number = 1;";
        let result = parse_script(
            &allocator,
            source,
            ParseOptions {
                typescript: true,
                ..Default::default()
            },
        );
        assert!(result.is_valid);
    }

    #[test]
    fn test_parse_rune_syntax() {
        let allocator = Allocator::default();
        let source = "let count = $state(0);";
        let result = parse_script(
            &allocator,
            source,
            ParseOptions {
                typescript: true,
                ..Default::default()
            },
        );
        // $state is valid JS syntax (function call)
        assert!(result.is_valid);
    }

    #[test]
    fn test_parse_expression() {
        let allocator = Allocator::default();
        let source = "count + 1";
        let result = parse_expression(&allocator, source, false);
        assert!(result.is_valid);
    }

    #[test]
    fn test_parse_invalid() {
        let allocator = Allocator::default();
        let source = "let x = ;"; // Invalid syntax
        let result = parse_script(&allocator, source, ParseOptions::default());
        assert!(!result.is_valid);
        assert!(!result.errors.is_empty());
    }
}
