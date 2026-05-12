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
 * The caller is responsible for managing the lifetime of the AST as a whole.
 * In all other cases, data is owned by the library. Any string values attached
 * to the tree, for example, will always be cleaned up by the library and are
 * not the responsibility of the caller, even when they are returned by one of
 * the Node API accessor functions.
 */
#ifndef ATRUS_H
#define ATRUS_H

#include <stdbool.h>

#define ATRUS_MAJOR_VERSION 0
#define ATRUS_MINOR_VERSION 5
#define ATRUS_PATCH_VERSION 2

/*
 * Reports the link-time version of the library.
 */
void atrus_version(int* major, int* minor, int* patch);

// Opaque node type.
struct atrus_node;

// ----------------------------------------------------------------------------
// Top-Level API
// ----------------------------------------------------------------------------
typedef enum : unsigned int {
    ATRUS_POST_PARSE_LEVEL = 0,
    ATRUS_PRE_PARSE_LEVEL = 1,
    ATRUS_RAW_PARSE_LEVEL = 2,
    ATRUS_BLOCK_PARSE_LEVEL = 3,
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
/*
 * Returns the camel-cased type name for the given node.
 */
const char* atrus_node_type(struct atrus_node* node);

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
 * The below functions operate on node of a particular type.
 *
 * If a function is used on a node of the wrong type, the function will panic.
 */
// --- Heading ----------------------------------------------------------------
unsigned short atrus_node_heading_depth(struct atrus_node* node);

// --- Text -------------------------------------------------------------------
const char* atrus_node_text_value(struct atrus_node* node);

#endif
