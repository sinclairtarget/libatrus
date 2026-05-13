#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <assert.h>

#include "atrus.h"

// Test that we can traverse the AST
void traverse_ast(struct atrus_node* root) {
    struct atrus_node* block = atrus_node_child(root, 0);
    assert(block);
    struct atrus_node* heading = atrus_node_child(block, 0);
    assert(heading);
    struct atrus_node* text = atrus_node_child(heading, 0);
    assert(text);
    printf("heading text: \"%s\"\n", atrus_node_text_value(text));
}

void modify_ast(struct atrus_node* root) {
    struct atrus_node* block = atrus_node_child(root, 0);
    assert(block);

    struct atrus_node* html;
    int retcode = atrus_node_html_create(
        &html,
        "<div><p>This is my custom HTML.</p></div>"
    );
    if (retcode != 0) {
        fprintf(
            stderr,
            "Failed to create HTML node. Got error: %d.\n",
            retcode
        );
        exit(1);
    }

    atrus_node_replace_child(block, 1, html);
}

/*
 * Tests the Atrus C API.
 *
 * Exits 0 on success, 1 on test failure.
 */
int main() {
    // Test getting version
    const char* version = atrus_version();
    fprintf(stderr, "libatrus version: %s\n", version);

    // Test parsing
    char* md = "# Heading\nThis is a paragraph.\n";
    struct atrus_node* node;
    atrus_parse_error_t err = atrus_parse(md, &node, ATRUS_PARSE_LEVEL_POST);
    if (err != ATRUS_PARSE_SUCCESS) {
        fprintf(stderr, "Failed to parse. Got error: %d.\n", err);
        exit(1);
    }

    // Test AST traversal
    traverse_ast(node);

    // Test getting node type and type name
    atrus_node_type_t node_type = atrus_node_type(node);
    assert(node_type == ATRUS_NODE_TYPE_ROOT);
    const char* node_type_name = atrus_node_type_name(node);
    printf("node type name: \"%s\"\n", node_type_name);

    // Test rendering (HTML)
    char* out;
    int len = atrus_render_html(node, &out);
    if (len == -1) {
        fprintf(stderr, "Failed to render HTML.\n");
        exit(1);
    }

    printf("%s\n", out);
    free(out);

    // Test AST modification
    modify_ast(node);

    // Test rendering (JSON)
    len = atrus_render_json(node, &out, ATRUS_JSON_INDENT_2);
    if (len == -1) {
        fprintf(stderr, "Failed to render JSON.\n");
        exit(1);
    }

    printf("%s\n", out);
    free(out);

    // Clean up
    atrus_free(node);

    fprintf(stderr, "Done!\n");
    return 0;
}
