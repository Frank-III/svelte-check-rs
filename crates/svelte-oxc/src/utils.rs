//! Common utilities for OXC-based transformations.

use oxc_ast::ast::{CallExpression, Expression};

/// Check if an expression is a function call to a specific name.
pub fn is_call_to(expr: &Expression, name: &str) -> bool {
    if let Expression::CallExpression(call) = expr {
        if let Expression::Identifier(id) = &call.callee {
            return id.name == name;
        }
    }
    false
}

/// Check if an expression is a method call (e.g., `obj.method()`).
pub fn is_method_call(expr: &Expression, object_name: &str, method_name: &str) -> bool {
    if let Expression::CallExpression(call) = expr {
        if let Expression::StaticMemberExpression(member) = &call.callee {
            if member.property.name == method_name {
                if let Expression::Identifier(id) = &member.object {
                    return id.name == object_name;
                }
            }
        }
    }
    false
}

/// Get the name of a function call's callee, if it's a simple identifier.
pub fn get_callee_name<'a>(call: &'a CallExpression) -> Option<&'a str> {
    match &call.callee {
        Expression::Identifier(id) => Some(&id.name),
        _ => None,
    }
}

/// Get the full callee name including member access (e.g., "obj.method").
pub fn get_full_callee_name(call: &CallExpression) -> Option<String> {
    match &call.callee {
        Expression::Identifier(id) => Some(id.name.to_string()),
        Expression::StaticMemberExpression(member) => {
            if let Expression::Identifier(obj) = &member.object {
                Some(format!("{}.{}", obj.name, member.property.name))
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Check if an expression is dynamic (needs reactive wrapper).
///
/// An expression is considered dynamic if it:
/// - Contains function calls
/// - Contains member access on reactive objects
/// - Is not a simple literal or identifier
pub fn is_dynamic_expression(expr: &Expression) -> bool {
    match expr {
        // Literals are static
        Expression::BooleanLiteral(_)
        | Expression::NullLiteral(_)
        | Expression::NumericLiteral(_)
        | Expression::StringLiteral(_)
        | Expression::BigIntLiteral(_)
        | Expression::RegExpLiteral(_)
        | Expression::TemplateLiteral(_) => false,

        // Identifiers might be reactive
        Expression::Identifier(_) => true,

        // Function calls are dynamic
        Expression::CallExpression(_) => true,

        // Member access is dynamic (could be accessing reactive property)
        Expression::StaticMemberExpression(_) | Expression::ComputedMemberExpression(_) => true,

        // Binary/unary expressions depend on their operands
        Expression::BinaryExpression(bin) => {
            is_dynamic_expression(&bin.left) || is_dynamic_expression(&bin.right)
        }
        Expression::UnaryExpression(unary) => is_dynamic_expression(&unary.argument),
        Expression::LogicalExpression(logical) => {
            is_dynamic_expression(&logical.left) || is_dynamic_expression(&logical.right)
        }

        // Conditional expressions depend on all parts
        Expression::ConditionalExpression(cond) => {
            is_dynamic_expression(&cond.test)
                || is_dynamic_expression(&cond.consequent)
                || is_dynamic_expression(&cond.alternate)
        }

        // Arrays and objects depend on their contents
        Expression::ArrayExpression(arr) => arr.elements.iter().any(|elem| {
            elem.as_expression()
                .is_some_and(|e| is_dynamic_expression(e))
        }),
        Expression::ObjectExpression(obj) => obj.properties.iter().any(|prop| {
            if let oxc_ast::ast::ObjectPropertyKind::ObjectProperty(p) = prop {
                is_dynamic_expression(&p.value)
            } else {
                true // Spread is dynamic
            }
        }),

        // Arrow functions and regular functions are static (they're values)
        Expression::ArrowFunctionExpression(_) | Expression::FunctionExpression(_) => false,

        // Everything else is considered dynamic
        _ => true,
    }
}

/// Check if an identifier starts with a capital letter (component convention).
pub fn is_component_name(name: &str) -> bool {
    name.chars()
        .next()
        .map(|c| c.is_uppercase())
        .unwrap_or(false)
}

/// Escape HTML special characters in a string.
pub fn escape_html(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            '"' => result.push_str("&quot;"),
            '\'' => result.push_str("&#39;"),
            _ => result.push(c),
        }
    }
    result
}

/// Trim whitespace from template text according to Svelte rules.
pub fn trim_whitespace(s: &str) -> String {
    // Collapse multiple whitespace to single space
    let mut result = String::new();
    let mut prev_whitespace = false;

    for c in s.chars() {
        if c.is_whitespace() {
            if !prev_whitespace {
                result.push(' ');
                prev_whitespace = true;
            }
        } else {
            result.push(c);
            prev_whitespace = false;
        }
    }

    result.trim().to_string()
}

/// Convert a camelCase event name to lowercase (e.g., "onClick" → "click").
pub fn to_event_name(name: &str) -> Option<String> {
    if name.starts_with("on") && name.len() > 2 {
        let event = &name[2..];
        // First char lowercase, rest as-is
        let mut result = String::new();
        for (i, c) in event.chars().enumerate() {
            if i == 0 {
                result.extend(c.to_lowercase());
            } else {
                result.push(c);
            }
        }
        Some(result)
    } else {
        None
    }
}

/// Check if a string is a valid JavaScript identifier.
pub fn is_valid_identifier(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }

    let mut chars = s.chars();

    // First character must be letter, underscore, or dollar sign
    let first = chars.next().unwrap();
    if !first.is_alphabetic() && first != '_' && first != '$' {
        return false;
    }

    // Rest can include digits
    chars.all(|c| c.is_alphanumeric() || c == '_' || c == '$')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_component_name() {
        assert!(is_component_name("Button"));
        assert!(is_component_name("MyComponent"));
        assert!(!is_component_name("button"));
        assert!(!is_component_name("myComponent"));
    }

    #[test]
    fn test_escape_html() {
        assert_eq!(escape_html("<div>"), "&lt;div&gt;");
        assert_eq!(escape_html("a & b"), "a &amp; b");
        assert_eq!(escape_html("\"hello\""), "&quot;hello&quot;");
    }

    #[test]
    fn test_trim_whitespace() {
        assert_eq!(trim_whitespace("  hello  world  "), "hello world");
        assert_eq!(trim_whitespace("\n\t  text  \n"), "text");
    }

    #[test]
    fn test_to_event_name() {
        assert_eq!(to_event_name("onClick"), Some("click".to_string()));
        assert_eq!(
            to_event_name("onMouseEnter"),
            Some("mouseEnter".to_string())
        );
        assert_eq!(to_event_name("on"), None);
        assert_eq!(to_event_name("click"), None);
    }

    #[test]
    fn test_is_valid_identifier() {
        assert!(is_valid_identifier("foo"));
        assert!(is_valid_identifier("_bar"));
        assert!(is_valid_identifier("$baz"));
        assert!(is_valid_identifier("foo123"));
        assert!(!is_valid_identifier("123foo"));
        assert!(!is_valid_identifier("foo-bar"));
        assert!(!is_valid_identifier(""));
    }
}
