---
title: Markdown Features I Didn't Know About
description: Explaining some less commonly used Markdown syntax.
date: 2026-02-23
---
To get some experience using Zig, I thought it'd be fun to build a Markdown
parser. I was feeling ambitious and decided I'd try my hand at making [my
parser](https://github.com/sinclairtarget/libatrus) spec-compliant. I'm now
five months deep into this "fun" side-project and shorn of my naivetë.

It turns out Markdown is complicated. And just... big. In all my years of using
it, I never thought to lookup the official word on what Markdown
can and cannot do. But I wish I had. In my hours and hours of staring
at the [Commonmark
specification](https://spec.commonmark.org/0.30/), I've discovered that there
are many features I'd have found helpful had I just known about them.

Markdown parsers, even the Commonmark-compliant ones, can start to diverge in
behavior as you combine increasingly esoteric syntax in complicated
ways. I've tested the examples below across a few different parsers and these
particular features are broadly supported. (Though not necessarily by syntax
highlighters, you'll notice.)

## Headings ###################################################################
In Markdown, you can create headings using leading `#` symbols:

```{code} markdown
:linenos:
# The foobar Library
## Installation
You can install it by running `brew install foobar`.

## Documentation
Reference documentation is available at [this link](foobar.com/docs).
```

What I didn't know is that this is just one of two different "styles" of
headings that Markdown supports. Headings using `#` symbols are known as
"ATX-style" headings, after [the markup
format](http://www.aaronsw.com/2002/atx/intro) proposed by Aaron Swartz. In
Markdown, you can also use "Setext-style" headings derived from [Structure
Enhanced Text](https://en.wikipedia.org/wiki/Setext).

Setext-style headings look like this:

```{code} markdown
:linenos:
The foobar Library
===
Installation
---
You can install it by running `brew install foobar`.

Documentation
---
Reference documentation is available at [this link](foobar.com/docs).
```

One thing I like about Setext-style headings is that the underline can be as
long as you want it to be. You can use this freedom to
clearly demarcate the various sections in your document:

```{code} markdown
:linenos:
The foobar Library
================================================================================
Installation
--------------------------------------------------------------------------------
You can install it by running `brew install foobar`.

Documentation
--------------------------------------------------------------------------------
Reference documentation is available at [this link](foobar.com/docs).
```

A drawback of the Setext style is that it can only be used to define
`h1` and `h2` headings. If you need deeper levels of subheadings, you have to
use the ATX style and give up on the longer lines. Or so I thought! Because it
turns out you can follow an ATX-style heading with an arbitrary number of
`#` characters, so visually demarcating your sections is still possible:

```{code} markdown
:linenos:
# The foobar Library ###########################################################
## Installation ################################################################
The library is available on Mac OS and Arch Linux.

### Mac OS #####################################################################
Mac OS users can install it by running `brew install foobar`.

### Arch #######################################################################
Arch Linux users can install it from AUR.

## Documentation ###############################################################
Reference documentation is available at [this link](foobar.com/docs).
```

The following is also valid if you don't like the long lines but want an
indicator of depth as you scan down the right-hand side:

```{code} markdown
:linenos:
# The foobar Library                                                           #
## Installation                                                               ##
The library is available on Mac OS and Arch Linux.

### Mac OS                                                                   ###
Mac OS users can install it by running `brew install foobar`.

### Arch                                                                     ###
Arch Linux users can install it from AUR.

## Documentation                                                              ##
Reference documentation is available at [this link](foobar.com/docs).
```

## Blockquotes ################################################################
Did you know that blockquotes can be nested? I've never had occasion to
blockquote somebody blockquoting somebody else, but I'm happy to know that
Markdown would be there for me if I needed to:

```{code} markdown
:linenos:
In her latest newsletter, Sarah explains the virtues of Zig:

> Zig is great and I love it. Like my friend, Bob, says, it's just a joyful
> language to program in. As he describes it:
>
> > How could you not like a language called "Zig"? It just makes me want to
> > zig-ah-zig ah.
>
> How can you argue with that?

I think Sarah has a great point.
```

To show you what this would look like, here's the above rendered by my own
blog:

> In her latest newsletter, Sarah explains the virtues of Zig:
>
> > Zig is great and I love it. Like my friend, Bob, says, it's just a joyful
> > language to program in. As he describes it:
> >
> > > How could you not like a language called "Zig"? It just makes me want to
> > > zig-ah-zig ah.
> >
> > How can you argue with that?
>
> I think Sarah has a great point.

The leading `>` character doesn't have to precede every line of the
blockquote, provided that the blockquote is just one paragraph long:

```{code} markdown
:linenos:
>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis
nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu
fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in
culpa qui officia deserunt mollit anim id est laborum.
```

In the Commonmark spec, the
trailing lines without the `>` are called "lazy continuation lines." If you
want to blockquote multiple paragraphs, you would typically just precede every
line with `>`. But if you're really lazy, this is technically valid:

```{code} markdown
:linenos:
>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis
nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu
fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in
culpa qui officia deserunt mollit anim id est laborum.
>
>Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium
doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore
veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim
ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia
consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt.
```

Finally, any Markdown element can be contained within blockquotes. If you want
to blockquote somebody else's code block, you can:
````{code} markdown
:linenos:
Sarah shows how to write Python on her blog:

> ### Functions that Do Nothing
> In Python, this is an example of a function `foo()` that does nothing:
>
> ```python
> def foo():
>     pass
> ```
>
> Wasn't that exciting?
````

Hugo (really [Goldmark](https://github.com/yuin/goldmark)) can parse this, but
I expected my blog to trip up trying to style the resulting HTML. Surprisingly:

> Sarah shows how to write Python on her blog:
>
> > ### Functions that Do Nothing
> > In Python, this is an example of a function `foo()` that does nothing:
> >
> > ```python
> > def foo():
> >     pass
> > ```
> >
> > Wasn't that exciting?

## Code Fences #################################################################
Like headings, code fences come in two styles. There's the familiar backtick
fence (```` ``` ````), which I've already used above to delimit code blocks.
Delightfully, code blocks can also be delimited with squigglies:

```{code} markdown
:linenos:
In Python, this is an example of a function `foo()` that does nothing:

~~~python
def foo():
    pass
~~~
```

The Commonmark specfication uses the less whimsical name, "tilde fence." As far
as I can see, the tilde fence only exists to make things easier if you want to
use lots of backticks in your code block. But you could also avoid problems
with nested backticks by using a longer line of backticks in the fence (the
block won't close until a fence at least as long as the opening fence is
reached):

`````{code} markdown
:linenos:
This is a Markdown code block demonstrating how to use a backtick fence:

````md
In Python, this is an example of a function `foo()` that does nothing:

```python
def foo():
    pass
```
````
`````

One small thing that clearly distinguishes tilde fences from backtick fences is
that they allow you to use backticks in what's known as the "info string." The
info string follows the opening code fence and is canonically used to specify
the name of the programming language used in the code block. But actually
anything after that first word should be ignored, so with a tilde fence you
could do this:

```{code} markdown
:linenos:
In Python, this is an example of a function `foo()` that does nothing:

~~~python Example of a `foo()` function that does nothing
def foo():
    pass
~~~
```

Adding info strings like the above to your code blocks could help you keep
track of what each code block is meant to demonstrate.

## Autolinks ###################################################################
As long as I've been using Markdown, I've been writing links like this when I
want the link URL to appear as text:

```{code} markdown
:linenos:
I found a cool site the other day.

You can visit it here: [https://foobar.com](https://foobar.com).
```

This works, but there's an easier way: the autolink. The following Markdown is
equivalent to the above:

```{code} markdown
:linenos:
I found a cool site the other day.

You can visit it here: <https://foobar.com>.
```

There's even special support for parsing email addresses as `mailto:` links:

```{code} markdown
:linenos:
I found a cool site the other day.

It's run by my friend Sarah. You can reach her at <sarah@mail.com>.
```

## Hard Line Breaks and HTML Character Entities ################################
If you need to control exactly where line breaks and spacing appear in your
text, Markdown allows you to do that too.

Hard line breaks are inserted when you end a line using a backslash. They render
as a `<br/>` element in HTML.

HTML numeric and character entity references, like `&amp;` or `&#1234;`, are
also valid in Markdown. You can use `&nbsp;` to insert non-breaking spaces.

As a last example, putting these tools together, here's how you can use
Markdown to write poetry:

```{code} markdown
:linenos:
In Xanadu did Kubla Khan\
A stately pleasure-dome decree:\
Where Alph, the sacred river, ran\
Through caverns measureless to man\
&nbsp; &nbsp; Down to a sunless sea.\
So twice five miles of fertile ground\
With walls and towers were girdled round;\
And there were gardens bright with sinuous rills,\
Where blossomed many an incense-bearing tree;\
And here were forests ancient as the hills,\
Enfolding sunny spots of greenery.
```

>In Xanadu did Kubla Khan\
>A stately pleasure-dome decree:\
>Where Alph, the sacred river, ran\
>Through caverns measureless to man\
>&nbsp; &nbsp; Down to a sunless sea.\
>So twice five miles of fertile ground\
>With walls and towers were girdled round;\
>And there were gardens bright with sinuous rills,\
>Where blossomed many an incense-bearing tree;\
>And here were forests ancient as the hills,\
>Enfolding sunny spots of greenery.

## The Future of Markdown ######################################################
The parser I'm working on is meant to be a Commonmark-compliant parser, but
only because Commonmark's syntax is a subset of the syntax I'm actually trying
to support. If everything goes well, sometime in 2029 my parser will support
all of the MyST Markdown spec.

MyST, or [Markedly Structured
Text](https://mystmd.org/guide/quickstart-myst-markdown), adds additional
elements to Markdown that make it easier to extend. MyST also defines an
abstract syntax tree for Markdown documents that makes it possible to parse a
document once and potentially output it as HTML, LaTeX, or anything else later.

I'm excited about MyST. It's intended primarily for scientific publishing, but I
see no reason it couldn't be useful for blog publishing as well. I want to use
my parser to build a static site generator based on MyST. First, though, I'll
need to get it successfully parsing the Markdown document for this blog post,
which believe you me is a real doozy.
