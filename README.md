> Reward? I'm sorry but all I have to offer you is... the library on the island
> of Myst. The books, that are contained there. Feel free to explore.

—Atrus, _Myst (1993)_

# Atrus
Atrus is a MyST document engine. Atrus parses [MyST-flavored
Markdown](https://mystmd.org/spec/overview) and can output MyST AST or HTML.
Other renderers might be added in the future.

MyST is a superset of [CommonMark](https://commonmark.org/), so Atrus is also
a CommonMark-compliant Markdown parser and HTML renderer.

Atrus is written in Zig and can be consumed as a Zig module, but also exports
a C API.

## Roadmap
Atrus can currently parse the following Markdown document:

~~~md
# Heading
This is a paragraph, containing `code`, *emphasis*, and **strong** text.

```python This is a code block.
def foo():
   pass
```

> This is a blockquote.

## Subheading
Checkout my cool [link][google].

[google]: https://google.com
~~~

This is exciting!

Much more work remains:

- [x] Get minimal parser working
- [x] Set up basic build
- [x] Set up MyST spec test suite
- [x] Get basic C API working
- [ ] Finish implementing commonmark spec
- [ ] Finish implementing MyST extensions
- [ ] Implement JSON AST parser
- [ ] Add benchmarks
- [ ] Expose AST via C API
