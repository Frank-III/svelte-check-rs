//! Template expression parsing and analysis using OXC.
//!
//! This module provides utilities for parsing and analyzing JavaScript expressions
//! that appear in Svelte template mustache tags like `{expression}`.

use oxc_allocator::Allocator;
use oxc_ast::ast::Expression;
use oxc_ast::Visit;
use oxc_parser::Parser;
use oxc_span::SourceType;

use smol_str::SmolStr;
use std::collections::HashSet;

/// Parsed expression with metadata.
#[derive(Debug)]
pub struct ParsedExpression {
    /// The original expression text.
    pub text: String,
    /// Information extracted from the expression.
    pub info: ExpressionInfo,
    /// Whether the expression parsed successfully.
    pub is_valid: bool,
    /// Parse error message, if any.
    pub error: Option<String>,
}

/// Information extracted from an expression.
#[derive(Debug, Default)]
pub struct ExpressionInfo {
    /// Variables referenced in the expression.
    pub variables: Vec<VariableRef>,
    /// Store subscriptions ($store syntax).
    pub store_subscriptions: HashSet<SmolStr>,
    /// The kind of expression.
    pub kind: ExpressionKind,
    /// Whether the expression is reactive (depends on reactive state).
    pub is_reactive: bool,
    /// Function calls in the expression.
    pub function_calls: Vec<SmolStr>,
}

/// A variable reference in an expression.
#[derive(Debug, Clone)]
pub struct VariableRef {
    /// The variable name.
    pub name: SmolStr,
    /// Start offset in the expression.
    pub start: u32,
    /// End offset in the expression.
    pub end: u32,
}

/// The kind of expression.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ExpressionKind {
    /// A simple identifier (e.g., `count`).
    Identifier,
    /// A literal value (e.g., `42`, `"hello"`).
    Literal,
    /// A member expression (e.g., `user.name`).
    MemberExpression,
    /// A function/method call (e.g., `foo()`, `bar.baz()`).
    CallExpression,
    /// A binary expression (e.g., `a + b`).
    BinaryExpression,
    /// A conditional expression (e.g., `a ? b : c`).
    ConditionalExpression,
    /// An arrow function (e.g., `() => {}`).
    ArrowFunction,
    /// An object literal (e.g., `{ a: 1 }`).
    ObjectLiteral,
    /// An array literal (e.g., `[1, 2, 3]`).
    ArrayLiteral,
    /// A template literal (e.g., `` `hello ${name}` ``).
    TemplateLiteral,
    /// Unknown or complex expression.
    #[default]
    Unknown,
}

/// Parse and analyze a template expression.
pub fn parse_expression(expr: &str) -> ParsedExpression {
    let allocator = Allocator::default();

    // Wrap in parentheses to make it a valid expression statement
    let wrapped = format!("({})", expr);
    let source_type = SourceType::tsx();

    let parser_return = Parser::new(&allocator, &wrapped, source_type).parse();

    if !parser_return.errors.is_empty() {
        return ParsedExpression {
            text: expr.to_string(),
            info: ExpressionInfo::default(),
            is_valid: false,
            error: Some(
                parser_return
                    .errors
                    .first()
                    .map(|e| e.message.to_string())
                    .unwrap_or_else(|| "Parse error".to_string()),
            ),
        };
    }

    // Analyze the parsed expression
    let mut analyzer = ExpressionAnalyzer::new();
    analyzer.visit_program(&parser_return.program);

    // Adjust offsets for the wrapping parenthesis
    for var in &mut analyzer.variables {
        if var.start > 0 {
            var.start -= 1;
        }
        if var.end > 0 {
            var.end -= 1;
        }
    }

    ParsedExpression {
        text: expr.to_string(),
        info: ExpressionInfo {
            variables: analyzer.variables,
            store_subscriptions: analyzer.store_subscriptions,
            kind: analyzer.kind,
            is_reactive: analyzer.is_reactive,
            function_calls: analyzer.function_calls,
        },
        is_valid: true,
        error: None,
    }
}

/// Analyzer for extracting information from expressions.
struct ExpressionAnalyzer {
    variables: Vec<VariableRef>,
    store_subscriptions: HashSet<SmolStr>,
    function_calls: Vec<SmolStr>,
    kind: ExpressionKind,
    is_reactive: bool,
    /// Depth in the AST (to identify top-level expression kind).
    depth: usize,
}

impl ExpressionAnalyzer {
    fn new() -> Self {
        Self {
            variables: Vec::new(),
            store_subscriptions: HashSet::new(),
            function_calls: Vec::new(),
            kind: ExpressionKind::Unknown,
            is_reactive: false,
            depth: 0,
        }
    }

    fn set_kind_if_top_level(&mut self, kind: ExpressionKind) {
        // Depth 2 means we're inside the ParenthesizedExpression we created
        if self.depth <= 2 {
            self.kind = kind;
        }
    }
}

impl<'a> Visit<'a> for ExpressionAnalyzer {
    fn visit_identifier_reference(&mut self, ident: &oxc_ast::ast::IdentifierReference<'a>) {
        let name = ident.name.as_str();

        // Check for store subscription ($storeName)
        if let Some(store_name) = name.strip_prefix('$') {
            if !store_name.is_empty()
                && !store_name.starts_with('$')
                && !is_rune_name(&format!("${}", store_name))
            {
                self.store_subscriptions.insert(SmolStr::new(store_name));
                self.is_reactive = true;
            }
        }

        // Track variable reference
        self.variables.push(VariableRef {
            name: SmolStr::new(name),
            start: ident.span.start,
            end: ident.span.end,
        });

        // Any identifier reference makes the expression potentially reactive
        self.is_reactive = true;
    }

    fn visit_expression(&mut self, expr: &Expression<'a>) {
        self.depth += 1;

        // Determine expression kind for top-level expressions
        match expr {
            Expression::Identifier(_) => {
                self.set_kind_if_top_level(ExpressionKind::Identifier);
            }
            Expression::BooleanLiteral(_)
            | Expression::NullLiteral(_)
            | Expression::NumericLiteral(_)
            | Expression::StringLiteral(_)
            | Expression::BigIntLiteral(_)
            | Expression::RegExpLiteral(_) => {
                self.set_kind_if_top_level(ExpressionKind::Literal);
            }
            Expression::StaticMemberExpression(_) | Expression::ComputedMemberExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::MemberExpression);
            }
            Expression::CallExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::CallExpression);
            }
            Expression::BinaryExpression(_) | Expression::LogicalExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::BinaryExpression);
            }
            Expression::ConditionalExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::ConditionalExpression);
            }
            Expression::ArrowFunctionExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::ArrowFunction);
            }
            Expression::ObjectExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::ObjectLiteral);
            }
            Expression::ArrayExpression(_) => {
                self.set_kind_if_top_level(ExpressionKind::ArrayLiteral);
            }
            Expression::TemplateLiteral(_) => {
                self.set_kind_if_top_level(ExpressionKind::TemplateLiteral);
            }
            _ => {}
        }

        // Continue visiting children
        oxc_ast::visit::walk::walk_expression(self, expr);

        self.depth -= 1;
    }

    fn visit_call_expression(&mut self, call: &oxc_ast::ast::CallExpression<'a>) {
        // Track function calls
        if let Some(name) = get_callee_name(call) {
            self.function_calls.push(SmolStr::new(name));
        }

        // Continue visiting
        oxc_ast::visit::walk::walk_call_expression(self, call);
    }
}

/// Get the name of a function call's callee.
fn get_callee_name<'a>(call: &'a oxc_ast::ast::CallExpression) -> Option<&'a str> {
    match &call.callee {
        Expression::Identifier(id) => Some(&id.name),
        Expression::StaticMemberExpression(member) => Some(&member.property.name),
        _ => None,
    }
}

/// Check if a name is a Svelte rune.
fn is_rune_name(name: &str) -> bool {
    matches!(
        name,
        "$state" | "$derived" | "$effect" | "$props" | "$bindable" | "$inspect" | "$host" | "$"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_identifier() {
        let result = parse_expression("count");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::Identifier);
        assert!(result.info.is_reactive);
        assert_eq!(result.info.variables.len(), 1);
        assert_eq!(result.info.variables[0].name.as_str(), "count");
    }

    #[test]
    fn test_parse_literal() {
        let result = parse_expression("42");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::Literal);
    }

    #[test]
    fn test_parse_member_expression() {
        let result = parse_expression("user.name");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::MemberExpression);
    }

    #[test]
    fn test_parse_binary_expression() {
        let result = parse_expression("a + b");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::BinaryExpression);
        assert_eq!(result.info.variables.len(), 2);
    }

    #[test]
    fn test_parse_call_expression() {
        let result = parse_expression("getData()");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::CallExpression);
        assert_eq!(result.info.function_calls.len(), 1);
        assert_eq!(result.info.function_calls[0].as_str(), "getData");
    }

    #[test]
    fn test_parse_store_subscription() {
        let result = parse_expression("$myStore");
        assert!(result.is_valid);
        assert!(result.info.store_subscriptions.contains("myStore"));
    }

    #[test]
    fn test_parse_object_literal() {
        let result = parse_expression("{ a: 1, b: 2 }");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::ObjectLiteral);
    }

    #[test]
    fn test_parse_arrow_function() {
        let result = parse_expression("() => console.log('hello')");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::ArrowFunction);
    }

    #[test]
    fn test_parse_invalid_expression() {
        let result = parse_expression("a + +");
        assert!(!result.is_valid);
        assert!(result.error.is_some());
    }

    #[test]
    fn test_parse_conditional() {
        let result = parse_expression("a ? b : c");
        assert!(result.is_valid);
        assert_eq!(result.info.kind, ExpressionKind::ConditionalExpression);
    }
}
