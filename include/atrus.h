#ifndef ATRUS_H
#define ATRUS_H

// Opaque type.
typedef struct atrus_ast_node atrus_ast_node;

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
atrus_parse_error_t atrus_parse(char* in, atrus_ast_node** out); 

/*
 * Frees the given AST.
 */
void atrus_free(atrus_ast_node* root);

/*
 * Given a MyST AST, renders the tree as HTML into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_html(atrus_ast_node* root, char** out);

typedef enum : unsigned int {
    ATURS_JSON_MINIFIED = 0,
    ATRUS_JSON_INDENT_2 = 1,
    ATRUS_JSON_INDENT_4 = 2,
} atrus_json_option_whitespace_t;

/*
 * Options for JSON rendering.
 */
struct atrus_json_options {
    atrus_json_option_whitespace_t whitespace;
};

/*
 * Given a MyST AST, renders the tree as JSON into a null-terminated string.
 * Returns the length of the string or a negative number on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_json(
    atrus_ast_node* root, 
    char** out,
    const struct atrus_json_options* options
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
atrus_load_error_t atrus_load_json(char* in, atrus_ast_node** out);

#endif
