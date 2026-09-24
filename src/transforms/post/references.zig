const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const myst = @import("../../myst/myst.zig");

const TargetMap = std.hash_map.StringHashMapUnmanaged(*ast.Node);

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var node = original_node;

    node = try transformTargets(alloc, scratch, node);

    var target_map: TargetMap = .empty;
    try fillTargetMap(scratch, node, &target_map);

    node = try transformLinksToRef(alloc, scratch, node, target_map);
    node = try transformResolve(alloc, scratch, node, target_map);

    return node;
}

/// Handles all reference targets in the tree, applying them to their next
/// sibling.
fn transformTargets(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                if (n.children.len == 0) {
                    return original_node;
                }

                // recurse first
                for (0..n.children.len) |i| {
                    n.children[i] = try transformTargets(
                        alloc,
                        scratch,
                        n.children[i],
                    );
                }

                // now handle reference targets
                const old_children = n.children;
                defer alloc.free(old_children);

                const new_children = try alloc.alloc(
                    *ast.Node,
                    n.children.len,
                );

                var new_children_i: usize = 0;
                for (0..n.children.len - 1, 1..n.children.len) |i, j| {
                    const target = switch (n.children[i].*) {
                        .target => |target_n| target_n,
                        else => {
                            new_children[new_children_i] = n.children[i];
                            new_children_i += 1;
                            continue;
                        },
                    };
                    switch (n.children[j].*) {
                        inline .code, .heading => |*applied_n| {
                            if (applied_n.label != null) continue;
                            applied_n.label = try alloc.dupeZ(
                                u8,
                                target.label,
                            );

                            const id = try myst.references.normalizeIdentifier(
                                scratch,
                                target.label,
                            );
                            applied_n.identifier = try alloc.dupeZ(u8, id);

                            n.children[i].deinit(alloc);
                        },
                        else => {
                            new_children[new_children_i] = n.children[i];
                            new_children_i += 1;
                        },
                    }
                }

                new_children[new_children_i] = n.children[n.children.len - 1];
                new_children_i += 1;

                n.children = try alloc.realloc(new_children, new_children_i);

                return original_node;
            },
        },
        .no => return original_node,
    }
}

/// For all links in the tree that could be a cross reference, replace the link
/// node with an unresolved cross reference node.
fn transformLinksToRef(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
    target_map: TargetMap,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .link => |n| {
                // We check to see if the link URL could be a cross reference.
                const maybe_ref_id = blk: {
                    // First check if the URL is a valid identifier
                    const ref_id = try linkURLToReferenceID(
                        scratch,
                        n.url,
                    ) orelse break :blk null;
                    // Then check if there's a matching target
                    if (!target_map.contains(ref_id))
                        break :blk null;

                    break :blk ref_id;
                };
                if (maybe_ref_id) |id| {
                    // TODO: Should be a better way to non-recursively
                    // deallocate a node.
                    defer alloc.free(n.url);
                    defer alloc.free(n.title);
                    defer alloc.destroy(original_node);

                    const label = try alloc.dupeZ(u8, id);
                    const identifier = try alloc.dupeZ(u8, id);

                    const ref_node = try alloc.create(ast.Node);
                    ref_node.* = .{
                        .cross_reference = .{
                            .children = n.children,
                            .kind = try alloc.dupeZ(u8, "ref"),
                            .label = label,
                            .identifier = identifier,
                        },
                    };

                    if (n.title.len > 0) {
                        ref_node.cross_reference.title = try alloc.dupeZ(
                            u8,
                            n.title,
                        );
                    }

                    return ref_node;
                } else {
                    return original_node;
                }
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try transformLinksToRef(
                        alloc,
                        scratch,
                        n.children[i],
                        target_map,
                    );
                }
                return original_node;
            },
        },
        .no => return original_node,
    }
}

/// Pairs each cross reference in the AST with its target and resolves the
/// cross reference.
///
/// This means that we update the "kind" of the cross reference depending on
/// the type of node it points to. We also add children to the cross reference
/// if it doesn't already have children, implementing default link text
/// depending on the cross reference type (i.e. "Table 1" or "My Heading").
fn transformResolve(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
    target_map: TargetMap,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .cross_reference => |n| {
                const target_node = target_map.get(n.identifier) orelse
                    return original_node; // TODO: Anything more to do here?

                n.resolved = true;

                // Assign kind.
                // Unclear exactly what these values should be. Not part of the
                // MyST spec.
                switch (target_node.*) {
                    .heading => {
                        alloc.free(n.kind);
                        n.kind = try alloc.dupeZ(u8, "heading");
                    },
                    .math => {
                        alloc.free(n.kind);
                        n.kind = try alloc.dupeZ(u8, "equation");
                    },
                    .container => |target_n| {
                        alloc.free(n.kind);
                        n.kind = try alloc.dupeZ(u8, target_n.kind);
                    },
                    // TODO: Handle other cases
                    else => @panic("not yet implemented"),
                }

                if (n.children.len > 0) {
                    // exit early, no need to add default link text
                    return original_node;
                }

                // Add children to implement default link text
                switch (target_node.*) {
                    .heading => |target_n| {
                        try generateHeadingCrossRefLinkText(
                            alloc,
                            n,
                            target_n,
                        );
                    },
                    .math => |target_n| {
                        try generateEquationCrossRefLinkText(
                            alloc,
                            n,
                            target_n,
                        );
                    },
                    .container => |target_n| {
                        try generateContainerCrossRefLinkText(
                            alloc,
                            n,
                            target_n,
                        );
                    },
                    // TODO: Handle other cases
                    else => @panic("not yet implemented"),
                }
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try transformResolve(
                        alloc,
                        scratch,
                        n.children[i],
                        target_map,
                    );
                }
            },
        },
        .no => {},
    }

    return original_node;
}

/// Adds all potential targets for cross references to the hash map.
///
/// Any node with a label/identifier pair is a potential target.
fn fillTargetMap(alloc: Allocator, node: *ast.Node, map: *TargetMap) !void {
    switch (node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline .heading, .container => |n| {
                if (n.identifier) |identifier| {
                    if (!map.contains(identifier)) {
                        try map.put(alloc, identifier, node);
                    }
                }

                for (n.children) |child| {
                    try fillTargetMap(alloc, child, map);
                }
            },
            inline else => |n| {
                for (n.children) |child| {
                    try fillTargetMap(alloc, child, map);
                }
            },
        },
        .no => |leaf_node| switch (leaf_node) {
            inline .code, .math => |n| {
                if (n.identifier) |identifier| {
                    if (!map.contains(identifier)) {
                        try map.put(alloc, identifier, node);
                    }
                }
            },
            else => {},
        },
    }
}

/// If the given URL contains only a fragment, turns that fragment into a
/// reference ID and returns it. Otherwise returns null.
///
/// That's the idea, anyway. In later versions of MyST, the URL has to be a
/// fragment, i.e. has to start with "#". In MyST 0.0.5, this isn't true. So we
/// consider just a plain string, even if it doesn't start with "#", to be a
/// fragment, so long as it doesn't look like an absolute or relative URL.
fn linkURLToReferenceID(alloc: Allocator, url: []const u8) !?[]const u8 {
    if (url.len == 0)
        return null;

    // If we can parse it as a URI, skip it
    if (std.Uri.parse(url)) |_| {
        return null;
    } else |_| {}

    // If it starts with a forward slash, consider it a relative URL, skip it
    if (url[0] == '/' or std.mem.startsWith(u8, url, "./"))
        return null;

    const unnormalized = blk: {
        // If it starts with "#", we have a fragment, strip the "#" to get the
        // reference ID
        if (url[0] == '#') {
            if (url.len == 1) return null;
            break :blk url[1..];
        }

        // We have a plain string that we'll pretend is a fragment
        break :blk url;
    };
    return try myst.references.normalizeIdentifier(alloc, unnormalized);
}

/// For cross refs to headings, the default link text is the text of the
/// heading itself.
///
/// So this function deep copies all children of the heading node to the cross
/// reference node.
fn generateHeadingCrossRefLinkText(
    alloc: Allocator,
    cross_ref: *ast.CrossReference,
    heading: ast.Heading,
) !void {
    std.debug.assert(cross_ref.children.len == 0);
    cross_ref.children = try ast.cloneChildren(alloc, heading.children);
}

/// For cross refs to equations, the default link text is the equation number
/// in parentheses. If the target node is for some reason not enumerated, then
/// we fall back to just "Equation".
fn generateEquationCrossRefLinkText(
    alloc: Allocator,
    cross_ref: *ast.CrossReference,
    math: ast.Math,
) !void {
    std.debug.assert(cross_ref.children.len == 0);

    const owned_value = if (math.enumerator) |enumerator|
        try std.fmt.allocPrintSentinel(alloc, "({s})", .{enumerator}, 0)
    else
        try alloc.dupeZ(u8, "Equation");

    const text_node = try alloc.create(ast.Node);
    text_node.* = .{
        .text = .{ .value = owned_value },
    };

    const new_children = try alloc.alloc(*ast.Node, 1);
    new_children[0] = text_node;

    cross_ref.children = new_children;
}

/// For cross refs to containers, the default link text depends on the
/// container type.
///
/// Figures (MyST 0.0.5):
///   If captioned, use the caption.
///   If enumerated, should be text reading "Figure x".
///   Otherwise, just "Figure".
///
/// Tables (MyST 0.0.5):
///   If captioned, use the caption.
///   If enumerated, should be text reading "Table x".
///   Otherwise, just "Table".
fn generateContainerCrossRefLinkText(
    alloc: Allocator,
    cross_ref: *ast.CrossReference,
    container: ast.Container,
) !void {
    std.debug.assert(cross_ref.children.len == 0);

    const title_case_kind, const caption_child_i: usize = blk: {
        if (std.mem.eql(u8, container.kind, "figure")) {
            break :blk .{"Figure", 1};
        } else if (std.mem.eql(u8, container.kind, "table")) {
            break :blk .{"Table", 0};
        } else {
            @panic("not yet implemented");
        }
    };

    const new_children = blk: {
        if (container.children.len > 1 and
            @as(ast.NodeType, container.children[caption_child_i].*) == .caption)
        {
            const caption_node = container.children[caption_child_i];
            const children_to_clone = children_blk: {
                if (caption_node.caption.children.len > 0) {
                    const child_node = caption_node.caption.children[0];
                    if (@as(ast.NodeType, child_node.*) == .paragraph) {
                        break :children_blk child_node.paragraph.children;
                    }
                }

                break :children_blk caption_node.caption.children;
            };

            // Clone base node children to use as link text
            break :blk try ast.cloneChildren(alloc, children_to_clone);
        } else {
            const owned_value = if (container.enumerator) |enumerator|
                try std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} {s}",
                    .{ title_case_kind, enumerator },
                    0,
                )
            else
                try alloc.dupeZ(u8, title_case_kind);

            const text_node = try alloc.create(ast.Node);
            text_node.* = .{
                .text = .{ .value = owned_value },
            };

            const new_children = try alloc.alloc(*ast.Node, 1);
            new_children[0] = text_node;
            break :blk new_children;
        }
    };

    cross_ref.children = new_children;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../../util/util.zig");

test "apply reference target to code block" {
    const target_node = try testing.allocator.create(ast.Node);
    target_node.* = .{
        .target = .{
            .label = try testing.allocator.dupeZ(u8, "Foo"),
        },
    };

    const code_node = try testing.allocator.create(ast.Node);
    code_node.* = .{
        .code = .{
            .value = try testing.allocator.dupeZ(u8, "def foo():\n    pass"),
            .lang = try testing.allocator.dupeZ(u8, "python"),
        },
    };

    const root_node: *ast.Node = blk: {
        const node = try testing.allocator.create(ast.Node);
        const children = try testing.allocator.dupe(*ast.Node, &[_]*ast.Node{
            target_node,
            code_node,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.root.children.len);

    const post_code_node = post_node.root.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, post_code_node.*));

    const label = try util.testing.expectNonNull(post_code_node.code.label);
    try testing.expectEqualStrings("Foo", label);

    const identifier = try util.testing.expectNonNull(
        post_code_node.code.identifier,
    );
    try testing.expectEqualStrings("foo", identifier);
}

test "handle reference target with no next sibling" {
    const target_node = try testing.allocator.create(ast.Node);
    target_node.* = .{
        .target = .{
            .label = try testing.allocator.dupeZ(u8, "Foo"),
        },
    };

    const root_node: *ast.Node = blk: {
        const node = try testing.allocator.create(ast.Node);
        const children = try testing.allocator.dupe(*ast.Node, &[_]*ast.Node{
            target_node,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));

    // Reference target node should stay in AST.
    try testing.expectEqual(1, post_node.root.children.len);
    const post_target_node = post_node.root.children[0];
    try testing.expectEqual(.target, @as(ast.NodeType, post_target_node.*));
}

test "link to ref" {
    const heading_text_node = try testing.allocator.create(ast.Node);
    heading_text_node.* = .{
        .text = .{ .value = try testing.allocator.dupeZ(u8, "My Heading") },
    };

    const heading_node = try testing.allocator.create(ast.Node);
    heading_node.* = .{
        .heading = .{
            .depth = 1,
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{heading_text_node},
            ),
            .label = try testing.allocator.dupeZ(u8, "pasta"),
            .identifier = try testing.allocator.dupeZ(u8, "pasta"),
        },
    };

    const link_text_node = try testing.allocator.create(ast.Node);
    link_text_node.* = .{
        .text = .{ .value = try testing.allocator.dupeZ(u8, "Bucatini") },
    };

    const fragment_link_node = try testing.allocator.create(ast.Node);
    fragment_link_node.* = .{
        .link = .{
            .url = try testing.allocator.dupeZ(u8, "pasta"),
            .title = try testing.allocator.dupeZ(u8, "The Best Pasta"),
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{link_text_node},
            ),
        },
    };

    const paragraph_text_node = try testing.allocator.create(ast.Node);
    paragraph_text_node.* = .{
        .text = .{ .value = try testing.allocator.dupeZ(u8, " is my fav.") },
    };

    const abs_link_node = try testing.allocator.create(ast.Node);
    abs_link_node.* = .{
        .link = .{
            .url = try testing.allocator.dupeZ(u8, "http://google.com"),
            .title = try testing.allocator.dupeZ(u8, "Google"),
            .children = &.{},
        },
    };

    const p_node = try testing.allocator.create(ast.Node);
    p_node.* = .{
        .paragraph = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{ fragment_link_node, paragraph_text_node, abs_link_node },
            ),
        },
    };

    const root_node = try testing.allocator.create(ast.Node);
    root_node.* = .{
        .root = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{ heading_node, p_node },
            ),
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(2, post_node.root.children.len);

    const post_p_node = post_node.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, post_p_node.*));
    try testing.expectEqual(3, post_p_node.paragraph.children.len);

    const ref_node = post_p_node.paragraph.children[0];
    try testing.expectEqual(.cross_reference, @as(ast.NodeType, ref_node.*));
    try testing.expectEqualStrings("heading", ref_node.cross_reference.kind);
    try testing.expectEqualStrings("pasta", ref_node.cross_reference.label);
    try testing.expectEqualStrings(
        "pasta",
        ref_node.cross_reference.identifier,
    );
    const title = try util.testing.expectNonNull(
        ref_node.cross_reference.title,
    );
    try testing.expectEqualStrings("The Best Pasta", title);

    try testing.expectEqual(1, ref_node.cross_reference.children.len);
    const post_link_text_node = ref_node.cross_reference.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, post_link_text_node.*));

    // Other link should be unchanged
    const link_node = post_p_node.paragraph.children[2];
    try testing.expectEqual(.link, @as(ast.NodeType, link_node.*));
}

test "heading cross reference resolution" {
    const target_node = try testing.allocator.create(ast.Node);
    target_node.* = .{
        .target = .{
            .label = try testing.allocator.dupeZ(u8, "my-heading"),
        },
    };

    const heading_txt_node = try testing.allocator.create(ast.Node);
    heading_txt_node.* = .{
        .text = .{ .value = try testing.allocator.dupeZ(u8, "My Heading") },
    };
    const heading_node = try testing.allocator.create(ast.Node);
    heading_node.* = .{
        .heading = .{
            .depth = 1,
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{heading_txt_node},
            ),
        },
    };

    const fragment_link_node = try testing.allocator.create(ast.Node);
    fragment_link_node.* = .{
        .link = .{
            .title = try testing.allocator.dupeZ(u8, ""),
            .url = try testing.allocator.dupeZ(u8, "my-heading"),
            .children = &.{},
        },
    };
    const p_node = try testing.allocator.create(ast.Node);
    p_node.* = .{
        .paragraph = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{fragment_link_node},
            ),
        },
    };

    const root_node = try testing.allocator.create(ast.Node);
    root_node.* = .{
        .root = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{
                    target_node,
                    heading_node,
                    p_node,
                },
            ),
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const post_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer post_node.deinit(testing.allocator);
    try testing.expectEqual(2, post_node.root.children.len);

    const post_p_node = post_node.root.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, post_p_node.*));
    try testing.expectEqual(1, post_p_node.paragraph.children.len);

    const ref_node = post_p_node.paragraph.children[0];
    try testing.expectEqualStrings("heading", ref_node.cross_reference.kind);
    try testing.expectEqual(1, ref_node.cross_reference.children.len);

    const ref_txt_node = ref_node.cross_reference.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, ref_txt_node.*));
    try testing.expectEqualStrings("My Heading", ref_txt_node.text.value);
}
