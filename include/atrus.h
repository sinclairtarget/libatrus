#ifndef ATRUS_H
#define ATRUS_H

// Opaque type.
typedef struct atrus_ast_node atrus_ast_node;

typedef enum {
    ATRUS_PARSE_SUCCESS = 0,
    ATRUS_PARSE_READ_FAILED = 1,
    ATRUS_PARSE_OTHER_ERROR = 2,
} atrus_parse_error_t;

/*
 * Given a string containing MyST markdown, parses it into a MyST AST.
 *
 * The caller is responsible for freeing the AST using atrus_free().
 */
atrus_parse_error_t atrus_ast_parse(char* in, atrus_ast_node** out); 

/*
 * Frees the given AST.
 */
void atrus_ast_free(atrus_ast_node* root);

/*
 * Given a MyST AST, renders the tree as JSON into a string. Returns the length
 * of the string or -1 on error.
 *
 * The caller is responsible for freeing the string.
 */
int atrus_render_json(atrus_ast_node* root, char** out);

#endif
