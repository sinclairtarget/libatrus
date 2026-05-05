/*
 * This file defines the public C-ABI-compatible interface of libatrus.
 *
 * There are two representations of the MyST AST declared below. Each is
 * designed to fulfill a different use case.
 *
 * If you don't need direct access to the AST, you should use the opaque
 * pointer representation of the AST (`struct atrus_node_opaque`). All the
 * available functions of the libatrus API accept and return the AST using this
 * opaque pointer type. If you restrict yourself to using the opaque pointer,
 * your usage of libatrus will be forward-compatible with new versions of the
 * library that make changes to the AST.
 *
 * If you need to access fields in the AST or modify the AST, then you will
 * have to use the exposed representation of the AST. To turn an opaque pointer
 * into a pointer to the exposed AST node type, you must call `atrus_expose()`.
 * There is some overhead incurred here because this creates a copy of the AST
 * with a C-ABI-compatible layout (though any pointers to strings from the
 * underlying MyST document are preserved and do not need to be copied). To
 * turn the exposed AST back into an opaque pointer, you must call
 * `atrus_adopt()`. New versions of libatrus are not guaranteed to have
 * backward ABI-comptability, so if you are using the exposed AST
 * representation it is a good idea to link libatrus statically or check for a
 * particular version of the library at runtime.
 */
#ifndef ATRUS_H
#define ATRUS_H

#include <stdbool.h>

extern const char* const atrus_version;

// ----------------------------------------------------------------------------
// Basic Atrus API (Opaque AST)
// ----------------------------------------------------------------------------
struct atrus_node_opaque;

typedef enum : unsigned int {
    ATRUS_POST_PARSE_LEVEL = 0,
    ATRUS_PRE_PARSE_LEVEL = 1,
    ATRUS_RAW_PARSE_LEVEL = 2,
    ATRUS_BLOCK_PARSE_LEVEL = 3,
} atrus_parse_option_parse_level_t;

// Options for MyST markdown parsing.
struct atrus_parse_opts {
    atrus_parse_option_parse_level_t parse_level;
};

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
    struct atrus_node_opaque** out,
    const struct atrus_parse_opts* options
);

/*
 * Retuns the camel-cased type name for the given node.
 */
const char* atrus_name(struct atrus_node_opaque* node);

/*
 * Frees the given AST recursively.
 */
void atrus_free(struct atrus_node_opaque* root);

/*
 * Given a MyST AST, renders the tree as HTML into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_html(struct atrus_node_opaque* root, char** out);

typedef enum : unsigned int {
    ATRUS_JSON_MINIFIED = 0,
    ATRUS_JSON_INDENT_2 = 1,
    ATRUS_JSON_INDENT_4 = 2,
} atrus_json_option_whitespace_t;

// Options for JSON rendering.
struct atrus_json_opts {
    atrus_json_option_whitespace_t whitespace;
};

/*
 * Given a MyST AST, renders the tree as JSON into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_json(
    struct atrus_node_opaque* root,
    char** out,
    const struct atrus_json_opts* options
);

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
    struct atrus_node_opaque** out
);

// ----------------------------------------------------------------------------
// Advanced Atrus API (Exposed AST)
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

struct atrus_node_root {
    struct atrus_node** children;
    unsigned int children_len;
};

struct atrus_node_wrapper {
    struct atrus_node** children;
    unsigned int children_len;
};

struct atrus_node_heading {
    struct atrus_node** children;
    unsigned int children_len;
    unsigned short depth;
};

struct atrus_node_text {
    const char* value;
};

struct atrus_node_code {
    const char* value;
    const char* lang;
    bool show_line_numbers;
};

struct atrus_node_link {
    struct atrus_node** children;
    unsigned int children_len;
    const char* url;
    const char* title;
};

struct atrus_node_link_definition {
    const char* url;
    const char* title;
    const char* label;
};

struct atrus_node_image {
    const char* url;
    const char* title;
    const char* alt;
};

struct atrus_node_container {
    struct atrus_node** children;
    unsigned int children_len;
    const char* kind;
};

struct atrus_node_myst_role {
    struct atrus_node** children;
    unsigned int children_len;
    const char* name;
    const char* value;
};

struct atrus_node_myst_role_error {
    const char* value;
};

struct atrus_node_abbreviation {
    struct atrus_node** children;
    unsigned int children_len;
    const char* title;
};

struct atrus_node_myst_directive {
    struct atrus_node** children;
    unsigned int children_len;
    const char* name;
    const char* args;
    const char* value;
};

struct atrus_node_myst_directive_error {
    struct atrus_node** children;
    unsigned int children_len;
    const char* message;
};

struct atrus_node_admonition {
    struct atrus_node** children;
    unsigned int children_len;
    const char* kind;
};

struct atrus_node {
    union {
        struct atrus_node_root                  root;
        struct atrus_node_wrapper               block;
        struct atrus_node_heading               heading;
        struct atrus_node_wrapper               paragraph;
        struct atrus_node_text                  text;
        struct atrus_node_code                  code;
        // thematic_break (void) omitted
        // break          (void) omitted
        struct atrus_node_wrapper               emphasis;
        struct atrus_node_wrapper               strong;
        struct atrus_node_text                  inline_code;
        struct atrus_node_link                  link;
        struct atrus_node_link_definition       definition;
        struct atrus_node_image                 image;
        struct atrus_node_wrapper               blockquote;
        struct atrus_node_text                  html;
        struct atrus_node_container             container;
        struct atrus_node_wrapper               caption;
        struct atrus_node_myst_role             myst_role;
        struct atrus_node_myst_role_error       myst_role_error;
        struct atrus_node_wrapper               subscript;
        struct atrus_node_wrapper               superscript;
        struct atrus_node_abbreviation          abbreviation;
        struct atrus_node_myst_directive        myst_directive;
        struct atrus_node_myst_directive_error  myst_directive_error;
        struct atrus_node_admonition            admonition;
        struct atrus_node_wrapper               admonition_title;
    } payload;
    atrus_node_type_t tag;
};

/*
 * Given an opaque pointer to an AST, converts the AST to an exposed AST with
 * fields accessible from C.
 *
 * This takes ownership of the input AST and creates a copy. The input opaque
 * pointer is invalidated. Do not subsequently call `atrus_free()` on the
 * opaque pointer.
 *
 * The caller is responsible for freeing the returned AST with
 * `atrus_free_exposed()`. You do not need to free the exposed AST if you later
 * pass it back to libatrus with `atrus_adopt()`.
 */
int atrus_expose(struct atrus_node_opaque* root, struct atrus_node** out);

/*
 * Given a pointer to an exposed AST, converts the AST back to libatrus'
 * internal representation.
 *
 * This takes ownership of the input AST and creates a copy. The input pointer
 * is invalidated. Do not subsequently call `atrus_free_exposed()` on the
 * pointer.
 *
 * The caller is responsible for freeing the returned AST with `atrus_free()`.
 */
int atrus_adopt(struct atrus_node* root, struct atrus_node_opaque** out);

/*
 * Frees the given exposed AST recursively.
 */
void atrus_free_exposed(struct atrus_node* root);

#endif
