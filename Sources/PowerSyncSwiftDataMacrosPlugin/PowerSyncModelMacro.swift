import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@PowerSyncModel` into a `PredicateCodableKeyPathProviding` extension whose
/// dictionary maps every stored property name to its key path.
public struct PowerSyncModelMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let typeName = type.trimmedDescription

        var entries: [String] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            if variable.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }) {
                continue
            }
            // SwiftData's @Transient properties are not persisted.
            if variable.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Transient"
            }) {
                continue
            }
            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                if let accessorBlock = binding.accessorBlock {
                    switch accessorBlock.accessors {
                    case .getter:
                        continue // computed
                    case let .accessors(list):
                        let isStored = list.allSatisfy {
                            $0.accessorSpecifier.tokenKind == .keyword(.willSet)
                                || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
                        }
                        if !isStored {
                            continue
                        }
                    }
                }
                let name = pattern.identifier.text
                entries.append("\"\(name)\": \\\(typeName).\(name)")
            }
        }

        // Replicate the model's availability on the generated extension.
        let availability = declaration.attributes
            .compactMap { $0.as(AttributeSyntax.self) }
            .filter { $0.attributeName.trimmedDescription == "available" }
            .map(\.trimmedDescription)
        let availabilityPrefix = availability.isEmpty ? "" : availability.joined(separator: "\n") + "\n"

        let dictionary = entries.isEmpty ? "[:]" : "[\(entries.joined(separator: ", "))]"
        let extensionDecl: DeclSyntax = """
        \(raw: availabilityPrefix)extension \(raw: typeName): PredicateCodableKeyPathProviding {
            public static var predicateCodableKeyPaths: [String: any PartialKeyPath<\(raw: typeName)> & Sendable] {
                \(raw: dictionary)
            }
        }
        """
        guard let result = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [result]
    }
}

@main
struct PowerSyncSwiftDataMacrosPluginMain: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PowerSyncModelMacro.self]
}
