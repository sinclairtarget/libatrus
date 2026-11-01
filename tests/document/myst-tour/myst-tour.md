# MyST Features
Markedly Structured Text, or MyST, is a superset of CommonMark. It adds several
features on top of standard Markdown meant to support technical and scientific
publishing. It also introduces "directives" and "roles", two ways of making
Markdown more extensible that are inspired by ReStructured Text.

This document describes the MyST features supported by `libatrus`.

## Comments
In MyST, any line beginning with a `%` symbol is a comment. Comments aren't
visible to readers. (Though that doesn't mean they are completely hidden. When
rendering to HTML, for example, comments are turned into HTML comments, which
can still be read if someone inspects the source for a web page.)

This is an example of a comment:

% Hi, I am a comment!
I am regular paragraph text.

## Blocks
A MyST document can be separated into one or more "blocks". Each block can have
metadata attached to it. Blocks are a way to break your document into different
parts at the top-most structural level.

You begin a new block with a line containing three or more `+` symbols. The
symbols can be followed by an inline JSON document with arbtitrary keys and
values.

This is the first block in the document.

+++ {"name": "foo"}

Now we're on the second block in the document.

## Directives
Directives are a way of adding new kinds of constructions to Markdown without
adding any new syntax. Directives should be used why you want to include
multiple lines of content in the new construction.

### Generic Syntax
A directive looks like this:

```{foobar} bim bam
:zips: 4
:zaps: enough
This is my content.

It goes on for many lines.
```

Here we've used `` ` `` as a code fence, but you can also use `:`, which makes
more sense when the directive includes nested Markdown content. (This makes no
difference to the MyST parser, but if your MyST document gets read by a normal
Markdown parser, using `:` for your directives ensures that the nested Markdown
still gets parsed.)

The name of the directive is enclosed in curly braces immediately following the
code fence. Anything on the same line after the curly braces is considered to
be the "argument" to the directive.

Within the fenced block, the first lines can start with an option name enclosed
by `:` followed by an option value. These are like named arguments to the
directive.

Finally, everything following the last option until the end of the fenced block
constitutes the directive's value or body.

Unless a directive is specially handled by `libatrus` (see the next section),
it will get rendered as an "unhandled directive." Applications should either
transform custom directives into other nodes before rendering or else override
rendering for the custom directive.

### Built-in Directives
MyST includes several built-in directives. These are required by the MyST
specification and are implemented in `libatrus`.

#### Admonitions
An admonition is block of text that calls special attention to something.

A basic admonition looks like this: 

:::{admonition} Pay Attention!
You need to understand this.
:::

There are also ten other kinds of admonition that you can use by varying the
directive name. Some examples are `{note}`, `{hint}`, `{warning}`, and
`{danger}`.

The directive argument is used as a title for the admonition element when
rendered. If none is given, then the admonition kind is used as the title
instead.

#### Code Blocks
The `{code}` directive introduces a code block that behaves similarly to a
regular Markdown code block but with added options.

Here is an example of a `{code}` directive:

```{code} python
:linenos:
:filename: run.py
def foo():
    pass
```

The directive argument is used to establish the programming language for the
code block. Here, we've used two options to specify we want to render this code
block with lines numbers and a filename of `run.py`.

Other valid options for code blocks are `:emphasize-lines:`, which specifies
one or more lines (or a range of lines) to be highlighted, and
`:lineno-start:`, which establishes the starting line number.

#### Images
The `{image}` directive, like the `{code}` directive, behaves similarly to the
existing Markdown image syntax but allows for added options.

Here is an example of an `{image}` directive:

```{image} cat.jpg
:alt: Funny cat.
:width: 200px
:align: center
```

The directive argument is used as the URL for the image. The `alt` option
allows for specifying alt text for the image. The `:width:` and `:align:`
options are available for controlling the size and placement of the image.

#### Figures
The `{figure}` directive is similar to the `{image}` directive except it allows
for an associated caption. The caption appears in the body of the directive.

:::{figure} cat.jpg
:alt: Funny cat.
This is my funny cat!
:::

The `{figure}` directive supports the same set of options as the `{image}`
directive.

#### Math
A `{math}` directive contains LaTeX-style math. No unique options are
supported.

Here is an example:

```{math}
y = mx + b 
```

#### Tables
Tables can be written in MyST as they are written in Github-flavored Markdown.
But there is also a `{list-table}` directive that can be used to create tables
from bullet lists.

Here is an example:

:::{list-table} Starter Pokemon
:header-rows: 1
:align: center
* * Pokemon
  * Type
* * Pikachu
  * Electric
* * Squirtle
  * Water
* * Bulbasaur
  * Grass
:::

For the `{list-table}` directive, the directive argument, if provided, is used
as a caption for the table. The `:align:` option sets the alignment of the
entire table. The `:header-rows:` option describes how many of the leading rows
should be considered header rows.

### Common Options
Though generally the supported options for each directive depend on the
directive, there are some common options that apply to all built-in directives.

Every directive can have either a `:name:` or a `:label:` option. This sets the
target ID for the directive so that it can be cross-referenced.

Every directive can have a boolean `:enumerated:` option determining whether
the directive should be given an enumartion value when cross-referenced.

Finally, every directive can also have a `:class:` option. This has no inherent
meaning but can be used to add custom styling once the directive has been
rendered.

### Errors
Sometimes a directive can be well-formed but invalid. This could happen if, for
example, a directive argument is of the wrong type.

If a directive is invalid, it is replaced in the MyST document by a directive
error, which includes an error message. Note that parsing of the MyST document
still completes successfully.

The following is an invalid use of the `list-table` directive and will produce
a directive error:

```{list-table}
* - Foo
  - Bar
* - 1
  - 2
  - 3
```

## Roles
Roles are similar to directives. They are a way of adding new constructions to
Markdown without adding any new syntax. But unlike directives they should apply
only to content appearing within a single line.

### Generic Syntax
A role looks like this: {foobar}`bim bam`.

THe role name is given in curly braces and the role value is given between
backticks following the curly braces.

Roles do not have arguments or options.

Unless a role is specially handled by `libatrus` (see the next section), it
will get rendered as an "unhandled role." Applications should either transform
custom roles into other nodes before rendering or else override rendering for
the custom role.

### Built-in Roles
MyST includes several built-in roles. These are required by the MyST
specification and are implemented in `libatrus`.

#### Abbreviations
The `{abbr}` role allows you to use an acronym and provide an expansion of the
acronym as optional content for the reader (the exact mechansim depends on the
render format).

Here is an example of the `{abbr}` role:

{abbr}`MyST (Markedly Structured Text)` is a great time!

As you can see, the expansion goes within parentheses following the acronym.

#### Subscript
The `{sub}` role indicates that the associated value should be treated as
subscript: CO{sub}`2`.

#### Superscript
The `{sup}` role indicates that the associated value should be treated as
superscript: 44{sup}`th` president.

#### Math
The `{math}` role indiciates that the associated value contains LaTeX math:
{math}`y = mx + b`.

#### References
There are two roles for cross-referencing that are covered in the section below
on references.

### Errors
Like with directives, if a role is well-formed but invalid then it is replaced
in the document with a role error (usually including an error message). Parsing
still completes successfully.

## Cross References
MyST supports a system for creating "rich" references to other parts of a
document or even to entirely different documents.

### Targets
For something to be the target of a cross reference, it must have a label. You
can give a label to something in a few different ways depending on whether that
something is a directive or not.

A directive can be labeled using either the `:label:` or `:name:` options. (The
`:label:` option takes precedence if both are specified.) Otherwise, you assign
a label by putting the label on the immediately preceding line using special
syntax.

Here is an example of a labeled heading:

(my-example-heading)=
#### My Example Labeled Heading

Labels can be given to headings, paragraphs, lists, blockquotes, or pretty much
any element that isn't an inline element.

### Referencing
You create a cross reference using Markdown's regular link syntax (and URL
fragments) or either the `{ref}`, `{numref}`, or `{eq}` role. Using the regular
link syntax establishes a cross reference with default behavior that varies
depending on the type of element targeted. Using the roles gives you greater
control over the cross reference.

The `{ref}` role establishes a cross reference that does not use any
enumeration value. Writing just {ref}`my-example-heading` establishes a cross
reference to the above heading that automatically fills in the link text based
on the heading. This is equivalent to [](#my-example-heading). Writing
{ref}`the above heading <my-example-heading>`, with the label given in angle
brackets, establishes a link using "the above heading" as the link text. This
is equivalent to [the above heading](#my-example-heading).

The `{numref}` role is similar but allows you to make use of the target's
enumeration value in the link text using `%s`. The reference will not resolve
(see below) if the target element is not enumerated. Here is an example of
using the `{numref}` role:

:::{figure} plot.png
:label: my-plot
Look at the curves on that distribution!
:::

Here is a reference to the above figure: {numref}`Plot %s <my-plot>`.

Finally there is the `{eq}` role, which establishes a reference to a `{math}`
directive. The only valid value for an `{eq}` role is the label for a `{math}`
directive. Here is an example:

```{math}
:label: super-formula
y = x^2
```

Take a look at {eq}`super-formula`!

### Resolution
The cross references in a MyST document are initially unresolved, meaning that
they are not yet connected to their targets. Resolution is one of the last
transformations applied to a MyST document before it is rendered.

When the `{ref}`, `{numref}`, and `{eq}` roles are used for cross referencing
and the reference is unresolved, it will be rendered as an unresolved cross
reference. Using the Markdown link syntax for cross references instead means
that an unresolved cross reference just gets rendered as a broken link.

Here is an unresolved reference: {ref}`This goes nowhere <not-a-thing>`.

Cross references within a single MyST document are handled by `libatrus`. To
cross reference to targets within other documents, you must supply the valid
universe of targets for a given document to `libatrus` when calling `resolve()`
on the document.
