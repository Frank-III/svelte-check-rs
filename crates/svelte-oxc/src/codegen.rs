//! Code generation using OXC codegen.
//!
//! This module provides utilities for generating TypeScript/TSX output
//! from OXC AST nodes.

use oxc_allocator::Allocator;
use oxc_ast::ast::Program;
use oxc_codegen::{Codegen, CodegenOptions as OxcCodegenOptions, CodegenReturn};

/// Options for code generation.
#[derive(Debug, Clone, Default)]
pub struct CodegenOptions {
    /// Use single quotes for strings.
    pub single_quote: bool,
    /// Indentation width.
    pub indent_width: u8,
    /// Whether to generate source maps.
    pub source_map: bool,
    /// The source filename for source maps.
    pub source_filename: Option<String>,
}

/// Result of code generation.
#[derive(Debug)]
pub struct CodegenResult {
    /// The generated code.
    pub code: String,
    /// The source map, if requested.
    pub source_map: Option<String>,
}

/// Generate code from an OXC program AST.
///
/// # Arguments
///
/// * `program` - The parsed program AST
/// * `options` - Code generation options
///
/// # Returns
///
/// A `CodegenResult` with the generated code and optional source map.
pub fn generate_code(program: &Program, options: CodegenOptions) -> CodegenResult {
    let mut codegen = Codegen::new();

    let oxc_options = OxcCodegenOptions {
        single_quote: options.single_quote,
        ..Default::default()
    };

    codegen = codegen.with_options(oxc_options);

    let result: CodegenReturn = codegen.build(program);

    CodegenResult {
        code: result.code,
        source_map: result.map.map(|m| m.to_json_string()),
    }
}

/// Generate code for a single expression.
///
/// This wraps the expression in a minimal program and generates code.
pub fn generate_expression(allocator: &Allocator, source: &str) -> Option<String> {
    use oxc_parser::Parser;
    use oxc_span::SourceType;

    // Parse as expression statement
    let wrapped = format!("({})", source);
    let parser_return = Parser::new(allocator, &wrapped, SourceType::tsx()).parse();

    if !parser_return.errors.is_empty() {
        return None;
    }

    let result = Codegen::new()
        .with_options(OxcCodegenOptions {
            single_quote: true,
            ..Default::default()
        })
        .build(&parser_return.program);

    // Remove the wrapping and trailing semicolon
    let code = result.code.trim();
    if code.starts_with('(') && code.ends_with(");") {
        Some(code[1..code.len() - 2].to_string())
    } else {
        Some(code.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use oxc_parser::Parser;
    use oxc_span::SourceType;

    #[test]
    fn test_generate_code() {
        let allocator = Allocator::default();
        let source = "let x = 1;";
        let parser_return = Parser::new(&allocator, source, SourceType::tsx()).parse();

        let result = generate_code(&parser_return.program, CodegenOptions::default());
        assert!(result.code.contains("let x = 1"));
    }

    #[test]
    fn test_generate_expression() {
        let allocator = Allocator::default();
        let result = generate_expression(&allocator, "1 + 2");
        // OXC codegen may add a semicolon, so we just check the expression is there
        assert!(result.is_some());
        assert!(result.unwrap().contains("1 + 2"));
    }
}
