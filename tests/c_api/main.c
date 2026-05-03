#include <stdlib.h>
#include <stdio.h>

#include "atrus.h"

// Test that we can traverse the AST
void print_heading_text(struct atrus_node* root) {
    struct atrus_node* block = root->payload.root.children[0];
    struct atrus_node* heading = block->payload.block.children[0];
    struct atrus_node* text = heading->payload.heading.children[0];
    printf("heading text: \"%s\"\n", text->payload.text.value);
}

/*
 * Tests the Atrus C API.
 *
 * Exits 0 on success, 1 on test failure.
 */
int main() {
    // Test getting version
    fprintf(stderr, "%s\n", atrus_version);

    // Test parsing
    char* md = "# Heading\nThis is a paragraph.\n";
    struct atrus_parse_opts parse_options = {
        .parse_level = ATRUS_POST_PARSE_LEVEL,
    };
    struct atrus_node_opaque* node;
    atrus_parse_error_t err = atrus_parse(md, &node, &parse_options);
    if (err != ATRUS_PARSE_SUCCESS) {
        fprintf(stderr, "Failed to parse. Got error: %d.\n", err);
        exit(1);
    }

    // Test getting node type name
    const char* node_type_name = atrus_name(node);
    printf("node type name: \"%s\"\n", node_type_name);

    // Test AST traversal
    struct atrus_node* exposed_node;
    if (atrus_expose(node, &exposed_node) < 0) {
        fprintf(stderr, "Failed to call atrus_expose().\n");
        exit(1);
    }

    print_heading_text(exposed_node);

    // Test atrus_adopt(). Not strictly necessary in this example since we
    // didn't modify the AST.
    if (atrus_adopt(exposed_node, &node) < 0) {
        fprintf(stderr, "Failed to call atrus_adopt().\n");
        exit(1);
    }

    // Test rendering (JSON)
    char* out;
    struct atrus_json_opts render_options = {
        .whitespace = ATRUS_JSON_INDENT_2,
    };
    int len = atrus_render_json(node, &out, &render_options);
    if (len == -1) {
        fprintf(stderr, "Failed to render JSON.\n");
        exit(1);
    }

    printf("%s\n", out);
    free(out);

    // Test rendering (HTML)
    len = atrus_render_html(node, &out);
    if (len == -1) {
        fprintf(stderr, "Failed to render HTML.\n");
        exit(1);
    }

    printf("%s\n", out);
    free(out);

    atrus_free(node);

    // Parse input again to create a second AST. We do this just to test
    // atrus_free_exposed().
    err = atrus_parse(md, &node, &parse_options);
    if (err != ATRUS_PARSE_SUCCESS) {
        fprintf(stderr, "Failed to parse. Got error: %d.\n", err);
        exit(1);
    }
    if (atrus_expose(node, &exposed_node) < 0) {
        fprintf(stderr, "Failed to call atrus_expose().\n");
        exit(1);
    }
    atrus_free_exposed(exposed_node);

    fprintf(stderr, "Done!\n");
    return 0;
}
