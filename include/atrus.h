/*
 * This file defines the public C-ABI-compatible interface of libatrus.
 *
 * Usage of this library typically involves:
 *   1) Creating an AST using `atrus_parse()`.
 *   2) Traversing or manipulating the tree if you need to.
 *   3) Rendering the tree using one of the render functions.
 *
 * Functions for parsing and rendering are defined below under the "Top-Level
 * API" divider. Functions for traversing and manipulating the tree are defined
 * under the "Node API" divider.
 *
 * The caller is responsible for managing the lifetime of the AST as a whole
 * (and the lifetime of any nodes or trees not attached to the main AST). In
 * all other cases, data is owned by the library. Any string values attached to
 * the tree, for example, will always be cleaned up by the library and are not
 * the responsibility of the caller, even when they are returned by one of the
 * Node API accessor functions.
 */
#ifndef ATRUS_H
#define ATRUS_H

#include <stdbool.h>

// Compile-time version.
#define ATRUS_MAJOR_VERSION 0
#define ATRUS_MINOR_VERSION 7
#define ATRUS_PATCH_VERSION 0

/*
 * Reports the link-time version of the library.
 */
const char* atrus_version();

/*
 * Returns true if the linked version of libatrus is at least as new as the
 * given version.
 */
bool atrus_version_at_least(int major, int minor, int patch);

// Opaque node type.
struct atrus_node;

// ----------------------------------------------------------------------------
// Top-Level API
// ----------------------------------------------------------------------------
typedef enum : unsigned int {
    ATRUS_PARSE_LEVEL_POST = 0,
    ATRUS_PARSE_LEVEL_PRE = 1,
    ATRUS_PARSE_LEVEL_RAW = 2,
    ATRUS_PARSE_LEVEL_BLOCK = 3,
} atrus_parse_option_parse_level_t;

typedef enum {
    ATRUS_PARSE_SUCCESS = 0,
    ATRUS_PARSE_READ_FAILED = -1,
    ATRUS_PARSE_OTHER_ERROR = -2,
} atrus_parse_error_t;

/*
 * Given a null-terminated string containing MyST markdown, parses it into a
 * MyST AST. Returns 0 on success or a negative number on error.
 *
 * The caller is responsible for freeing the AST using `atrus_free()`.
 */
atrus_parse_error_t atrus_parse(
    const char* in,
    struct atrus_node** out,
    atrus_parse_option_parse_level_t parse_level
);

/*
 * Given a MyST AST, renders the tree as HTML into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_html(struct atrus_node* root, char** out);

typedef enum : unsigned int {
    ATRUS_JSON_MINIFIED = 0,
    ATRUS_JSON_INDENT_2 = 1,
    ATRUS_JSON_INDENT_4 = 2,
} atrus_json_option_whitespace_t;

/*
 * Given a MyST AST, renders the tree as JSON into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_json(
    struct atrus_node* root,
    char** out,
    atrus_json_option_whitespace_t whitespace
);

/*
 * Give a MyST AST, renders the tree as Typst markup into a null-terminated
 * string. Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_typst(struct atrus_node* root, char** out);

typedef enum {
    ATRUS_LOAD_SUCCESS = 0,
    ATRUS_LOAD_FAILURE = -1,
} atrus_load_error_t;

/*
 * Given a null-terminated JSON string, attempts to parse the JSON string into
 * a MyST AST. Returns 0 on success or a negative number on error.
 *
 * The caller is responsible for freeing the returned AST using `atrus_free()`.
 */
atrus_load_error_t atrus_load_json(
    const char* in,
    struct atrus_node** out
);

/*
 * Frees the given AST recursively.
 */
void atrus_free(struct atrus_node* root);

// ----------------------------------------------------------------------------
// Node API
// ----------------------------------------------------------------------------
typedef enum : unsigned int {
    ATRUS_NODE_TYPE_ROOT = 0,
    ATRUS_NODE_TYPE_BLOCK = 1,
    ATRUS_NODE_TYPE_HEADING = 2,
    ATRUS_NODE_TYPE_PARAGRAPH = 3,
    ATRUS_NODE_TYPE_TEXT = 4,
    ATRUS_NODE_TYPE_CODE = 5,
    ATRUS_NODE_TYPE_THEMATIC_BREAK = 6,
    ATRUS_NODE_TYPE_BREAK = 7,
    ATRUS_NODE_TYPE_EMPHASIS = 8,
    ATRUS_NODE_TYPE_STRONG = 9,
    ATRUS_NODE_TYPE_INLINE_CODE = 10,
    ATRUS_NODE_TYPE_LINK = 11,
    ATRUS_NODE_TYPE_DEFINITION = 12,
    ATRUS_NODE_TYPE_IMAGE = 13,
    ATRUS_NODE_TYPE_BLOCKQUOTE = 14,
    ATRUS_NODE_TYPE_HTML = 15,
    ATRUS_NODE_TYPE_CONTAINER = 25,
    ATRUS_NODE_TYPE_CAPTION = 26,
    ATRUS_NODE_TYPE_MYST_ROLE = 16,
    ATRUS_NODE_TYPE_MYST_ROLE_ERROR = 17,
    ATRUS_NODE_TYPE_SUBSCRIPT = 18,
    ATRUS_NODE_TYPE_SUPERSCRIPT = 19,
    ATRUS_NODE_TYPE_ABBREVIATION = 20,
    ATRUS_NODE_TYPE_MYST_DIRECTIVE = 21,
    ATRUS_NODE_TYPE_MYST_DIRECTIVE_ERROR = 22,
    ATRUS_NODE_TYPE_ADMONITION = 23,
    ATRUS_NODE_TYPE_ADMONITION_TITLE = 24,
} atrus_node_type_t;

/*
 * Returns the node type of the given node.
 */
atrus_node_type_t atrus_node_type(struct atrus_node* node);

/*
 * Returns the node type of the given node as a camel-cased string.
 */
const char* atrus_node_type_name(struct atrus_node* node);

/*
 * Returns the number of children the node has.
 *
 * If the node type is always a leaf node, just returns zero.
 */
unsigned int atrus_node_num_children(struct atrus_node* node);

/*
 * Gets an opaque pointer to the ith child of the given node.
 *
 * If the index is out of bounds, this function panics.
 */
struct atrus_node* atrus_node_child(struct atrus_node* node, unsigned int i);

/*
 * Replaces the ith child with a new node.
 *
 * The AST takes ownership of the new child.
 */
void atrus_node_replace_child(
    struct atrus_node* node,
    unsigned int i,
    struct atrus_node* new_child_node
);

/*
 * The below functions operate on a node of a particular type.
 *
 * If a function is used on a node of the wrong type, the function will panic.
 *
 * The `atrus_node_*_create()` functions create a node owned by the caller. If
 * the node is later made a child of an existing node, then the node becomes
 * owned by its parent. All values passed into an `atrus_node_*_create()` will
 * be copied and the copies will be owned by the node.
 */

typedef enum {
    ATRUS_NODE_CREATE_SUCCESS = 0,
    ATRUS_NODE_CREATE_ERROR = -1,
} atrus_node_create_error_t;

// --- Root -------------------------------------------------------------------
atrus_node_create_error_t atrus_node_root_create(struct atrus_node** out);

// --- Block ------------------------------------------------------------------
atrus_node_create_error_t atrus_node_block_create(struct atrus_node** out);

// --- Heading ----------------------------------------------------------------
unsigned short atrus_node_heading_depth(struct atrus_node* node);

atrus_node_create_error_t atrus_node_heading_create(
    struct atrus_node** out,
    unsigned int depth
);

// --- Paragraph --------------------------------------------------------------
atrus_node_create_error_t atrus_node_paragraph_create(struct atrus_node** out);

// --- Text -------------------------------------------------------------------
const char* atrus_node_text_value(struct atrus_node* node);

atrus_node_create_error_t atrus_node_text_create(
    struct atrus_node** out,
    const char* value
);

// --- Code -------------------------------------------------------------------
const char* atrus_node_code_value(struct atrus_node* node);
const char* atrus_node_code_lang(struct atrus_node* node);
bool atrus_node_code_show_line_numbers(struct atrus_node* node);
const char* atrus_node_code_filename(struct atrus_node* node); // can be null
// copies no more than len line numbers to dest, returning the number copied
size_t atrus_node_code_emphasize_lines(
    struct atrus_node* node,
    unsigned int* dest,
    size_t len
);

atrus_node_create_error_t atrus_node_code_create(
    struct atrus_node** out,
    const char* value,
    const char* lang,
    bool show_line_numbers
);

// --- Thematic Break ---------------------------------------------------------

// --- Break ------------------------------------------------------------------

// --- Emphasis ---------------------------------------------------------------

// --- Strong -----------------------------------------------------------------

// --- Inline Code ------------------------------------------------------------
const char* atrus_node_inline_code_value(struct atrus_node* node);

atrus_node_create_error_t atrus_node_inline_code_create(
    struct atrus_node** out,
    const char* value
);

// --- Link -------------------------------------------------------------------
const char* atrus_node_link_url(struct atrus_node* node);
const char* atrus_node_link_title(struct atrus_node* node);

atrus_node_create_error_t atrus_node_link_create(
    struct atrus_node** out,
    const char* url,
    const char* title
);

// --- Link Definition --------------------------------------------------------
const char* atrus_node_definition_url(struct atrus_node* node);
const char* atrus_node_definition_title(struct atrus_node* node);
const char* atrus_node_definition_label(struct atrus_node* node);

atrus_node_create_error_t atrus_node_definition_create(
    struct atrus_node** out,
    const char* url,
    const char* title,
    const char* label
);

// --- Image ------------------------------------------------------------------
const char* atrus_node_image_url(struct atrus_node* node);
const char* atrus_node_image_title(struct atrus_node* node);
const char* atrus_node_image_alt(struct atrus_node* node);

atrus_node_create_error_t atrus_node_image_create(
    struct atrus_node** out,
    const char* url,
    const char* title,
    const char* alt
);

// --- Blockquote -------------------------------------------------------------

// --- HTML -------------------------------------------------------------------
const char* atrus_node_html_value(struct atrus_node* node);

atrus_node_create_error_t atrus_node_html_create(
    struct atrus_node** out,
    const char* html_value
);

// --- Container --------------------------------------------------------------
const char* atrus_node_container_kind(struct atrus_node* node);

// --- Caption ----------------------------------------------------------------

// --- MyST Role --------------------------------------------------------------
const char* atrus_node_myst_role_name(struct atrus_node* node);
const char* atrus_node_myst_role_value(struct atrus_node* node);

// --- MyST Role Error --------------------------------------------------------
const char* atrus_node_myst_role_error_value(struct atrus_node* node);

// --- Subscript --------------------------------------------------------------

// --- Superscript ------------------------------------------------------------

// --- Abbreviation -----------------------------------------------------------
const char* atrus_node_abbreviation_title(struct atrus_node* node);

// --- MyST Directive ---------------------------------------------------------
const char* atrus_node_myst_directive_name(struct atrus_node* node);
const char* atrus_node_myst_directive_args(struct atrus_node* node);
const char* atrus_node_myst_directive_value(struct atrus_node* node);

// --- MyST Directive Error ---------------------------------------------------
const char* atrus_node_myst_directive_error_message(struct atrus_node* node);

// --- Admonition -------------------------------------------------------------
const char* atrus_node_admonition_kind(struct atrus_node* node);

// --- Admonition Title -------------------------------------------------------

#endif
