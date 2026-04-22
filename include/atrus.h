/*
 * This file defines the public C-ABI-compatible interface of libatrus.
 */
#ifndef ATRUS_H
#define ATRUS_H

extern const char* const atrus_version;

// ----------------------------------------------------------------------------
// Atrus MyST Markdown AST
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
} atrus_node_type_t;

struct atrus_ast_node_root {
    struct atrus_ast_node** children;
    unsigned int n_children;
};

struct atrus_ast_node_container {
    struct atrus_ast_node** children;
    unsigned int n_children;
};

struct atrus_ast_node_heading {
    struct atrus_ast_node** children;
    unsigned int n_children;
    unsigned short depth;
};

struct atrus_ast_node_text {
    const char* value;
};

struct atrus_ast_node_code {
    const char* value;
    const char* lang;
};

struct atrus_ast_node_link {
    struct atrus_ast_node** children;
    unsigned int n_children;
    const char* url;
    const char* title;
};

struct atrus_ast_node_link_definition {
    const char* url;
    const char* title;
    const char* label;
};

struct atrus_ast_node_image {
    const char* url;
    const char* title;
    const char* alt;
};

struct atrus_ast_node {
    union {
        struct atrus_ast_node_root            root;
        struct atrus_ast_node_container       block;
        struct atrus_ast_node_heading         heading;
        struct atrus_ast_node_container       paragraph;
        struct atrus_ast_node_text            text;
        struct atrus_ast_node_code            code;
        // thematic_break (void) omitted
        // break          (void) omitted
        struct atrus_ast_node_container       emphasis;
        struct atrus_ast_node_container       strong;
        struct atrus_ast_node_text            inline_code;
        struct atrus_ast_node_link            link;
        struct atrus_ast_node_link_definition definition;
        struct atrus_ast_node_image           image;
        struct atrus_ast_node_container       blockquote;
    } payload;
    atrus_node_type_t tag;
};

// ----------------------------------------------------------------------------
// Atrus API
// ----------------------------------------------------------------------------
typedef enum : unsigned int {
    ATRUS_BLOCK_PARSE_LEVEL = 0,
    ATRUS_RAW_PARSE_LEVEL = 1,
    ATRUS_PRE_PARSE_LEVEL = 2,
    ATRUS_POST_PARSE_LEVEL = 3,
} atrus_parse_option_parse_level_t;

/*
 * Options for MyST markdown parsing.
 */
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
 * The caller is responsible for freeing the AST using atrus_free().
 */
atrus_parse_error_t atrus_parse(
    const char* in,
    struct atrus_ast_node** out,
    const struct atrus_parse_opts* options
);

/*
 * Frees the given AST, recursively.
 *
 * Will panic if called on a non-root node.
 */
void atrus_free(struct atrus_ast_node* root);

/*
 * Given a MyST AST, renders the tree as HTML into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_html(struct atrus_ast_node* root, char** out);

typedef enum : unsigned int {
    ATRUS_JSON_MINIFIED = 0,
    ATRUS_JSON_INDENT_2 = 1,
    ATRUS_JSON_INDENT_4 = 2,
} atrus_json_option_whitespace_t;

/*
 * Options for JSON rendering.
 */
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
    struct atrus_ast_node* root,
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
 * The caller is responsible for freeing the returned AST using atrus_free().
 */
atrus_load_error_t atrus_load_json(
    const char* in,
    struct atrus_ast_node** out
);

#endif
