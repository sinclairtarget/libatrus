# Atrus
> Reward? I'm sorry but all I have to offer you is... the library on the island
> of Myst. The books, that are contained there. Feel free to explore.
>
> —Atrus, _Myst_ (1993)

Atrus parses [MyST Markdown](https://mystmd.org/spec/overview) into the MyST
abstract syntax tree. It can render the AST as JSON or as HTML. Other renderers
(such as for [Typst](https://github.com/typst/typst)) might be added in the
future.

MyST is a superset of [CommonMark](https://commonmark.org/), so Atrus is also
a CommonMark-compliant Markdown parser and HTML renderer.

Atrus is written in Zig and can be consumed as a Zig package, but also exports
a C API.

## Disclaimer
Atrus implements the MyST Markdown specification but has no affiliation with
the MyST specification authors, Jupyter Book, or Project Jupyter.

## Usage
_For an example of an application using Atrus as a Zig package, see
[here][aweigh gh]. For an example of an application using Atrus via the C API,
see [Michel][michel gh] and [libatrus-go][libatrus-go gh]._

## Roadmap
Atrus can currently parse the following Markdown document:

~~~txt
# Heading
This is a paragraph, containing `code`, *emphasis*, and **strong** text.

```python This is a regular code block.
def foo():
   pass
```

> This is a blockquote.
>
> > You can nest blockquotes!
> > 
> > Or even put code inside them:
> > 
> > ```zig
> > fn foo() u8 {
> >     return 'a';
> > }
> > ```

## Subheading
Checkout my cool [link][google].

[google]: https://google.com

## Roles
In {abbr}`MyST (Markedly Structured Text)`, you can create abbreviations using
roles.

## Directives
You can also use MyST directives, like this one creating a warning admonition:

```{warning}
This project is in development. It has bugs and is NOT secure!
```
~~~

This is exciting!

Much more work remains:

- [x] Get minimal parser working
- [x] Set up basic build
- [x] Set up MyST spec test suite
- [x] Get basic C API working
- [x] Expose AST via C API
- [ ] Finish implementing commonmark spec
- [ ] Finish implementing MyST extensions
- [ ] Implement JSON AST parser
- [ ] Add benchmarks
- [ ] Make if faaast. Ditch recursive descent? Data-oriented design?

[aweigh gh]: https://github.com/sinclairtarget/aweigh
[michel gh]: https://github.com/sinclairtarget/michel
[libatrus-go gh]: https://github.com/sinclairtarget/libatrus-go
