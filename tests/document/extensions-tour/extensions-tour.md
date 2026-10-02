# Markdown Extensions
MyST Markdown includes support for a few features that, while not part of
CommonMark, are often implemented in Markdown parsers.

## Github-Flavored Markdown Tables
In MyST Markdown, you can create a table using a directive. But you can also
create a table the same way you might do so on Github, using the
Github-Flavored Markdown syntax for tables.

Here is an example of a table created using this syntax:

| Student | Height |
| ------- | ------ |
| John    | 5'9"   |
| Sarah   | 5'6"   |
| Sally   | 5'2"   |
| Bill    | 6'2"   |

The divider row with all the hyphens cannot be omitted. It does not matter how
many hyphens you put in each column in that row as long as there is at least
one in each column.

The pipe characters on the outside of the table are not strictly necessary.
This is still a valid table:

Student | Height
------- | ------
John    | 5'9"  
Sarah   | 5'6"  
Sally   | 5'2"  
Bill    | 6'2"  

By default, the content of all cells is left-aligned. To change the alignment
for a given column, you can include a colon either at the beginning or end of
the line of hyphens in the divider row for that column. A single colon at the
end means to right-align, while a single colon at the beginning means to
left-align. A colon at both the beginning and the end means to center-align.

In the following table, the "Height" column is center-aligned while the "Age"
column is right-aligned.

| Student | Height | Age | 
| ------- | :----: | --: |
| John    | 5'9"   | 17  |
| Sarah   | 5'6"   | 18  |
| Sally   | 5'2"   | 17  |
| Bill    | 6'2"   | 17  |

Finally, table cells can include inline content of any kind (e.g. emphasis,
links, or inline HTML):

| Student                        | Height | Age | 
| ------------------------------ | :----: | --: |
| *John*                         | 5'9"   | 17  |
| Sarah                          | 5'6"   | 18  |
| [Sally](https://sally.com)     | 5'2"   | 17  |
| <span class="name">Bill</span> | 6'2"   | 17  |

## Pandoc Footnotes
Using plain CommonMark, there's no easy method to add footnotes to a document.
You might be able to get away with creating footnotes using inline links, but
you'd have to manually number all the footnotes and they wouldn't use
superscript for the numbers.

MyST Markdown supports creating footnotes using the Pandoc syntax for
footnotes. To create a footnote, you need to define the footnote and then
reference it using the same label.

A footnote definition looks a little bit like a link definition except with a
caret before the label:

[^my-footnote]: This is my footnote! It can contain block and *inline markup*
    and it goes on for as many lines as I'd like.

    If I want to begin a new block within the footnote though, I have to
    indent it by at least four spaces.

    ```python
    def foo():
        pass
    ```

    This is now the last line of the footnote!

To reference the definition, you simply use the label where you want the
superscript number to appear.[^my-footnote]

The label `my-footnote` is just a placeholder and will never appear in the
final rendered document. Instead, footnotes will be assigned numbers based on
the order in which they are first referenced in the document. It does not
matter where the footnote is defined. (And you can even place the definition
after the reference if you want to. It's quite natural to put all the
definitions at the very bottom of the document.)

If you want to force a footnote to use a certain number, you can do that by
using the number as the label.[^4]

[^4]: This is footnote four, even though there are only two footnotes in this
    document!
