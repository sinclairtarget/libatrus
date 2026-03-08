#include <stdlib.h>
#include <stdio.h>

#include "atrus.h"

/*
 * Tests the Atrus C API.
 *
 * Exits 0 on success, 1 on test failure.
 */
int main() {
    char* md = "# Heading\nThis is a paragraph.\n";
    struct atrus_parse_opts parse_options = {
        .parse_level = ATRUS_POST_PARSE_LEVEL,
    };
    atrus_ast_node* node;
    atrus_parse_error_t err = atrus_parse(md, &node, &parse_options);
    if (err != ATRUS_PARSE_SUCCESS) {
        fprintf(stderr, "Failed to parse. Got error: %d.\n", err);
        exit(1);
    }

    char* out;
    struct atrus_json_opts render_options = { 
        .whitespace = ATRUS_JSON_INDENT_2,
    };
    int len = atrus_render_json(node, &out, &render_options);
    if (len == -1) {
        fprintf(stderr, "Failed to render JSON.\n");
        exit(1);
    }

    free(out);

    len = atrus_render_html(node, &out);
    if (len == -1) {
        fprintf(stderr, "Failed to render HTML.\n");
        exit(1);
    }

    free(out);

    atrus_free(node);

    return 0;
}
