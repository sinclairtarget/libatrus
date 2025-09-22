# Atrus
A MyST document engine. Atrus parses [MyST-flavored
Markdown](https://mystmd.org/spec/overview) and can output MyST AST or HTML.
Other renderers might be added in the future.

MyST is a superset of [CommonMark](https://commonmark.org/), so Atrus is also
a CommonMark-compliant Markdown parser and HTML renderer.

Atrus is written in Zig and can be consumed as a Zig module, but also exports
a C API.

## Roadmap
Atrus can currently parse the following Markdown document:
```
# Heading
This is a paragraph.
```

This is exciting!

Much more work remains:

- [x] Get minimal parser working
- [x] Set up basic build
- [x] Set up MyST spec test suite
- [x] Get basic C API working
- [ ] ...actually implement a spec-compliant parser
- [ ] Implement HTML renderer
- [ ] Implement YAML renderer
- [ ] Implement JSON AST parser
- [ ] Add benchmarks
