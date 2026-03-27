/*
 * Storage helper for prrrrrrrrr.
 *
 * On Android, the Java side calls set_app_files_dir() during onCreate
 * to tell native code where to store the SQLite database.
 * On desktop, falls back to /tmp.
 */

#include <string.h>

#define MAX_PATH 512

static char g_files_dir[MAX_PATH] = "/tmp";

void set_app_files_dir(const char *path)
{
    strncpy(g_files_dir, path, MAX_PATH - 1);
    g_files_dir[MAX_PATH - 1] = '\0';
}

const char *get_app_files_dir(void)
{
    return g_files_dir;
}
