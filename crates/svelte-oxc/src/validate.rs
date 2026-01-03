//! Script and expression validation using OXC.
//!
//! This module provides validation for JavaScript/TypeScript code
//! within Svelte components, extracting syntax errors for diagnostics.

use oxc_allocator::Allocator;
use oxc_diagnostics::OxcDiagnostic;
use oxc_parser::Parser;
use oxc_span::SourceType;

/// Result of script validation.
#[derive(Debug, Default)]
pub struct ValidationResult {
    /// Whether the script is valid (no syntax errors).
    pub is_valid: bool,
    /// Syntax errors found during parsing.
    pub errors: Vec<ValidationError>,
    /// Whether the script contains TypeScript.
    pub is_typescript: bool,
}

/// A syntax error found during validation.
#[derive(Debug, Clone)]
pub struct ValidationError {
    /// Error message.
    pub message: String,
    /// Start offset in the source.
    pub start: u32,
    /// End offset in the source.
    pub end: u32,
}

impl From<OxcDiagnostic> for ValidationError {
    fn from(diag: OxcDiagnostic) -> Self {
        let message = diag.message.to_string();
        // OxcDiagnostic labels may have span info
        let (start, end) = diag
            .labels
            .as_ref()
            .and_then(|labels| labels.first())
            .map(|label| (label.offset() as u32, (label.offset() + label.len()) as u32))
            .unwrap_or((0, 0));

        ValidationError {
            message,
            start,
            end,
        }
    }
}

/// Validate a script block as TypeScript.
///
/// Returns validation errors if the script has syntax errors.
pub fn validate_script(source: &str, is_typescript: bool) -> ValidationResult {
    let allocator = Allocator::default();

    let source_type = if is_typescript {
        SourceType::tsx()
    } else {
        SourceType::mjs()
    };

    let parser_return = Parser::new(&allocator, source, source_type).parse();

    let errors: Vec<ValidationError> = parser_return.errors.into_iter().map(Into::into).collect();

    ValidationResult {
        is_valid: errors.is_empty(),
        errors,
        is_typescript,
    }
}

/// Validate a JavaScript/TypeScript expression.
///
/// This wraps the expression in a minimal context to check if it's valid.
pub fn validate_expression(expr: &str) -> ValidationResult {
    let allocator = Allocator::default();

    // Wrap in a minimal expression context
    let wrapped = format!("({})", expr);
    let source_type = SourceType::tsx();

    let parser_return = Parser::new(&allocator, &wrapped, source_type).parse();

    // Adjust error positions to account for the wrapping parenthesis
    let errors: Vec<ValidationError> = parser_return
        .errors
        .into_iter()
        .map(|diag| {
            let mut error: ValidationError = diag.into();
            // Adjust for the opening paren we added
            if error.start > 0 {
                error.start -= 1;
            }
            if error.end > 0 {
                error.end -= 1;
            }
            error
        })
        .collect();

    ValidationResult {
        is_valid: errors.is_empty(),
        errors,
        is_typescript: true,
    }
}

/// Validate multiple expressions and collect all errors.
pub fn validate_expressions<'a>(
    expressions: impl IntoIterator<Item = &'a str>,
) -> Vec<ValidationError> {
    let mut all_errors = Vec::new();

    for expr in expressions {
        let result = validate_expression(expr);
        all_errors.extend(result.errors);
    }

    all_errors
}

/// Check if a string looks like it contains TypeScript syntax.
///
/// This is a heuristic check for common TypeScript patterns.
pub fn looks_like_typescript(source: &str) -> bool {
    // Quick checks for common TypeScript patterns
    let patterns = [
        ": ",   // Type annotations
        " as ", // Type assertions
        "<>",   // Type parameters (empty)
        "interface ",
        "type ",
        "enum ",
        "namespace ",
        "declare ",
        "readonly ",
        "private ",
        "protected ",
        "public ",
        "abstract ",
        "implements ",
    ];

    for pattern in &patterns {
        if source.contains(pattern) {
            return true;
        }
    }

    // Check for generic type parameters like <T> or <T, U>
    let mut chars = source.chars().peekable();
    let mut in_string = None;
    let mut prev_was_escape = false;

    while let Some(ch) = chars.next() {
        // Track string context
        if prev_was_escape {
            prev_was_escape = false;
            continue;
        }

        if let Some(quote) = in_string {
            if ch == '\\' {
                prev_was_escape = true;
            } else if ch == quote {
                in_string = None;
            }
            continue;
        }

        if matches!(ch, '"' | '\'' | '`') {
            in_string = Some(ch);
            continue;
        }

        // Look for generic patterns: identifier<Type> or function<T>
        if ch == '<' {
            // Check if preceded by an identifier and followed by a type-like pattern
            if let Some(&next) = chars.peek() {
                if next.is_ascii_alphabetic() || next == '_' {
                    // Could be a generic type parameter
                    return true;
                }
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_valid_script() {
        let result = validate_script("let x = 1;", false);
        assert!(result.is_valid);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn test_validate_invalid_script() {
        let result = validate_script("let x = ;", false);
        assert!(!result.is_valid);
        assert!(!result.errors.is_empty());
    }

    #[test]
    fn test_validate_typescript() {
        let result = validate_script("let x: number = 1;", true);
        assert!(result.is_valid);
    }

    #[test]
    fn test_validate_expression() {
        let result = validate_expression("a + b");
        assert!(result.is_valid);
    }

    #[test]
    fn test_validate_invalid_expression() {
        let result = validate_expression("a + +");
        assert!(!result.is_valid);
    }

    #[test]
    fn test_looks_like_typescript() {
        assert!(looks_like_typescript("let x: number = 1;"));
        assert!(looks_like_typescript("const y = x as string;"));
        assert!(looks_like_typescript("interface Foo {}"));
        assert!(!looks_like_typescript("let x = 1;"));
    }
}
