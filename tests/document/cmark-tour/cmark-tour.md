Markdown exists because these two things are true: First, structured text is
more useful than unstructured text, and second, structured text is harder for
humans to read and write. Markdown is an attempt to make it possible to write
structured text in a format that looks unstructured, so that humans can read
and write it comfortably.

What do we mean by "structured text"? When we process a text document with a
computer program, there are many things we might want to do with that text that
require understanding how different parts of the document relate to one
another. For example, if we are rendering the document to a screen, we might
want to show headings in a larger font size than everything else. Or, if we are 
compiling a bibliography, we might want to list out all the citations that
appear within the main body of the document. For a computer program to do these
things for us, it needs to know which parts of the text document are headings
and which parts are citations. 

The most straightforward way to communicate this structure to a computer
program is to "mark up" our text with tags. This is the approach taken by
markup languages like HTML (Hypertext Markup Language) and XML (Extensible
Markup Language). The nice thing about tags is that they are predictable and
consistent; it is relatively simple to write a program that can look for an
opening tag and then a closing tag and associate the text in between with that
tag. But tags also clutter a text document, making it harder to read. And
having to add tags as you write a document is a tedious chore. 

What if, rather than relying on explicit tags, we tried to use some of the
existing conventions that humans already have for visually communicating
structure in a text document? Humans already separate paragraphs from each
other with whitespace, already distinguish headings by underlining them,
already write lists using bullet points. Can we write a computer program smart
enough to glean structure from these visual patterns instead, freeing humans
to read and write more naturally?

That is what Markdown tries to do. Markdown is a large set of rules governing
how structure can be derived from these natural patterns in text and (a few
explicit tag-like constructs for when the natural patterns aren't sufficient).
The set of rules is large because recognizing these natural patterns in a text
document is much more complicated than just looking for tags. This is a
drawback of Markdown: Writing a program to read Markdown is challenging. But
writing a Markdown document, for humans, is easy. And once you have a program
that can read Markdown, you can convert your document to other, more
machine-friendly formats programmatically.

This document is written using Markdown. Let's explore what Markdown allows us
to do. Markdown allows us to do more than most people probably realize.

So far, this document has consisted of a series of paragraphs. Markdown knows
they are separate paragraphs because they are separated by blank lines.
We can
write sentences across 
several lines like this,
but Markdown will still consider it all part of the same paragraph if
there is no blank line.

We could also choose to write one sentence per line.
This is something that I've heard is popular.
The sentences could even be really long, like this one, which just goes on, and it doesn't matter.
In Markdown, unless there's a blank line, it will all be the same paragraph.
You can rely on the wrapping feature in your editor to manage the long lines.

Note that starting a line with an indent is not sufficient to open a new
paragraph.
	This line starts with a tab character, but is still considered the second
sentence in this paragraph.

If for some reason we include multiple blank lines between paragraphs, this is
no different than including a single blank line. The extra blank lines are
ignored.



See?

If Markdown ignores extra blank lines, then does that mean it's impossible to
force a bunch of blank lines to appear in the output? No! If Markdown sees a
line that ends with a backslash, it treats that as something it calls a hard
break. Hard breaks give you control over exactly where line endings should be
and allow you to force blank lines to appear in the output.

Here\
you see some lines\
including some blank ones\
\
\
ending in hard breaks.

Hard breaks would be very useful if you were trying to write poetry.

Okay, let's add some more structure to this document so that it's not just one
big soup of paragraphs. Let's discuss headings.

Setext Headings
===============
In Markdown, there are two different ways to indicate that something should be
a heading. The first way, known as the Setext-style heading, involves what we
might otherwise do naturally: underlining the heading.

The underline can be written using "=" or "-" characters. A heading underlined
with "=" characters is considered a level-one heading, while a heading
underlined with "-" characters is considered a level-two heading. The underline
must consist of three or more characters to be valid, but otherwise can include
as many characters as you'd like.

# ATX Headings
The other way to indicate headings is known as the ATX style. To create an
ATX-style heading, you precede your heading with up to six "#" characters. The
number of characters indicates the level of the heading.

The ATX heading is less natural than the Setext heading but has the advantage
that it supports headings up to level six. That's why we'll use it for the rest
of this document.

If you aren't using syntax highlighting in your editor, another disadvantage of
ATX-style headings is that they stand out less than Setext-style headings from
regular paragraphs. A little-known fact though is that you can include as many
'#' characters as you want after your heading on the same line, so writing a
heading like this is completely valid and makes scanning your document easier:

# Example Heading #############################################################

Okay, let's move on from headings to another useful way of splitting up your
document.

# Thematic Breaks
Sometimes you want to mark a transition in your document without categorizing
each part under a separate heading. You can use a thematic break for this. A
thematic break looks like:

* * *

This is very similar to what you might see printed in a novel. But you can get
more creative with your thematic breaks if you like. You can use "*"
characters, "-" characters, or "_" characters, as long as there are at least
three of them. You can include whitespace between the characters or on either
side. So this is also a valid thematic break:

   --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- 

For reasons we'll discuss in the next section, you can't include more than
three spaces at the beginning of the line.

# Code
Sometimes, especially in the world of software development, we want to include
code listings in our documents. We want this to be part of the known structure
of our document because in the final rendered version it's very helpful to
human readers if we can show all code in a monospace font while keeping the
main body text in a regular, variable-width font.

The situation with code in Markdown is similar to the situation with headings.
There are two ways to include code listings in a Markdown document, one of
which is maybe more natural while the other is a little less natural but also
more powerful.

The first way to include a code listing in a Markdown document is to indent
your code four spaces:

    def foo():
        print("Hello, world!")

This is easy and very natural for human authors. But it also means you have to
be careful not to start any line with more than three spaces worth of
indentation.

    Even this line, which doesn't look anything like code, will be treated as
    code in Markdown because it is indented by four spaces.

It can also be easy to indent your code too far and end up with extra spaces at
the beginning of each line in your code listing. It can be hard to spot this
when you've done it.

A more artificial but perhaps less ambiguous way of specifying a code listing
is to write it like this:

```
def foo():
    print("Hello, world!")
```

A line starting with three or more backticks is called a "code fence."
Everything between two code fences is treated as code.

One nice advantage of using code fences is that you can note the language the
code is written in by including it after the first code fence:

```python
def foo():
    print("Hello, world!")
```

This would be useful if you later plan to add syntax highlighting to your code
listings.

# HTML
Markdown is often used to write documents that are later converted into HTML.
Because of this tight link between Markdown and HTML, Markdown allows you to
include HTML directly in your document:

<div foo="bar">
  <p>Look, this is an HTML paragraph!</p>
</div>

You can also put Markdown inside of an HTML element:

<div foo="bar">
  This is a regular paragraph.

  ```python
  def foo():
     print("Hello, world!")
  ```
</div>

This might be very useful if you always plan to convert your document to HTML.
It gives you the option of resorting to explicit mark up when you need it. But
be aware that if you render your Markdown document into a format other than
HTML there may not be a natural representation of HTML in your target format.

# Lists
We often need to make lists of things. Markdown supports both bullet lists and
numbered lists.

## Bullet Lists
Bullet lists work pretty much exactly the way you'd expect them to:

* First item
* Second item
* Third item

If you aren't a fan of the asterisk, you can also use "+" or "-":

- First item
- Second item

+ First item
+ Second item

What if you want your bullet-point list items to be longer? In Markdown, you
can include multiple paragraphs in a single list item, but you have to be
careful to line up the indentation:

* Here is a long list item. It goes on for multiple sentences. In fact the
  sentences are so many that there are even multiple paragraphs.

  A blank line separates the paragraphs. But this paragraph is still part of
  the first list item, since it's indented to match the paragraph above.
* This is a new paragraph in the second list item.

You can even have sublists. You don't have to use a separate character for your
bullets in the sublist, but it might make it easier to read:

* This is a normal list item.
* This list item contains a sublist:

  + Juice
  + Milk
  + Eggs
  + Strawberries

As you can see, bullet lists are very natural to write in Markdown.

## Numbered Lists
Numbered lists work similarly to bullet lists, but there are a few hidden
gotchas.

1. This is the first item of a numbered list.
2. This is the second item.
3. This is the third.

You don't have to start a numbered list with "1":

7. This list starts with seven for some reason.
8. This is the eighth list item.

But note that you can only control the number used to start the list. The
list items after the first are always numbered sequentially from the starting
number, no matter what you've written:

4. This is the fourth item.
7. This might look like the seventh item, but it will actually be numbered as
   fifth.
1. This will be numbered as sixth.

If you'd like, you can also write numbered lists this way, using a ")" after
the number:

1) This is the first item.
2) This is the second.
3) This is the third.

Though it's unlikely to come up often, one thing to be careful of in Markdown
is starting a line with a "1." or "1)". This will always be interpreted as the
start of a list, even if you may not mean it that way. For example:

I asked my old friend when I should come over for the party. He said to come at
1. I said that sounded good.

The same thing will not happen if you use any number other than 1.

# Blockquotes
This is a useful one! You can quote someone else at length using blockquotes.
To create a blockquote, just precede each line with a ">" character:

> This other person said this thing. It was very wise and had great insight
> into pressing contemporary problems.

You can include anything in a blockquote, including headings, code, lists, or
even other blockquotes:

> This is a quote with some nested elements.
> 
> > # Nested Blockquote
> > ```python
> > def foo():
> >     print("Hello, world!")
> > ```
> 
> Isn't that neat?

# Inline Elements
So far, we've only talked about what are known in Markdown as "block" elements.
These are structures in our document that apply to one or more lines of text.

Markdown also supports many ways to add structure within paragraphs of text.
These are known as "inline" elements in Markdown.

## Emphasis
You can apply emphasis to some text by either surrounding it with "*"
characters or surrounding it with "_" characters.

In this _paragraph_, *for example*, we've emphasized "paragraph" and "for
example."

If you want to emphasize only part of a word rather than the whole word, you
can do that like this: em*pha*size. You can only do this when marking emphasis
using asterisks rather than underlines.

### Strong Emphasis
You can emphasize things even more strongly using strong emphasis. Depending on
how you later render your Markdown document, this usually produces bolded text.

To emphasize **strongly**, you just __double up__ the characters.

## Code
You can mark some text in a paragraph as code by surrounding it in backticks.
You might want to mention a function `foo()` in your paragraph, or a variable
`bar`.

## Links
In Markdown, it's possible to indicate that some text should link to an
external resource. For example, this is a link to [Google](https://google.com).
You surround the text with square brackets and then include a URL in
parentheses following the text.

URLs can get very long, which could make your document harder to read if you
have lots of links. Markdown allows you to define the URL using a shorthand
name that you can then reference when you apply the link to some text in your
document. So instead of linking to Google like we did above, we could do this:

[google homepage]: https://google.com

This is a [link to Google][google homepage].

This time, the URL in parentheses is replaced by the shorthand name in square
brackets.

Note that the definition of the shorthand name does not have to come before the
link. You could put it at the bottom of your document if you wanted to, which
is probably tidiest!

### Autolinks
If you ever want to include a link in your document where the text of the link
is just the URL, Markdown has a special syntax for that: <https://google.com>.

## Images
You can include images in your document using a syntax very similar to the
syntax for links. The following includes the image at `https://foo.com/bar.jpg`
in the document:

![an exemplary bar](https://foo.com/bar.jpg)

The text between the square brackets is used as the alt text for the image.

## HTML
Finally, if you need to, you can include <span class="bim">inline html</span>
within paragraphs. This has all the advantages and disadvantages of block-level
HTML.
