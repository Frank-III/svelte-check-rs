//! Svelte rune transformation using OXC.
//!
//! This module transforms Svelte 5 runes to TypeScript equivalents:
//!
//! - `$state(value)` → `let x = value`
//! - `$derived(expr)` → `let x: typeof expr`
//! - `$props()` → Props type extraction
//! - `$effect()` → `__svelte_effect()`
//! - `$store` → `__svelte_store_get(store)`

use std::collections::HashSet;

use oxc_allocator::Allocator;
use oxc_ast::ast::{BindingPatternKind, Expression, VariableDeclarator};
use oxc_ast::Visit;
use oxc_parser::Parser;
use oxc_span::SourceType;

use smol_str::SmolStr;
use source_map::Span as SourceSpan;

/// Options for rune transformation.
#[derive(Debug, Clone, Default)]
pub struct RuneTransformOptions {
    /// Base offset for source mapping (offset of script content in original file).
    pub base_offset: u32,
    /// Default props type for SvelteKit routes.
    pub default_props_type: Option<String>,
    /// Whether to preserve the original span information.
    pub preserve_spans: bool,
}

/// Result of rune transformation.
#[derive(Debug, Default)]
pub struct RuneTransformResult {
    /// The transformed code.
    pub output: String,
    /// Store names that were subscribed to ($store syntax).
    pub store_names: HashSet<SmolStr>,
    /// Whether $props accessor was used ($props.name()).
    pub uses_props_accessor: bool,
    /// Extracted props information.
    pub props_info: Option<PropsInfo>,
    /// Source mappings for transformed expressions.
    pub mappings: Vec<RuneMapping>,
}

/// Information about $props() usage.
#[derive(Debug, Clone, Default)]
pub struct PropsInfo {
    /// The destructured property names.
    pub properties: Vec<PropProperty>,
    /// The type annotation on $props(), if any.
    pub type_annotation: Option<String>,
    /// The full pattern text.
    pub pattern: String,
}

/// A property extracted from $props().
#[derive(Debug, Clone)]
pub struct PropProperty {
    /// The property name.
    pub name: SmolStr,
    /// The default value, if any.
    pub default_value: Option<String>,
    /// Whether this is a rest property (...rest).
    pub is_rest: bool,
    /// Whether this is bindable.
    pub bindable: bool,
}

/// A source mapping for a transformed rune.
#[derive(Debug, Clone)]
pub struct RuneMapping {
    /// Original span in the source.
    pub original_span: SourceSpan,
    /// Start offset in generated code.
    pub generated_start: usize,
    /// End offset in generated code.
    pub generated_end: usize,
}

/// Transform Svelte runes in the given source code.
///
/// This uses a simple string-based approach for now, with OXC parsing
/// for validation and analysis.
pub fn transform_runes(source: &str, _options: RuneTransformOptions) -> RuneTransformResult {
    let allocator = Allocator::default();

    // Parse the source as TypeScript to analyze runes
    let source_type = SourceType::tsx();
    let parser_return = Parser::new(&allocator, source, source_type).parse();

    if !parser_return.errors.is_empty() {
        // If parsing fails, return the original source
        return RuneTransformResult {
            output: source.to_string(),
            ..Default::default()
        };
    }

    // Analyze the AST to find runes and stores
    let mut analyzer = RuneAnalyzer::new();
    analyzer.visit_program(&parser_return.program);

    // Transform using string replacement (simpler and more reliable for now)
    let mut output = source.to_string();

    // Transform $effect(() => ...) → __svelte_effect(() => ...)
    output = transform_effect_calls(&output);

    // Transform $effect.pre(() => ...) → __svelte_effect_pre(() => ...)
    output = transform_effect_pre_calls(&output);

    // Transform $state(value) → value
    output = transform_state_calls(&output);

    // Transform $derived(expr) → expr
    output = transform_derived_calls(&output);

    // Transform $derived.by(fn) → fn()
    output = transform_derived_by_calls(&output);

    // Transform $bindable(value) → value
    output = transform_bindable_calls(&output);

    // Transform $store → __svelte_store_get(store)
    output = transform_store_subscriptions(&output, &analyzer.store_names);

    RuneTransformResult {
        output,
        store_names: analyzer.store_names,
        uses_props_accessor: analyzer.uses_props_accessor,
        props_info: analyzer.props_info,
        mappings: Vec::new(),
    }
}

/// Visitor to analyze runes in the AST.
struct RuneAnalyzer {
    store_names: HashSet<SmolStr>,
    uses_props_accessor: bool,
    props_info: Option<PropsInfo>,
}

impl RuneAnalyzer {
    fn new() -> Self {
        Self {
            store_names: HashSet::new(),
            uses_props_accessor: false,
            props_info: None,
        }
    }
}

impl<'a> Visit<'a> for RuneAnalyzer {
    fn visit_identifier_reference(&mut self, ident: &oxc_ast::ast::IdentifierReference<'a>) {
        let name = ident.name.as_str();
        // Check for store subscription ($storeName but not $state, $derived, etc.)
        if name.starts_with('$') && !name.starts_with("$$") && name.len() > 1 && !is_rune_name(name)
        {
            self.store_names.insert(SmolStr::new(&name[1..]));
        }
    }

    fn visit_member_expression(&mut self, expr: &oxc_ast::ast::MemberExpression<'a>) {
        // Check for $props.name() accessor pattern
        if let oxc_ast::ast::MemberExpression::StaticMemberExpression(static_member) = expr {
            if let Expression::Identifier(obj) = &static_member.object {
                if obj.name == "$props" {
                    self.uses_props_accessor = true;
                }
            }
        }

        // Continue visiting
        oxc_ast::visit::walk::walk_member_expression(self, expr);
    }

    fn visit_variable_declarator(&mut self, declarator: &VariableDeclarator<'a>) {
        // Check for $props() destructuring
        if let Some(Expression::CallExpression(call)) = &declarator.init {
            if let Expression::Identifier(callee) = &call.callee {
                if callee.name == "$props" {
                    self.extract_props_info(declarator);
                }
            }
        }

        // Continue visiting
        oxc_ast::visit::walk::walk_variable_declarator(self, declarator);
    }
}

impl RuneAnalyzer {
    fn extract_props_info(&mut self, declarator: &VariableDeclarator) {
        let mut props_info = PropsInfo::default();

        if let BindingPatternKind::ObjectPattern(pattern) = &declarator.id.kind {
            for prop in &pattern.properties {
                if let Some(key) = prop.key.static_name() {
                    props_info.properties.push(PropProperty {
                        name: SmolStr::new(key),
                        default_value: None, // TODO: extract default
                        is_rest: false,
                        bindable: false,
                    });
                }
            }

            if let Some(rest) = &pattern.rest {
                if let BindingPatternKind::BindingIdentifier(id) = &rest.argument.kind {
                    props_info.properties.push(PropProperty {
                        name: SmolStr::new(id.name.as_str()),
                        default_value: None,
                        is_rest: true,
                        bindable: false,
                    });
                }
            }
        }

        self.props_info = Some(props_info);
    }
}

/// Check if a name is a Svelte rune.
fn is_rune_name(name: &str) -> bool {
    matches!(
        name,
        "$state" | "$derived" | "$effect" | "$props" | "$bindable" | "$inspect" | "$host" | "$"
    )
}

/// Transform $effect(() => ...) calls.
fn transform_effect_calls(source: &str) -> String {
    // Simple regex-free replacement
    source.replace("$effect(", "__svelte_effect(")
}

/// Transform $effect.pre(() => ...) calls.
fn transform_effect_pre_calls(source: &str) -> String {
    source.replace("$effect.pre(", "__svelte_effect_pre(")
}

/// Transform $state(value) → value.
fn transform_state_calls(source: &str) -> String {
    let mut result = String::with_capacity(source.len());
    let mut i = 0;

    while i < source.len() {
        let remaining = &source[i..];

        // Look for $state(
        if remaining.starts_with("$state(") {
            // Find the matching closing paren
            let start = i + 7; // After "$state("
            if let Some((arg, end)) = extract_balanced_parens(&source[start..]) {
                if arg.is_empty() {
                    // $state() → undefined
                    result.push_str("undefined");
                } else {
                    // $state(value) → value
                    result.push_str(arg.trim());
                }
                i = start + end;
                continue;
            }
        }

        result.push(source[i..].chars().next().unwrap());
        i += source[i..]
            .chars()
            .next()
            .map(|c| c.len_utf8())
            .unwrap_or(1);
    }

    result
}

/// Transform $derived(expr) → expr.
fn transform_derived_calls(source: &str) -> String {
    let mut result = String::with_capacity(source.len());
    let mut i = 0;

    while i < source.len() {
        let remaining = &source[i..];

        // Look for $derived( but not $derived.by(
        if remaining.starts_with("$derived(") && !remaining.starts_with("$derived.by(") {
            let start = i + 9; // After "$derived("
            if let Some((arg, end)) = extract_balanced_parens(&source[start..]) {
                result.push_str(arg.trim());
                i = start + end;
                continue;
            }
        }

        result.push(source[i..].chars().next().unwrap());
        i += source[i..]
            .chars()
            .next()
            .map(|c| c.len_utf8())
            .unwrap_or(1);
    }

    result
}

/// Transform $derived.by(fn) → fn().
fn transform_derived_by_calls(source: &str) -> String {
    let mut result = String::with_capacity(source.len());
    let mut i = 0;

    while i < source.len() {
        let remaining = &source[i..];

        if remaining.starts_with("$derived.by(") {
            let start = i + 12; // After "$derived.by("
            if let Some((arg, end)) = extract_balanced_parens(&source[start..]) {
                // $derived.by(fn) → fn()
                result.push_str(arg.trim());
                result.push_str("()");
                i = start + end;
                continue;
            }
        }

        result.push(source[i..].chars().next().unwrap());
        i += source[i..]
            .chars()
            .next()
            .map(|c| c.len_utf8())
            .unwrap_or(1);
    }

    result
}

/// Transform $bindable(value) → value.
fn transform_bindable_calls(source: &str) -> String {
    let mut result = String::with_capacity(source.len());
    let mut i = 0;

    while i < source.len() {
        let remaining = &source[i..];

        if remaining.starts_with("$bindable(") {
            let start = i + 10; // After "$bindable("
            if let Some((arg, end)) = extract_balanced_parens(&source[start..]) {
                if arg.is_empty() {
                    result.push_str("undefined");
                } else {
                    result.push_str(arg.trim());
                }
                i = start + end;
                continue;
            }
        }

        result.push(source[i..].chars().next().unwrap());
        i += source[i..]
            .chars()
            .next()
            .map(|c| c.len_utf8())
            .unwrap_or(1);
    }

    result
}

/// Transform $store → __svelte_store_get(store).
fn transform_store_subscriptions(source: &str, store_names: &HashSet<SmolStr>) -> String {
    if store_names.is_empty() {
        return source.to_string();
    }

    let mut result = String::with_capacity(source.len() * 2);
    let mut i = 0;

    while i < source.len() {
        let remaining = &source[i..];

        // Check if this is a store subscription
        if remaining.starts_with('$') && !remaining.starts_with("$$") {
            // Extract identifier
            let mut j = 1;
            while j < remaining.len() {
                let c = remaining[j..].chars().next().unwrap();
                if c.is_alphanumeric() || c == '_' {
                    j += c.len_utf8();
                } else {
                    break;
                }
            }

            let name = &remaining[1..j];
            if !name.is_empty() && store_names.contains(name) && !is_rune_name(&remaining[..j]) {
                result.push_str("__svelte_store_get(");
                result.push_str(name);
                result.push(')');
                i += j;
                continue;
            }
        }

        result.push(source[i..].chars().next().unwrap());
        i += source[i..]
            .chars()
            .next()
            .map(|c| c.len_utf8())
            .unwrap_or(1);
    }

    result
}

/// Extract content within balanced parentheses.
/// Returns (inner_content, end_index_after_closing_paren).
fn extract_balanced_parens(source: &str) -> Option<(&str, usize)> {
    let mut depth = 1;
    let mut i = 0;
    let mut in_string = None;
    let mut prev_escape = false;

    for c in source.chars() {
        if prev_escape {
            prev_escape = false;
            i += c.len_utf8();
            continue;
        }

        if c == '\\' && in_string.is_some() {
            prev_escape = true;
            i += c.len_utf8();
            continue;
        }

        match in_string {
            Some(delim) if c == delim => {
                in_string = None;
            }
            Some(_) => {}
            None => match c {
                '"' | '\'' | '`' => {
                    in_string = Some(c);
                }
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some((&source[..i], i + 1));
                    }
                }
                _ => {}
            },
        }

        i += c.len_utf8();
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_transform_state() {
        let result = transform_runes("let count = $state(0);", RuneTransformOptions::default());
        assert!(result.output.contains("let count = 0"));
    }

    #[test]
    fn test_transform_state_empty() {
        let result = transform_runes("let value = $state();", RuneTransformOptions::default());
        assert!(result.output.contains("let value = undefined"));
    }

    #[test]
    fn test_transform_derived() {
        let result = transform_runes(
            "let double = $derived(count * 2);",
            RuneTransformOptions::default(),
        );
        assert!(result.output.contains("let double = count * 2"));
    }

    #[test]
    fn test_transform_effect() {
        let result = transform_runes(
            "$effect(() => { console.log(count); });",
            RuneTransformOptions::default(),
        );
        assert!(result.output.contains("__svelte_effect"));
    }

    #[test]
    fn test_transform_store() {
        let result = transform_runes("console.log($myStore);", RuneTransformOptions::default());
        assert!(result.output.contains("__svelte_store_get(myStore)"));
        assert!(result.store_names.contains("myStore"));
    }

    #[test]
    fn test_extract_balanced_parens() {
        assert_eq!(extract_balanced_parens("123)"), Some(("123", 4)));
        assert_eq!(extract_balanced_parens("(a, b))"), Some(("(a, b)", 7)));
        assert_eq!(extract_balanced_parens("')')"), Some(("')'", 4)));
    }
}
