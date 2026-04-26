//! Renders MyST AST as JSON.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const ast = @import("../ast.zig");

pub const Options = extern struct {
    whitespace: enum(c_uint) {
        minified = 0,
        indent_2 = 1,
        indent_4 = 2,
    } = .minified,
};

/// Renders the given AST as JSON.
///
/// The given AST node might be the root, but it might not. We support
/// rendering arbitrary subtrees of a complete MyST AST.
pub fn render(
    node: *ast.Node,
    out: *Io.Writer,
    options: Options,
) Io.Writer.Error!void {
    const stringify_options: Stringify.Options = .{
        .whitespace = switch (options.whitespace) {
            .minified => .minified,
            .indent_2 => .indent_2,
            .indent_4 => .indent_4,
        },
    };
    var stringify = Stringify{
        .writer = out,
        .options = stringify_options,
    };
    try render_node(&stringify, node);
}

fn render_node(stringify: *Stringify, node: *ast.Node) Io.Writer.Error!void {
    // These nodes don't get rendered
    if (node.tag == .definition) {
        return;
    }

    try stringify.beginObject();
    try stringify.objectField("type");

    switch (node.tag) {
        .thematic_break => try stringify.write("thematicBreak"),
        .inline_code => try stringify.write("inlineCode"),
        .myst_role => try stringify.write("mystRole"),
        .myst_role_error => try stringify.write("mystRoleError"),
        .myst_directive => try stringify.write("mystDirective"),
        .myst_directive_error => try stringify.write("mystDirectiveError"),
        .admonition_title => try stringify.write("admonitionTitle"),
        else => try stringify.write(@tagName(node.tag)),
    }

    switch (node.tag) {
        inline .root, .paragraph, .block, .emphasis, .strong,
        .blockquote, .subscript, .superscript,
        .admonition_title => |node_type| {
            const n = @field(node.payload, @tagName(node_type));
            try render_children(stringify, n);
        },
        .heading => {
            const n = node.payload.heading;
            try stringify.objectField("depth");
            try stringify.write(n.depth);
            try render_children(stringify, n);
        },
        inline .text, .inline_code, .html => |node_type| {
            const n = @field(node.payload, @tagName(node_type));
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .code => {
            const n = node.payload.code;
            try stringify.objectField("lang");
            try stringify.write(n.lang);
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .link => {
            const n = node.payload.link;
            try stringify.objectField("url");
            try stringify.write(std.mem.span(n.url));

            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }

            try render_children(stringify, n);
        },
        .image => {
            const n = node.payload.image;
            try stringify.objectField("url");
            try stringify.write(std.mem.span(n.url));

            const alt = std.mem.span(n.alt);
            if (alt.len > 0) {
                try stringify.objectField("alt");
                try stringify.write(alt);
            }

            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }
        },
        .@"break", .thematic_break => {},
        .definition => unreachable,
        .container => {
            const n = node.payload.container;

            try stringify.objectField("kind");
            try stringify.write(std.mem.span(n.kind));

            if (n.n_children > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_role => {
            const n = node.payload.myst_role;
            try stringify.objectField("name");
            try stringify.write(std.mem.span(n.name));

            try stringify.objectField("value");
            try stringify.write(std.mem.span(n.value));

            if (n.n_children > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_role_error => {
            const n = node.payload.myst_role;
            try stringify.objectField("value");
            try stringify.write(std.mem.span(n.value));
        },
        .abbreviation => {
            const n = node.payload.abbreviation;
            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }

            if (n.n_children > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_directive => {
            const n = node.payload.myst_directive;
            try stringify.objectField("name");
            try stringify.write(std.mem.span(n.name));

            const args = std.mem.span(n.args);
            if (args.len > 0) {
                try stringify.objectField("args");
                try stringify.write(args);
            }

            const value = std.mem.span(n.value);
            if (value.len > 0) {
                try stringify.objectField("value");
                try stringify.write(value);
            }

            if (n.n_children > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_directive_error => {
            const n = node.payload.myst_directive_error;
            try stringify.objectField("message");
            try stringify.write(std.mem.span(n.message));
        },
        .admonition => {
            const n = node.payload.admonition;

            const kind = std.mem.span(n.kind);
            if (kind.len > 0) {
                try stringify.objectField("kind");
                try stringify.write(kind);
            }

            if (n.n_children > 0) {
                try render_children(stringify, n);
            }
        },
    }

    try stringify.endObject();
}

fn render_children(
    stringify: *Stringify,
    node_data: anytype,
) Io.Writer.Error!void {
    try stringify.objectField("children");
    try stringify.beginArray();

    const sliced = node_data.children[0..node_data.n_children];
    for (sliced) |child| {
        try render_node(stringify, child);
    }

    try stringify.endArray();
}
