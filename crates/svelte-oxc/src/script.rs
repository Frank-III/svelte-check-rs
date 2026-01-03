//! Script analysis and validation using OXC.
//!
//! This module provides high-level utilities for analyzing Svelte script blocks,
//! including validation, import extraction, and export detection.

use oxc_allocator::Allocator;
use oxc_ast::ast::{Declaration, ModuleDeclaration, Statement};
use oxc_ast::Visit;
use oxc_parser::Parser;
use oxc_span::SourceType;
use smol_str::SmolStr;
use std::collections::HashSet;

use crate::validate::{ValidationError, ValidationResult};

/// Information extracted from a script block.
#[derive(Debug, Default)]
pub struct ScriptInfo {
    /// Imports found in the script.
    pub imports: Vec<ImportInfo>,
    /// Exports found in the script.
    pub exports: Vec<ExportInfo>,
    /// Top-level variable declarations.
    pub variables: Vec<VariableInfo>,
    /// Function declarations.
    pub functions: Vec<FunctionInfo>,
    /// Type/interface declarations (TypeScript).
    pub type_declarations: Vec<TypeInfo>,
    /// Whether the script contains rune calls.
    pub has_runes: bool,
    /// Rune names used in the script.
    pub rune_names: HashSet<SmolStr>,
    /// Validation result.
    pub validation: ValidationResult,
}

/// Information about an import statement.
#[derive(Debug, Clone)]
pub struct ImportInfo {
    /// The module specifier.
    pub source: SmolStr,
    /// Named imports.
    pub named: Vec<SmolStr>,
    /// Default import name.
    pub default: Option<SmolStr>,
    /// Namespace import name.
    pub namespace: Option<SmolStr>,
    /// Whether this is a type-only import.
    pub is_type_only: bool,
}

/// Information about an export.
#[derive(Debug, Clone)]
pub struct ExportInfo {
    /// The exported name.
    pub name: SmolStr,
    /// The local name (if different).
    pub local_name: Option<SmolStr>,
    /// Whether this is a type-only export.
    pub is_type_only: bool,
    /// Whether this is a default export.
    pub is_default: bool,
}

/// Information about a variable declaration.
#[derive(Debug, Clone)]
pub struct VariableInfo {
    /// The variable name.
    pub name: SmolStr,
    /// The kind (let, const, var).
    pub kind: VariableKind,
    /// Whether initialized with a rune.
    pub is_rune: bool,
    /// The rune name if applicable.
    pub rune_name: Option<SmolStr>,
    /// Start offset.
    pub start: u32,
    /// End offset.
    pub end: u32,
}

/// Variable declaration kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VariableKind {
    Let,
    Const,
    Var,
}

/// Information about a function declaration.
#[derive(Debug, Clone)]
pub struct FunctionInfo {
    /// The function name.
    pub name: SmolStr,
    /// Whether it's async.
    pub is_async: bool,
    /// Whether it's a generator.
    pub is_generator: bool,
    /// Start offset.
    pub start: u32,
    /// End offset.
    pub end: u32,
}

/// Information about a type declaration.
#[derive(Debug, Clone)]
pub struct TypeInfo {
    /// The type name.
    pub name: SmolStr,
    /// Whether it's an interface.
    pub is_interface: bool,
    /// Start offset.
    pub start: u32,
    /// End offset.
    pub end: u32,
}

/// Analyze a script block and extract information.
pub fn analyze_script(source: &str, is_typescript: bool) -> ScriptInfo {
    let allocator = Allocator::default();

    let source_type = if is_typescript {
        SourceType::tsx()
    } else {
        SourceType::mjs()
    };

    let parser_return = Parser::new(&allocator, source, source_type).parse();

    let validation_errors: Vec<ValidationError> = parser_return
        .errors
        .iter()
        .cloned()
        .map(Into::into)
        .collect();

    let validation = ValidationResult {
        is_valid: validation_errors.is_empty(),
        errors: validation_errors,
        is_typescript,
    };

    if !validation.is_valid {
        return ScriptInfo {
            validation,
            ..Default::default()
        };
    }

    let mut analyzer = ScriptAnalyzer::new();
    analyzer.visit_program(&parser_return.program);

    ScriptInfo {
        imports: analyzer.imports,
        exports: analyzer.exports,
        variables: analyzer.variables,
        functions: analyzer.functions,
        type_declarations: analyzer.type_declarations,
        has_runes: !analyzer.rune_names.is_empty(),
        rune_names: analyzer.rune_names,
        validation,
    }
}

/// Quick check if a script is valid without full analysis.
pub fn is_script_valid(source: &str, is_typescript: bool) -> bool {
    let allocator = Allocator::default();

    let source_type = if is_typescript {
        SourceType::tsx()
    } else {
        SourceType::mjs()
    };

    let parser_return = Parser::new(&allocator, source, source_type).parse();
    parser_return.errors.is_empty()
}

/// Extract just the imports from a script.
pub fn extract_imports(source: &str) -> Vec<ImportInfo> {
    analyze_script(source, true).imports
}

/// Extract just the exports from a script.
pub fn extract_exports(source: &str) -> Vec<ExportInfo> {
    analyze_script(source, true).exports
}

/// Analyzer for extracting information from scripts.
struct ScriptAnalyzer {
    imports: Vec<ImportInfo>,
    exports: Vec<ExportInfo>,
    variables: Vec<VariableInfo>,
    functions: Vec<FunctionInfo>,
    type_declarations: Vec<TypeInfo>,
    rune_names: HashSet<SmolStr>,
}

impl ScriptAnalyzer {
    fn new() -> Self {
        Self {
            imports: Vec::new(),
            exports: Vec::new(),
            variables: Vec::new(),
            functions: Vec::new(),
            type_declarations: Vec::new(),
            rune_names: HashSet::new(),
        }
    }
}

impl<'a> Visit<'a> for ScriptAnalyzer {
    fn visit_statement(&mut self, stmt: &Statement<'a>) {
        match stmt {
            Statement::VariableDeclaration(decl) => {
                let kind = match decl.kind {
                    oxc_ast::ast::VariableDeclarationKind::Var => VariableKind::Var,
                    oxc_ast::ast::VariableDeclarationKind::Let => VariableKind::Let,
                    oxc_ast::ast::VariableDeclarationKind::Const => VariableKind::Const,
                    oxc_ast::ast::VariableDeclarationKind::Using
                    | oxc_ast::ast::VariableDeclarationKind::AwaitUsing => VariableKind::Const,
                };

                for declarator in &decl.declarations {
                    if let oxc_ast::ast::BindingPatternKind::BindingIdentifier(id) =
                        &declarator.id.kind
                    {
                        let (is_rune, rune_name) = check_rune_init(&declarator.init);

                        if let Some(ref rune) = rune_name {
                            self.rune_names.insert(rune.clone());
                        }

                        self.variables.push(VariableInfo {
                            name: SmolStr::new(id.name.as_str()),
                            kind,
                            is_rune,
                            rune_name,
                            start: declarator.span.start,
                            end: declarator.span.end,
                        });
                    }
                }
            }
            Statement::FunctionDeclaration(func) => {
                if let Some(id) = &func.id {
                    self.functions.push(FunctionInfo {
                        name: SmolStr::new(id.name.as_str()),
                        is_async: func.r#async,
                        is_generator: func.generator,
                        start: func.span.start,
                        end: func.span.end,
                    });
                }
            }
            Statement::TSTypeAliasDeclaration(alias) => {
                self.type_declarations.push(TypeInfo {
                    name: SmolStr::new(alias.id.name.as_str()),
                    is_interface: false,
                    start: alias.span.start,
                    end: alias.span.end,
                });
            }
            Statement::TSInterfaceDeclaration(iface) => {
                self.type_declarations.push(TypeInfo {
                    name: SmolStr::new(iface.id.name.as_str()),
                    is_interface: true,
                    start: iface.span.start,
                    end: iface.span.end,
                });
            }
            _ => {}
        }

        oxc_ast::visit::walk::walk_statement(self, stmt);
    }

    fn visit_module_declaration(&mut self, decl: &ModuleDeclaration<'a>) {
        match decl {
            ModuleDeclaration::ImportDeclaration(import) => {
                let source = SmolStr::new(import.source.value.as_str());
                let is_type_only = import.import_kind.is_type();

                let mut named = Vec::new();
                let mut default = None;
                let mut namespace = None;

                if let Some(specifiers) = &import.specifiers {
                    for spec in specifiers {
                        match spec {
                            oxc_ast::ast::ImportDeclarationSpecifier::ImportSpecifier(s) => {
                                named.push(SmolStr::new(s.local.name.as_str()));
                            }
                            oxc_ast::ast::ImportDeclarationSpecifier::ImportDefaultSpecifier(s) => {
                                default = Some(SmolStr::new(s.local.name.as_str()));
                            }
                            oxc_ast::ast::ImportDeclarationSpecifier::ImportNamespaceSpecifier(
                                s,
                            ) => {
                                namespace = Some(SmolStr::new(s.local.name.as_str()));
                            }
                        }
                    }
                }

                self.imports.push(ImportInfo {
                    source,
                    named,
                    default,
                    namespace,
                    is_type_only,
                });
            }
            ModuleDeclaration::ExportNamedDeclaration(export) => {
                let is_type_only = export.export_kind.is_type();

                // Handle re-exports with specifiers
                for spec in &export.specifiers {
                    let name = match &spec.exported {
                        oxc_ast::ast::ModuleExportName::IdentifierName(id) => {
                            SmolStr::new(id.name.as_str())
                        }
                        oxc_ast::ast::ModuleExportName::IdentifierReference(id) => {
                            SmolStr::new(id.name.as_str())
                        }
                        oxc_ast::ast::ModuleExportName::StringLiteral(s) => {
                            SmolStr::new(s.value.as_str())
                        }
                    };

                    let local_name = match &spec.local {
                        oxc_ast::ast::ModuleExportName::IdentifierName(id) => {
                            Some(SmolStr::new(id.name.as_str()))
                        }
                        oxc_ast::ast::ModuleExportName::IdentifierReference(id) => {
                            Some(SmolStr::new(id.name.as_str()))
                        }
                        oxc_ast::ast::ModuleExportName::StringLiteral(s) => {
                            Some(SmolStr::new(s.value.as_str()))
                        }
                    };

                    self.exports.push(ExportInfo {
                        name,
                        local_name,
                        is_type_only,
                        is_default: false,
                    });
                }

                // Handle declaration exports
                if let Some(decl) = &export.declaration {
                    match decl {
                        Declaration::VariableDeclaration(var_decl) => {
                            for declarator in &var_decl.declarations {
                                if let oxc_ast::ast::BindingPatternKind::BindingIdentifier(id) =
                                    &declarator.id.kind
                                {
                                    self.exports.push(ExportInfo {
                                        name: SmolStr::new(id.name.as_str()),
                                        local_name: None,
                                        is_type_only,
                                        is_default: false,
                                    });
                                }
                            }
                        }
                        Declaration::FunctionDeclaration(func) => {
                            if let Some(id) = &func.id {
                                self.exports.push(ExportInfo {
                                    name: SmolStr::new(id.name.as_str()),
                                    local_name: None,
                                    is_type_only,
                                    is_default: false,
                                });
                            }
                        }
                        Declaration::ClassDeclaration(class) => {
                            if let Some(id) = &class.id {
                                self.exports.push(ExportInfo {
                                    name: SmolStr::new(id.name.as_str()),
                                    local_name: None,
                                    is_type_only,
                                    is_default: false,
                                });
                            }
                        }
                        Declaration::TSTypeAliasDeclaration(alias) => {
                            self.exports.push(ExportInfo {
                                name: SmolStr::new(alias.id.name.as_str()),
                                local_name: None,
                                is_type_only: true,
                                is_default: false,
                            });
                        }
                        Declaration::TSInterfaceDeclaration(iface) => {
                            self.exports.push(ExportInfo {
                                name: SmolStr::new(iface.id.name.as_str()),
                                local_name: None,
                                is_type_only: true,
                                is_default: false,
                            });
                        }
                        _ => {}
                    }
                }
            }
            ModuleDeclaration::ExportDefaultDeclaration(_) => {
                self.exports.push(ExportInfo {
                    name: SmolStr::new("default"),
                    local_name: None,
                    is_type_only: false,
                    is_default: true,
                });
            }
            _ => {}
        }

        oxc_ast::visit::walk::walk_module_declaration(self, decl);
    }
}

/// Check if an initializer is a rune call.
fn check_rune_init(init: &Option<oxc_ast::ast::Expression>) -> (bool, Option<SmolStr>) {
    if let Some(oxc_ast::ast::Expression::CallExpression(call)) = init {
        if let oxc_ast::ast::Expression::Identifier(id) = &call.callee {
            let name = id.name.as_str();
            if is_rune_name(name) {
                return (true, Some(SmolStr::new(name)));
            }
        }
        // Check for $state.raw, $derived.by, etc.
        if let oxc_ast::ast::Expression::StaticMemberExpression(member) = &call.callee {
            if let oxc_ast::ast::Expression::Identifier(obj) = &member.object {
                let full_name = format!("{}.{}", obj.name, member.property.name);
                if is_rune_method(&full_name) {
                    return (true, Some(SmolStr::new(full_name)));
                }
            }
        }
    }
    (false, None)
}

fn is_rune_name(name: &str) -> bool {
    matches!(
        name,
        "$state" | "$derived" | "$effect" | "$props" | "$bindable" | "$inspect" | "$host"
    )
}

fn is_rune_method(name: &str) -> bool {
    matches!(
        name,
        "$state.raw"
            | "$state.snapshot"
            | "$derived.by"
            | "$effect.pre"
            | "$effect.root"
            | "$effect.tracking"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_analyze_simple_script() {
        let info = analyze_script("let x = 1;", false);
        assert!(info.validation.is_valid);
        assert_eq!(info.variables.len(), 1);
        assert_eq!(info.variables[0].name.as_str(), "x");
    }

    #[test]
    fn test_analyze_imports() {
        let info = analyze_script("import { foo, bar } from 'module';", false);
        assert!(info.validation.is_valid);
        assert_eq!(info.imports.len(), 1);
        assert_eq!(info.imports[0].source.as_str(), "module");
        assert_eq!(info.imports[0].named.len(), 2);
    }

    #[test]
    fn test_analyze_exports() {
        let info = analyze_script("export const x = 1;", false);
        assert!(info.validation.is_valid);
        assert_eq!(info.exports.len(), 1);
        assert_eq!(info.exports[0].name.as_str(), "x");
    }

    #[test]
    fn test_analyze_runes() {
        let info = analyze_script("let count = $state(0);", false);
        assert!(info.validation.is_valid);
        assert!(info.has_runes);
        assert!(info.rune_names.contains("$state"));
        assert!(info.variables[0].is_rune);
    }

    #[test]
    fn test_analyze_typescript() {
        let info = analyze_script("interface Foo { x: number; }", true);
        assert!(info.validation.is_valid);
        assert_eq!(info.type_declarations.len(), 1);
        assert_eq!(info.type_declarations[0].name.as_str(), "Foo");
        assert!(info.type_declarations[0].is_interface);
    }

    #[test]
    fn test_analyze_invalid_script() {
        let info = analyze_script("let x = ;", false);
        assert!(!info.validation.is_valid);
    }

    #[test]
    fn test_is_script_valid() {
        assert!(is_script_valid("let x = 1;", false));
        assert!(!is_script_valid("let x = ;", false));
    }
}
