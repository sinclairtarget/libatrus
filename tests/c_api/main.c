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

    atrus_ast_node* node;
    atrus_parse_error_t err = atrus_ast_parse(md, &node);
    if (err != ATRUS_PARSE_SUCCESS) {
        fprintf(stderr, "Failed to parse. Got error: %d.\n", err);
        exit(1);
    }

    char* out;
    int len = atrus_render_json(node, &out);
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

    atrus_ast_free(node);

    return 0;
}
