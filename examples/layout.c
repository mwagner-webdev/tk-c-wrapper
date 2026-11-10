/*
 * layout.c -- a small form laid out with Tk's grid (and pack inside a
 * button bar), with a callback that updates the interface.
 *
 *   +-------------------------------------------+
 *   | Name:  [entry........................]    |
 *   | Note:  [entry........................]    |
 *   | +---------------------------------------+ |
 *   | | treeview (spans 2 columns, grows)     | |
 *   | +---------------------------------------+ |
 *   | status label                [Add] [Clear]|
 *   +-------------------------------------------+
 *
 * Column 1 and row 2 have weight 1, so the entries widen and the tree
 * grows when the window is resized.  No Tcl code is written anywhere.
 *
 *   build/9.1.0/layout
 *   TKX_EXAMPLE_AUTOCLOSE=1 build/9.1.0/layout   (scripted run for CI)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tkx.h"

typedef struct Form {
    TkxId name, note, tree, status, add, clear;
    int rows;
} Form;

static void die(const char *what)
{
    fprintf(stderr, "%s: %s: %s\n", what, tkx_status_name(tkx_last_error()),
	    tkx_last_error_message());
    exit(1);
}

#define CHECK(call) do { if ((call) != TKX_OK) die(#call); } while (0)

static void update_status(Form *f)
{
    char buf[128];
    snprintf(buf, sizeof(buf), "%d row%s", f->rows, f->rows == 1 ? "" : "s");
    CHECK(tkx_ttk_label_set_text(f->status, buf));
}

static void on_add(TkxId button, void *user_data)
{
    Form *f = (Form *)user_data;
    char *name = NULL, *note = NULL, *item = NULL;
    const char *values[1];
    (void)button;

    CHECK(tkx_ttk_entry_get(f->name, &name));
    CHECK(tkx_ttk_entry_get(f->note, &note));
    if (name[0] != '\0') {
	CHECK(tkx_ttk_treeview_insert(f->tree, "", TKX_INDEX_END, NULL, &item));
	CHECK(tkx_ttk_treeview_item_set_text(f->tree, item, name));
	values[0] = note;
	CHECK(tkx_ttk_treeview_item_set_values(f->tree, item, values, 1));
	CHECK(tkx_ttk_entry_delete(f->name, 0, &(int){TKX_INDEX_END}));
	CHECK(tkx_ttk_entry_delete(f->note, 0, &(int){TKX_INDEX_END}));
	f->rows++;
	update_status(f);
	tkx_free(item);
    }
    tkx_free(name);
    tkx_free(note);
}

static void on_clear(TkxId button, void *user_data)
{
    Form *f = (Form *)user_data;
    TkxStringList kids = {0, NULL};
    (void)button;
    CHECK(tkx_ttk_treeview_children(f->tree, "", NULL, 0, &kids));
    if (kids.count > 0) {
	CHECK(tkx_ttk_treeview_delete(f->tree, (const char *const *)kids.items, kids.count));
    }
    tkx_string_list_free(&kids);
    f->rows = 0;
    update_status(f);
}

static TkxId label(TkxId parent, const char *text)
{
    TkxId l = tkx_ttk_label_create(parent);
    if (!l) die("label");
    CHECK(tkx_ttk_label_set_text(l, text));
    return l;
}

int main(void)
{
    Form f;
    TkxId win, content, bar, l1, l2;
    const char *columns[] = {"note"};
    int w, h;

    memset(&f, 0, sizeof(f));
    CHECK(tkx_app_init(NULL));
    win = tkx_app_main_window();
    CHECK(tkx_window_set_title(win, "tkx layout"));

    /* A ttk frame fills the window (pack), everything else is gridded. */
    content = tkx_ttk_frame_create(win);
    CHECK(tkx_ttk_frame_set_padding(content, "8"));
    CHECK(tkx_pack(content));
    CHECK(tkx_pack_set_fill(content, TKX_PACK_FILL_BOTH));
    CHECK(tkx_pack_set_expand(content, 1));

    l1 = label(content, "Name:");
    l2 = label(content, "Note:");
    f.name = tkx_ttk_entry_create(content);
    f.note = tkx_ttk_entry_create(content);
    f.tree = tkx_ttk_treeview_create(content);
    f.status = label(content, "");
    bar = tkx_frame_create(content);
    f.add = tkx_ttk_button_create(bar);
    f.clear = tkx_ttk_button_create(bar);
    if (!f.name || !f.note || !f.tree || !bar || !f.add || !f.clear) die("create");

    CHECK(tkx_ttk_treeview_set_columns(f.tree, columns, 1));
    CHECK(tkx_ttk_treeview_heading_set_text(f.tree, "#0", "Name"));
    CHECK(tkx_ttk_treeview_heading_set_text(f.tree, "note", "Note"));
    CHECK(tkx_ttk_treeview_set_height(f.tree, 6));
    CHECK(tkx_ttk_button_set_text(f.add, "Add"));
    CHECK(tkx_ttk_button_set_text(f.clear, "Clear"));
    if (!tkx_ttk_button_set_command(f.add, on_add, &f, NULL)) die("command");
    if (!tkx_ttk_button_set_command(f.clear, on_clear, &f, NULL)) die("command");

    /* Grid: labels in column 0 (east-aligned), entries in column 1. */
    CHECK(tkx_grid(l1, 0, 0));
    CHECK(tkx_grid_set_sticky(l1, TKX_STICKY_E));
    CHECK(tkx_grid(f.name, 0, 1));
    CHECK(tkx_grid_set_sticky(f.name, TKX_STICKY_E | TKX_STICKY_W));
    CHECK(tkx_grid_set_pady(f.name, 2, 2));
    CHECK(tkx_grid(l2, 1, 0));
    CHECK(tkx_grid_set_sticky(l2, TKX_STICKY_E));
    CHECK(tkx_grid(f.note, 1, 1));
    CHECK(tkx_grid_set_sticky(f.note, TKX_STICKY_E | TKX_STICKY_W));
    CHECK(tkx_grid_set_pady(f.note, 2, 2));
    /* The tree spans both columns and fills its cell. */
    CHECK(tkx_grid(f.tree, 2, 0));
    CHECK(tkx_grid_set_columnspan(f.tree, 2));
    CHECK(tkx_grid_set_sticky(f.tree, TKX_STICKY_NSEW));
    CHECK(tkx_grid_set_pady(f.tree, 6, 6));
    CHECK(tkx_grid(f.status, 3, 0));
    CHECK(tkx_grid_set_sticky(f.status, TKX_STICKY_W));
    CHECK(tkx_grid(bar, 3, 1));
    CHECK(tkx_grid_set_sticky(bar, TKX_STICKY_E));
    /* Buttons inside the bar are packed right to left. */
    CHECK(tkx_pack(f.clear));
    CHECK(tkx_pack_set_side(f.clear, TKX_SIDE_RIGHT));
    CHECK(tkx_pack(f.add));
    CHECK(tkx_pack_set_side(f.add, TKX_SIDE_RIGHT));
    CHECK(tkx_pack_set_padx(f.add, 0, 4));
    /* Resizing behaviour. */
    CHECK(tkx_grid_columnconfigure_weight(content, 1, 1));
    CHECK(tkx_grid_rowconfigure_weight(content, 2, 1));
    CHECK(tkx_grid_columnconfigure_minsize(content, 0, 60));
    update_status(&f);

    if (getenv("TKX_EXAMPLE_AUTOCLOSE")) {
	TkxBox before, after;
	CHECK(tkx_app_update_idletasks());
	CHECK(tkx_ttk_entry_insert(f.name, 0, "Ada"));
	CHECK(tkx_ttk_entry_insert(f.note, 0, "first entry"));
	CHECK(tkx_ttk_button_invoke(f.add));
	CHECK(tkx_ttk_entry_insert(f.name, 0, "Grace"));
	CHECK(tkx_ttk_button_invoke(f.add));
	CHECK(tkx_widget_requested_size(content, &w, &h));
	printf("rows=%d requested=%dx%d\n", f.rows, w, h);
	/* Make the window bigger: the tree (row/column weight 1) grows. */
	CHECK(tkx_window_set_geometry(win, w + 200, h + 150));
	CHECK(tkx_app_update_idletasks());
	tkx_app_process_events();
	CHECK(tkx_widget_geometry(f.tree, &before));
	CHECK(tkx_window_set_geometry(win, w + 300, h + 250));
	tkx_app_process_events();
	CHECK(tkx_app_update_idletasks());
	CHECK(tkx_widget_geometry(f.tree, &after));
	printf("tree grows: %s\n", after.width > before.width && after.height > before.height
		? "yes" : "no");
	CHECK(tkx_ttk_button_invoke(f.clear));
	printf("after clear rows=%d\n", f.rows);
	tkx_app_shutdown();
	return 0;
    }
    CHECK(tkx_app_run());
    tkx_app_shutdown();
    return 0;
}
