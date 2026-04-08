/*
 * Extra JNI methods specific to prrrrrrrrr.
 *
 * Compiled with -DJNI_PACKAGE=me_jappie_prrrrrrrrr via extraJniBridge
 * in nix/android.nix.  The standard 11 JNI methods come from
 * haskell-mobile's jni_bridge.c (compiled with me_jappie_haskellmobile
 * since they are declared on HaskellMobileActivity).
 *
 * Consumer-specific native methods (like setFilesDir) are declared on
 * the consumer's own MainActivity subclass, so JNI_CLASS must be
 * MainActivity here — not the library's HaskellMobileActivity default.
 */

#include <jni.h>
#define JNI_CLASS MainActivity
#include "JniBridge.h"

extern void set_app_files_dir(const char *path);

JNIEXPORT void JNICALL
JNI_METHOD(setFilesDir)(JNIEnv *env, jobject thiz, jstring path)
{
    const char *cpath = (*env)->GetStringUTFChars(env, path, NULL);
    if (cpath) {
        set_app_files_dir(cpath);
        (*env)->ReleaseStringUTFChars(env, path, cpath);
    }
}
