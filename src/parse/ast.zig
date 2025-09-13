//! Abstract syntax tree for a MyST document.
//!
//! https://mystmd.org/spec

pub const NodeType = enum {
    root,
    heading,
    paragraph,
};

pub const AstNode = struct {
    node_type: NodeType,
};

pub const MystAst = struct {
    root: AstNode,
};
