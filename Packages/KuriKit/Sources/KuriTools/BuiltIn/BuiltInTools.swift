/// The tools Kuri provides itself, as opposed to tools from MCP servers.
public enum BuiltInTools {
    public static var all: [any Tool] {
        [ClarifyTool(), TaskListTool(), MemoryTool(), ConversationSearchTool()]
    }
}
