const std = @import("std");
const jinja = @import("vibe_jinja");
const tokenizer_mod = @import("tokenizer.zig");

const Tokenizer = tokenizer_mod.Tokenizer;

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

/// Chat template configuration loaded from tokenizer_config.json.
pub const ChatConfig = struct {
    chat_template: []const u8,
    bos_token: ?[]const u8,
    eos_token: ?[]const u8,
    add_bos_token: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChatConfig) void {
        self.allocator.free(self.chat_template);
        if (self.bos_token) |t| self.allocator.free(t);
        if (self.eos_token) |t| self.allocator.free(t);
    }
};

/// Load chat template configuration from tokenizer_config.json.
pub fn loadChatConfig(allocator: std.mem.Allocator, model_dir: []const u8) !ChatConfig {
    const path = try std.fmt.allocPrint(allocator, "{s}/tokenizer_config.json", .{model_dir});
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const chat_template = if (root.get("chat_template")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const bos_token: ?[]const u8 = if (root.get("bos_token")) |v|
        (if (v == .string) try allocator.dupe(u8, v.string) else null)
    else
        null;

    const eos_token: ?[]const u8 = if (root.get("eos_token")) |v|
        (if (v == .string) try allocator.dupe(u8, v.string) else null)
    else
        null;

    const add_bos_token = if (root.get("add_bos_token")) |v|
        (if (v == .bool) v.bool else false)
    else
        false;

    return .{
        .chat_template = chat_template,
        .bos_token = bos_token,
        .eos_token = eos_token,
        .add_bos_token = add_bos_token,
        .allocator = allocator,
    };
}

/// Format chat messages into token IDs using the model's Jinja chat template.
pub fn formatChat(
    allocator: std.mem.Allocator,
    tok: *const Tokenizer,
    messages: []const Message,
    chat_config: *const ChatConfig,
    tools_json: ?[]const u8,
    tool_choice_instruction: ?[]const u8,
) ![]u32 {
    // Render the chat template using vibe-jinja
    const rendered = try renderChatTemplate(allocator, messages, chat_config, tools_json, tool_choice_instruction);
    defer allocator.free(rendered);

    // Encode the rendered text
    var ids = std.ArrayList(u32).empty;
    errdefer ids.deinit(allocator);

    // Handle BOS token
    if (chat_config.add_bos_token) {
        if (tok.bos_id) |bos| {
            try ids.append(allocator, bos);
        }
    }

    // Split on special tokens and encode each segment
    try encodeWithSpecialTokens(allocator, tok, rendered, &ids);

    return ids.toOwnedSlice(allocator);
}

/// Render the Jinja chat template with the given messages.
fn renderChatTemplate(
    allocator: std.mem.Allocator,
    messages: []const Message,
    chat_config: *const ChatConfig,
    tools_json: ?[]const u8,
    tool_choice_instruction: ?[]const u8,
) ![]const u8 {
    return try fallbackFormatChat(allocator, messages, chat_config, tools_json, tool_choice_instruction);
}

/// Encode text that may contain special tokens (like <|im_start|>, <bos>, etc.).
/// Splits the text on known special tokens, encodes text segments normally,
/// and inserts the special token IDs directly.
fn encodeWithSpecialTokens(
    allocator: std.mem.Allocator,
    tok: *const Tokenizer,
    text: []const u8,
    ids: *std.ArrayList(u32),
) !void {
    // Collect special tokens sorted by length (longest first for greedy matching)
    var specials = std.ArrayList(SpecialEntry).empty;
    defer specials.deinit(allocator);

    var sit = tok.special_tokens.iterator();
    while (sit.next()) |entry| {
        try specials.append(allocator, .{ .text = entry.key_ptr.*, .id = entry.value_ptr.* });
    }

    // Sort by length descending (greedy match)
    std.mem.sort(SpecialEntry, specials.items, {}, struct {
        fn lessThan(_: void, a: SpecialEntry, b: SpecialEntry) bool {
            return a.text.len > b.text.len;
        }
    }.lessThan);

    var pos: usize = 0;
    while (pos < text.len) {
        // Try to match a special token at current position
        var matched = false;
        for (specials.items) |special| {
            if (pos + special.text.len <= text.len and
                std.mem.eql(u8, text[pos .. pos + special.text.len], special.text))
            {
                // Encode any text before this special token
                // (already handled by the loop structure)
                try ids.append(allocator, special.id);
                pos += special.text.len;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        // Find the next special token
        var next_special_pos: usize = text.len;
        for (specials.items) |special| {
            if (std.mem.indexOf(u8, text[pos..], special.text)) |offset| {
                const abs_pos = pos + offset;
                if (abs_pos < next_special_pos) {
                    next_special_pos = abs_pos;
                }
            }
        }

        // Encode the text segment before the next special token
        if (next_special_pos > pos) {
            const segment = text[pos..next_special_pos];
            const segment_ids = try tok.encode(allocator, segment);
            defer allocator.free(segment_ids);
            try ids.appendSlice(allocator, segment_ids);
        }
        pos = next_special_pos;
    }
}

const SpecialEntry = struct {
    text: []const u8,
    id: u32,
};

/// Fallback chat formatting for when Jinja rendering fails.
/// Detects known template patterns and generates the expected format.
fn fallbackFormatChat(
    allocator: std.mem.Allocator,
    messages: []const Message,
    chat_config: *const ChatConfig,
    tools_json: ?[]const u8,
    tool_choice_instruction: ?[]const u8,
) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    // Detect template type from eos_token or template content
    const is_chatml = chat_config.eos_token != null and
        std.mem.indexOf(u8, chat_config.eos_token.?, "<|im_end|>") != null;

    // Check if the first message is a system message
    const has_system = messages.len > 0 and std.mem.eql(u8, messages[0].role, "system");

    if (is_chatml) {
        // ChatML format (Qwen3, etc.)
        // If tools are provided and no system message exists, inject a system message with tool defs
        if (tools_json != null and !has_system) {
            try result.appendSlice(allocator, "<|im_start|>system\n");
            try appendToolSystemPrompt(allocator, &result, tools_json.?, tool_choice_instruction);
            try result.appendSlice(allocator, "<|im_end|>\n");
        }

        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system") and tools_json != null) {
                // Append tools to existing system message
                try result.appendSlice(allocator, "<|im_start|>system\n");
                try result.appendSlice(allocator, msg.content);
                try result.appendSlice(allocator, "\n\n");
                try appendToolSystemPrompt(allocator, &result, tools_json.?, tool_choice_instruction);
                try result.appendSlice(allocator, "<|im_end|>\n");
            } else if (std.mem.eql(u8, msg.role, "assistant") and msg.tool_calls != null) {
                // Assistant message with tool calls
                try result.appendSlice(allocator, "<|im_start|>assistant\n");
                if (msg.content.len > 0) {
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "\n");
                }
                for (msg.tool_calls.?) |tc| {
                    try result.appendSlice(allocator, "<tool_call>\n");
                    try result.appendSlice(allocator, "{\"name\": \"");
                    try result.appendSlice(allocator, tc.name);
                    try result.appendSlice(allocator, "\", \"arguments\": ");
                    try result.appendSlice(allocator, tc.arguments);
                    try result.appendSlice(allocator, "}\n</tool_call>");
                }
                try result.appendSlice(allocator, "<|im_end|>\n");
            } else if (std.mem.eql(u8, msg.role, "tool")) {
                // Tool result message
                try result.appendSlice(allocator, "<|im_start|>user\n");
                try result.appendSlice(allocator, "<tool_response>\n");
                try result.appendSlice(allocator, msg.content);
                try result.appendSlice(allocator, "\n</tool_response>");
                try result.appendSlice(allocator, "<|im_end|>\n");
            } else {
                try result.appendSlice(allocator, "<|im_start|>");
                try result.appendSlice(allocator, msg.role);
                try result.appendSlice(allocator, "\n");
                try result.appendSlice(allocator, msg.content);
                try result.appendSlice(allocator, "<|im_end|>\n");
            }
        }
        try result.appendSlice(allocator, "<|im_start|>assistant\n");
        // Qwen3 thinking models: disable thinking by default (prefill no-think tags)
        if (std.mem.indexOf(u8, chat_config.chat_template, "enable_thinking") != null) {
            try result.appendSlice(allocator, "<think>\n\n</think>\n\n");
        }
    } else {
        // Gemma/Llama-style format
        if (chat_config.bos_token) |bos| {
            try result.appendSlice(allocator, bos);
        }

        // Check if this is Llama-style (uses <|start_header_id|>)
        const is_llama = std.mem.indexOf(u8, chat_config.chat_template, "start_header_id") != null;

        if (is_llama) {
            // Llama 3 format with tool support
            try result.appendSlice(allocator, "<|start_header_id|>system<|end_header_id|>\n\n");
            if (tools_json != null) {
                try result.appendSlice(allocator, "Environment: ipython\n");
            }
            // Add system message content
            if (has_system) {
                try result.appendSlice(allocator, messages[0].content);
            } else {
                try result.appendSlice(allocator, "You are a helpful assistant.");
            }
            if (tools_json != null) {
                try result.appendSlice(allocator, "\n\n");
                try appendToolSystemPrompt(allocator, &result, tools_json.?, tool_choice_instruction);
            }
            try result.appendSlice(allocator, "<|eot_id|>");

            const start_idx: usize = if (has_system) 1 else 0;
            for (messages[start_idx..]) |msg| {
                if (std.mem.eql(u8, msg.role, "assistant") and msg.tool_calls != null) {
                    try result.appendSlice(allocator, "<|start_header_id|>assistant<|end_header_id|>\n\n");
                    for (msg.tool_calls.?) |tc| {
                        try result.appendSlice(allocator, "{\"name\": \"");
                        try result.appendSlice(allocator, tc.name);
                        try result.appendSlice(allocator, "\", \"parameters\": ");
                        try result.appendSlice(allocator, tc.arguments);
                        try result.appendSlice(allocator, "}");
                    }
                    try result.appendSlice(allocator, "<|eot_id|>");
                } else if (std.mem.eql(u8, msg.role, "tool")) {
                    try result.appendSlice(allocator, "<|start_header_id|>ipython<|end_header_id|>\n\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<|eot_id|>");
                } else {
                    try result.appendSlice(allocator, "<|start_header_id|>");
                    try result.appendSlice(allocator, msg.role);
                    try result.appendSlice(allocator, "<|end_header_id|>\n\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<|eot_id|>");
                }
            }
            try result.appendSlice(allocator, "<|start_header_id|>assistant<|end_header_id|>\n\n");
        } else {
            // Gemma-style format
            if (tools_json != null and !has_system) {
                try result.appendSlice(allocator, "<start_of_turn>user\n");
                try appendToolSystemPrompt(allocator, &result, tools_json.?, tool_choice_instruction);
                try result.appendSlice(allocator, "<end_of_turn>\n");
            }
            for (messages) |msg| {
                if (std.mem.eql(u8, msg.role, "tool")) {
                    try result.appendSlice(allocator, "<start_of_turn>user\n");
                    try result.appendSlice(allocator, "Tool result: ");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<end_of_turn>\n");
                } else {
                    try result.appendSlice(allocator, "<start_of_turn>");
                    try result.appendSlice(allocator, msg.role);
                    try result.appendSlice(allocator, "\n");
                    try result.appendSlice(allocator, msg.content);
                    try result.appendSlice(allocator, "<end_of_turn>\n");
                }
            }
            try result.appendSlice(allocator, "<start_of_turn>model\n");
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse tool calls from model output text.
/// Looks for <tool_call>...</tool_call> markers or raw JSON with "name"/"arguments" keys.
/// Returns null if no tool calls found.
pub fn parseToolCalls(allocator: std.mem.Allocator, text: []const u8) !?[]ParsedToolCall {
    var calls = std.ArrayList(ParsedToolCall).empty;
    errdefer {
        for (calls.items) |tc| {
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        calls.deinit(allocator);
    }

    // Look for <tool_call>...</tool_call> patterns
    var search_pos: usize = 0;
    while (search_pos < text.len) {
        const tag_start = std.mem.indexOf(u8, text[search_pos..], "<tool_call>") orelse break;
        const content_start = search_pos + tag_start + "<tool_call>".len;
        const tag_end = std.mem.indexOf(u8, text[content_start..], "</tool_call>") orelse break;
        const content = std.mem.trim(u8, text[content_start .. content_start + tag_end], " \t\n\r");
        search_pos = content_start + tag_end + "</tool_call>".len;

        if (try parseToolCallJson(allocator, content)) |tc| {
            try calls.append(allocator, tc);
        }
    }

    // If no <tool_call> tags, try to find raw JSON tool call in the text
    if (calls.items.len == 0) {
        // Strip any stray closing tags and find the first { in the text
        var trimmed = std.mem.trim(u8, text, " \t\n\r");
        // Strip leading </tool_call> if present (model artifact)
        if (std.mem.startsWith(u8, trimmed, "</tool_call>")) {
            trimmed = std.mem.trim(u8, trimmed["</tool_call>".len..], " \t\n\r");
        }
        // Find the first JSON object
        if (std.mem.indexOf(u8, trimmed, "{")) |brace_pos| {
            const json_start = trimmed[brace_pos..];
            if (try parseToolCallJson(allocator, json_start)) |tc| {
                try calls.append(allocator, tc);
            }
        }
    }

    if (calls.items.len == 0) return null;
    return try calls.toOwnedSlice(allocator);
}

pub const ParsedToolCall = struct {
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Try to parse a JSON string as a tool call.
/// Supports both {"name":"...", "arguments":{...}} and {"name":"...", "parameters":{...}}
fn parseToolCallJson(allocator: std.mem.Allocator, json_text: []const u8) !?ParsedToolCall {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    // Look for "arguments" or "parameters" — extract from raw JSON text
    const args_key = if (std.mem.indexOf(u8, json_text, "\"arguments\"") != null)
        "arguments"
    else if (std.mem.indexOf(u8, json_text, "\"parameters\"") != null)
        "parameters"
    else
        return null;

    const args_str = extractJsonValue(allocator, json_text, args_key) orelse
        try allocator.dupe(u8, "{}");

    return .{
        .name = try allocator.dupe(u8, name_val.string),
        .arguments = args_str,
    };
}

/// Extract a JSON value substring for a given key from raw JSON text.
fn extractJsonValue(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key"
    var buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, search_key) orelse return null;
    var i = key_pos + search_key.len;

    // Skip whitespace and colon
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) {
        i += 1;
    }
    if (i >= json.len) return null;

    // Extract the value
    if (json[i] == '{' or json[i] == '[') {
        const open = json[i];
        const close: u8 = if (open == '{') '}' else ']';
        var depth: usize = 1;
        var j = i + 1;
        var in_str = false;
        while (j < json.len and depth > 0) {
            if (json[j] == '\\' and in_str) {
                j += 1;
            } else if (json[j] == '"') {
                in_str = !in_str;
            } else if (!in_str) {
                if (json[j] == open) depth += 1;
                if (json[j] == close) depth -= 1;
            }
            j += 1;
        }
        if (depth == 0) return allocator.dupe(u8, json[i..j]) catch null;
    } else if (json[i] == '"') {
        // String value — find closing quote
        var j = i + 1;
        while (j < json.len) {
            if (json[j] == '\\') {
                j += 1;
            } else if (json[j] == '"') {
                return allocator.dupe(u8, json[i + 1 .. j]) catch null;
            }
            j += 1;
        }
    }
    return null;
}

/// Append tool definitions as a system prompt section.
fn appendToolSystemPrompt(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools_json: []const u8, tool_choice_instruction: ?[]const u8) !void {
    try result.appendSlice(allocator,
        \\You are a helpful assistant with access to the following functions. To call a function, respond with a JSON object in the following format:
        \\<tool_call>
        \\{"name": "function_name", "arguments": {"arg1": "value1"}}
        \\</tool_call>
        \\
        \\Available functions:
        \\
    );
    try result.appendSlice(allocator, tools_json);
    if (tool_choice_instruction) |instr| {
        try result.appendSlice(allocator, instr);
    }
}
