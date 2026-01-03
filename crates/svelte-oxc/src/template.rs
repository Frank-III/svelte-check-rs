//! Template expression utilities using OXC.
//!
//! This module provides OXC-based utilities for analyzing and transforming
//! Svelte template expressions.

use crate::expression::{parse_expression, ExpressionKind};
use smol_str::SmolStr;
use std::collections::HashSet;

/// Result of analyzing a template expression.
#[derive(Debug)]
pub struct TemplateExpressionAnalysis {
    /// The original expression.
    pub expression: String,
    /// Store subscriptions found ($store syntax).
    pub store_subscriptions: HashSet<SmolStr>,
    /// Whether the expression is valid JavaScript/TypeScript.
    pub is_valid: bool,
    /// Parse error if invalid.
    pub error: Option<String>,
    /// The kind of expression.
    pub kind: ExpressionKind,
    /// Whether this is a simple expression (identifier, literal, member access).
    pub is_simple: bool,
    /// Whether the expression contains function calls.
    pub has_function_calls: bool,
}

/// Analyze a template expression using OXC.
///
/// This provides richer information than string-based analysis:
/// - Accurate store subscription detection
/// - Expression classification
/// - Syntax validation
pub fn analyze_template_expression(expr: &str) -> TemplateExpressionAnalysis {
    let parsed = parse_expression(expr);

    let is_simple = matches!(
        parsed.info.kind,
        ExpressionKind::Identifier | ExpressionKind::Literal | ExpressionKind::MemberExpression
    );

    TemplateExpressionAnalysis {
        expression: expr.to_string(),
        store_subscriptions: parsed.info.store_subscriptions,
        is_valid: parsed.is_valid,
        error: parsed.error,
        kind: parsed.info.kind,
        is_simple,
        has_function_calls: !parsed.info.function_calls.is_empty(),
    }
}

/// Collect store subscriptions from multiple template expressions.
///
/// Returns a set of store names that need alias declarations.
pub fn collect_store_subscriptions<'a>(
    expressions: impl IntoIterator<Item = &'a str>,
) -> HashSet<SmolStr> {
    let mut stores = HashSet::new();

    for expr in expressions {
        let analysis = analyze_template_expression(expr);
        stores.extend(analysis.store_subscriptions);
    }

    stores
}

/// Validate a template expression and return any errors.
pub fn validate_template_expression(expr: &str) -> Option<String> {
    let parsed = parse_expression(expr);
    parsed.error
}

/// Check if an expression is a simple reactive expression.
///
/// Simple expressions are:
/// - Identifiers: `count`
/// - Member expressions: `user.name`
/// - Literals: `42`, `"hello"`
///
/// These can be optimized differently from complex expressions.
pub fn is_simple_expression(expr: &str) -> bool {
    let parsed = parse_expression(expr);
    parsed.is_valid
        && matches!(
            parsed.info.kind,
            ExpressionKind::Identifier | ExpressionKind::Literal | ExpressionKind::MemberExpression
        )
}

/// Extract the root identifier from an expression if it's a simple chain.
///
/// Examples:
/// - `count` -> Some("count")
/// - `user.name` -> Some("user")
/// - `items[0].name` -> Some("items")
/// - `fn()` -> None
pub fn extract_root_identifier(expr: &str) -> Option<SmolStr> {
    let parsed = parse_expression(expr);

    if !parsed.is_valid {
        return None;
    }

    // Find the first identifier that's not a store subscription
    for var in &parsed.info.variables {
        let name = var.name.as_str();
        if !name.starts_with('$') {
            return Some(var.name.clone());
        }
    }

    // If only store subscriptions, return the first one without $
    if let Some(store) = parsed.info.store_subscriptions.iter().next() {
        return Some(store.clone());
    }

    None
}

/// Analyze an event handler expression.
///
/// Event handlers can be:
/// - Identifier references: `handleClick`
/// - Arrow functions: `() => count++`
/// - Method calls: `handler.bind(this)`
#[derive(Debug)]
pub struct EventHandlerAnalysis {
    /// Whether the handler is a simple identifier reference.
    pub is_identifier: bool,
    /// Whether the handler is an arrow/function expression.
    pub is_function: bool,
    /// The handler name if it's an identifier.
    pub handler_name: Option<SmolStr>,
    /// Whether the expression is valid.
    pub is_valid: bool,
}

/// Analyze an event handler expression.
pub fn analyze_event_handler(expr: &str) -> EventHandlerAnalysis {
    let parsed = parse_expression(expr);

    let is_identifier = parsed.info.kind == ExpressionKind::Identifier;
    let is_function = parsed.info.kind == ExpressionKind::ArrowFunction;

    let handler_name = if is_identifier {
        parsed.info.variables.first().map(|v| v.name.clone())
    } else {
        None
    };

    EventHandlerAnalysis {
        is_identifier,
        is_function,
        handler_name,
        is_valid: parsed.is_valid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_analyze_simple_identifier() {
        let result = analyze_template_expression("count");
        assert!(result.is_valid);
        assert!(result.is_simple);
        assert_eq!(result.kind, ExpressionKind::Identifier);
    }

    #[test]
    fn test_analyze_store_subscription() {
        let result = analyze_template_expression("$myStore.value");
        assert!(result.is_valid);
        assert!(result.store_subscriptions.contains("myStore"));
    }

    #[test]
    fn test_analyze_function_call() {
        let result = analyze_template_expression("getData()");
        assert!(result.is_valid);
        assert!(!result.is_simple);
        assert!(result.has_function_calls);
    }

    #[test]
    fn test_collect_stores() {
        let exprs = ["$store1.value", "$store2", "regularVar"];
        let stores = collect_store_subscriptions(exprs.iter().copied());
        assert!(stores.contains("store1"));
        assert!(stores.contains("store2"));
        assert!(!stores.contains("regularVar"));
    }

    #[test]
    fn test_is_simple_expression() {
        assert!(is_simple_expression("count"));
        assert!(is_simple_expression("user.name"));
        assert!(is_simple_expression("42"));
        assert!(!is_simple_expression("getData()"));
        assert!(!is_simple_expression("a + b"));
    }

    #[test]
    fn test_extract_root_identifier() {
        assert_eq!(
            extract_root_identifier("count"),
            Some(SmolStr::new("count"))
        );
        assert_eq!(
            extract_root_identifier("user.name"),
            Some(SmolStr::new("user"))
        );
        assert_eq!(
            extract_root_identifier("$store.value"),
            Some(SmolStr::new("store"))
        );
    }

    #[test]
    fn test_analyze_event_handler() {
        let handler = analyze_event_handler("handleClick");
        assert!(handler.is_identifier);
        assert_eq!(handler.handler_name, Some(SmolStr::new("handleClick")));

        let arrow = analyze_event_handler("() => count++");
        assert!(arrow.is_function);
        assert!(arrow.handler_name.is_none());
    }
}
