package me.jappie.prrrrrrrrr;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.Manifest;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.widget.EditText;

public class MainActivity extends Activity implements View.OnClickListener {

    static {
        System.loadLibrary("prrrrrrrrr");
    }

    private native String greet(String name);
    private native void renderUI();
    private native void onButtonClick(View view);
    private native void onTextChange(View view, String text);
    private native void onLifecycleCreate();
    private native void onLifecycleStart();
    private native void onLifecycleResume();
    private native void onLifecyclePause();
    private native void onLifecycleStop();
    private native void onLifecycleDestroy();
    private native void onLifecycleLowMemory();
    private native void onPermissionResult(int requestCode, int statusCode);

    private String permissionCodeToString(int permissionCode) {
        switch (permissionCode) {
            case 0: return Manifest.permission.ACCESS_FINE_LOCATION;
            case 1: return Manifest.permission.BLUETOOTH_SCAN;
            case 2: return Manifest.permission.CAMERA;
            case 3: return Manifest.permission.RECORD_AUDIO;
            case 4: return Manifest.permission.READ_CONTACTS;
            case 5: return Manifest.permission.READ_EXTERNAL_STORAGE;
            default: return null;
        }
    }

    public void requestPermission(int permissionCode, int requestId) {
        String permission = permissionCodeToString(permissionCode);
        if (permission == null) {
            onPermissionResult(requestId, 1);
            return;
        }
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            onPermissionResult(requestId, 0);
            return;
        }
        requestPermissions(new String[]{ permission }, requestId);
    }

    public int checkPermission(int permissionCode) {
        String permission = permissionCodeToString(permissionCode);
        if (permission == null) return 1;
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED ? 0 : 1;
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        int statusCode = (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) ? 0 : 1;
        onPermissionResult(requestCode, statusCode);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setFilesDir(getFilesDir().getAbsolutePath());
        onLifecycleCreate();
        renderUI();
    }

    /** Pass the Android files directory to native code for SQLite storage. */
    private native void setFilesDir(String path);

    @Override
    public void onClick(View v) {
        onButtonClick(v);
    }

    /**
     * Register a TextWatcher on an EditText. Called from native code
     * when a TextInput widget has an EventTextChange handler.
     */
    public void registerTextWatcher(final EditText editText) {
        editText.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {}

            @Override
            public void afterTextChanged(Editable s) {
                onTextChange(editText, s.toString());
            }
        });
    }

    @Override
    protected void onStart() {
        super.onStart();
        onLifecycleStart();
    }

    @Override
    protected void onResume() {
        super.onResume();
        onLifecycleResume();
    }

    @Override
    protected void onPause() {
        super.onPause();
        onLifecyclePause();
    }

    @Override
    protected void onStop() {
        super.onStop();
        onLifecycleStop();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        onLifecycleDestroy();
    }

    @Override
    public void onLowMemory() {
        super.onLowMemory();
        onLifecycleLowMemory();
    }
}
