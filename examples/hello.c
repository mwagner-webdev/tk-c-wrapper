/*
 * hello.c -- minimal tkx program: a label and a button that updates it.
 *
 *   build/9.1.0/hello            (needs an X display)
 *   TKX_EXAMPLE_AUTOCLOSE=1 ...  invoke the button once and exit (CI)
 */
#include <stdio.h>
#include <stdlib.h>
#include "tkx.h"

static int clicks = 0;

static void on_click(TkxId button, void *user_data)
{
    TkxId label = *(TkxId *)user_data;
    char text[64];
    (void)button;
    clicks++;
    snprintf(text, sizeof(text), "Clicked %d time%s", clicks, clicks == 1 ? "" : "s");
    tkx_ttk_label_set_text(label, text);
}

static int check(TkxStatus st, const char *what)
{
    if (st != TKX_OK) {
	fprintf(stderr, "%s: %s: %s\n", what, tkx_status_name(st), tkx_last_error_message());
	exit(1);
    }
    return 0;
}

int main(void)
{
    TkxId win, label, button;
    char *text = NULL;

    check(tkx_app_init(NULL), "tkx_app_init");
    win = tkx_app_main_window();
    check(tkx_window_set_title(win, "tkx hello"), "title");

    label = tkx_ttk_label_create(win);
    button = tkx_ttk_button_create(win);
    if (!label || !button) {
	fprintf(stderr, "create: %s\n", tkx_last_error_message());
	return 1;
    }
    check(tkx_ttk_label_set_text(label, "Hello from C \xe2\x9c\x93"), "label text");
    check(tkx_ttk_button_set_text(button, "Click me"), "button text");
    if (tkx_ttk_button_set_command(button, on_click, &label, NULL) == TKX_NULL_ID) {
	fprintf(stderr, "command: %s\n", tkx_last_error_message());
	return 1;
    }
    check(tkx_pack(label), "pack label");
    check(tkx_pack_set_padx(label, 20, 20), "pack padx");
    check(tkx_pack_set_pady(label, 10, 5), "pack pady");
    check(tkx_pack(button), "pack button");
    check(tkx_pack_set_pady(button, 5, 10), "pack pady");

    if (getenv("TKX_EXAMPLE_AUTOCLOSE")) {
	tkx_app_update_idletasks();
	check(tkx_ttk_button_invoke(button), "invoke");
	check(tkx_ttk_label_get_text(label, &text), "get text");
	printf("label: %s\n", text);
	tkx_free(text);
	tkx_app_shutdown();
	return clicks == 1 ? 0 : 1;
    }
    tkx_app_run();
    tkx_app_shutdown();
    return 0;
}
