const std = @import("std");
const Ast = std.zig.Ast;
const Builder = @import("code_actions.zig").Builder;
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const types = @import("lsp").types;

fn fresh(builder: *Builder, base: []const u8) error{OutOfMemory}![]const u8 {
    var suffix: usize = 0;
    while (true) : (suffix += 1) {
        const name = if (suffix == 0) base else try builder.arena.print("{s}{d}", .{ base, suffix });
        for (0..builder.handle.tree.tokens.len) |i| {
            const token: Ast.TokenIndex = @intCast(i);
            if (builder.handle.tree.tokenTag(token) == .identifier and std.mem.eql(u8, builder.handle.tree.tokenSlice(token), name)) break;
        } else return name;
    }
}

fn action(builder: *Builder, title: []const u8, edits: []const types.TextEdit) error{OutOfMemory}!void {
    try builder.actions.append(builder.arena, .{ .title = title, .kind = .refactor, .edit = try builder.createWorkspaceEdit(edits) });
}

pub fn generate(builder: *Builder, range: types.Range) Analyser.Error!void {
    if (!builder.wantKind(.refactor)) return;
    const tree = &builder.handle.tree;
    const start = offsets.positionToIndex(tree.source, range.start, builder.offset_encoding);
    const end = offsets.positionToIndex(tree.source, range.end, builder.offset_encoding);
    if (end > start) {
        try extract(builder, .{ .start = start, .end = end });
    } else {
        try inlineConstant(builder, start);
    }
}

fn extract(builder: *Builder, selected: offsets.Loc) Analyser.Error!void {
    const tree = &builder.handle.tree;
    const ancestors = try ast.nodesOverlappingIndex(builder.arena, tree, selected.start);
    for (ancestors, 0..) |node, index| {
        const loc = offsets.nodeToLoc(tree, node);
        if (loc.start != selected.start or loc.end != selected.end) continue;
        if (index + 1 >= ancestors.len) return;
        const declaration_node = ancestors[index + 1];
        const declaration = tree.fullVarDecl(declaration_node) orelse return;
        if (declaration.ast.init_node != node.toOptional()) return;
        const function = for (ancestors[index + 2 ..]) |parent| {
            if (tree.nodeTag(parent) == .fn_decl) break parent;
        } else return;
        const statement = offsets.nodeToLoc(tree, declaration_node);
        const line = offsets.lineLocAtIndex(tree.source, statement.start);
        const indent = tree.source[line.start..statement.start];
        if (std.mem.trim(u8, indent, " \t").len != 0) return;
        const name = try fresh(builder, "extracted");
        const annotation = if (declaration.ast.type_node.unwrap()) |ty|
            try builder.arena.print(": {s}", .{offsets.nodeToSlice(tree, ty)})
        else
            "";
        const expression = offsets.locToSlice(tree.source, selected);
        try action(builder, "Extract variable", &.{
            builder.createTextEditPos(statement.start, try builder.arena.print("const {s}{s} = {s};\n{s}", .{ name, annotation, expression, indent })),
            builder.createTextEditLoc(selected, name),
        });
        try extractFunction(builder, node, function, selected);
        return;
    }
}

fn extractFunction(builder: *Builder, node: Ast.Node.Index, function: Ast.Node.Index, selected: offsets.Loc) Analyser.Error!void {
    const tree = &builder.handle.tree;
    const function_loc = offsets.nodeToLoc(tree, function);
    const line = offsets.lineLocAtIndex(tree.source, function_loc.start);
    const indent = tree.source[line.start..function_loc.start];
    if (std.mem.trim(u8, indent, " \t").len != 0) return;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var parameters: std.ArrayList([]const u8) = .empty;
    var arguments: std.ArrayList([]const u8) = .empty;
    var walker = try ast.Walker.init(builder.arena, tree, node);
    defer walker.deinit(builder.arena);
    while (try walker.next(builder.arena, tree)) |event| {
        if (event != .open) continue;
        const child = event.open;
        switch (tree.nodeTag(child)) {
            // These constructs can capture control flow, evaluation context,
            // addresses or mutation. A by-value extraction is not safe for them.
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .address_of,
            .assign,
            .assign_destructure,
            .@"try",
            .@"catch",
            .@"orelse",
            .@"return",
            .@"break",
            .@"continue",
            .block,
            .block_semicolon,
            .block_two,
            .block_two_semicolon,
            .if_simple,
            .@"if",
            .@"switch",
            .switch_comma,
            .bool_and,
            .bool_or,
            => return,
            .identifier => {
                const token = tree.nodeMainToken(child);
                const name = tree.tokenSlice(token);
                if (std.zig.isPrimitive(name)) continue;
                const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, name, tree.tokenStart(token)) orelse return;
                if (try decl.isStatic()) continue;
                const entry = try names.getOrPut(builder.arena, name);
                if (entry.found_existing) continue;
                try arguments.append(builder.arena, name);
                try parameters.append(builder.arena, try builder.arena.print("{s}: anytype", .{name}));
            },
            else => {},
        }
    }
    const result_type = try builder.analyser.resolveTypeOfNode(.of(node, builder.handle)) orelse return;
    // Keep this first implementation to scalar results; local or anonymous
    // container types may not be visible beside the enclosing function.
    if (result_type.data != .ip_index) return;
    switch (builder.analyser.ip.zigTypeTag(result_type.data.ip_index.type) orelse return) {
        .int, .float, .bool => {},
        else => return,
    }
    const type_name = try result_type.stringifyTypeOf(builder.analyser, .{ .truncate_container_decls = false });
    if (std.mem.indexOf(u8, type_name, "unknown") != null) return;
    const name = try fresh(builder, "extractedFunction");
    const args = try std.mem.join(builder.arena, ", ", arguments.items);
    const params = try std.mem.join(builder.arena, ", ", parameters.items);
    try action(builder, "Extract function", &.{
        builder.createTextEditLoc(selected, try builder.arena.print("{s}({s})", .{ name, args })),
        builder.createTextEditPos(function_loc.end, try builder.arena.print("\n\n{s}fn {s}({s}) {s} {{\n{s}    return {s};\n{s}}}", .{ indent, name, params, type_name, indent, offsets.locToSlice(tree.source, selected), indent })),
    });
}

fn inlineConstant(builder: *Builder, position: usize) Analyser.Error!void {
    const tree = &builder.handle.tree;
    const name_loc = offsets.identifierLocFromIndex(tree, position) orelse return;
    const decl = try builder.analyser.lookupSymbolGlobal(builder.handle, offsets.locToSlice(tree.source, name_loc), position) orelse return;
    if (decl.handle != builder.handle or decl.decl != .ast_node or try decl.isStatic()) return;
    const node = decl.decl.ast_node;
    const variable = tree.fullVarDecl(node) orelse return;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return;
    const init = variable.ast.init_node.unwrap() orelse return;
    switch (tree.nodeTag(init)) {
        .number_literal, .char_literal, .string_literal => {},
        else => return,
    }
    const references = try @import("references.zig").declarationReferences(builder.analyser, decl, builder.offset_encoding);
    if (references.items.len != 1 or !std.mem.eql(u8, references.items[0].uri, builder.handle.uri.raw)) return;
    const loc = offsets.nodeToLoc(tree, node);
    const line = offsets.lineLocAtIndex(tree.source, loc.start);
    if (std.mem.trim(u8, tree.source[line.start..loc.start], " \t").len != 0) return;
    const line_end = std.mem.indexOfScalarPos(u8, tree.source, loc.end, '\n') orelse tree.source.len;
    if (!std.mem.eql(u8, std.mem.trim(u8, tree.source[loc.end..line_end], " \t\r"), ";")) return;
    const expression = offsets.nodeToSlice(tree, init);
    const replacement = if (variable.ast.type_node.unwrap()) |ty|
        try builder.arena.print("@as({s}, {s})", .{ offsets.nodeToSlice(tree, ty), expression })
    else
        try builder.arena.print("({s})", .{expression});
    try action(builder, "Inline constant", &.{
        builder.createTextEditLoc(.{ .start = line.start, .end = if (line_end < tree.source.len) line_end + 1 else line_end }, ""),
        .{ .range = references.items[0].range, .newText = replacement },
    });
}
