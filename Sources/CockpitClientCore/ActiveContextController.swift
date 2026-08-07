import CockpitTypes

public actor ActiveContextController {
    private var activeContext: ActiveContext?
    private var generation: UInt64 = 0

    public init() {}

    public func select(_ context: ResolvedWorkspaceContext) -> ActiveContext {
        precondition(generation < UInt64.max, "Active context generation exhausted")
        generation += 1
        let selected = try! ActiveContext(
            validating: context.contextID,
            projectID: context.projectID,
            conversationID: context.conversationID,
            environmentID: context.environmentID,
            workspaceRootIdentity: context.workspaceRootIdentity,
            generation: generation
        )
        activeContext = selected
        return selected
    }

    public func accepts(generation: UInt64) -> Bool {
        activeContext?.generation == generation
    }

    public func current() -> ActiveContext? {
        activeContext
    }
}
