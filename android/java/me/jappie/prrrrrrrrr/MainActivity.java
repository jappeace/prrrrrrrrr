package me.jappie.prrrrrrrrr;

import android.os.Bundle;
import me.jappie.haskellmobile.HaskellMobileActivity;

public class MainActivity extends HaskellMobileActivity {

    /** Pass the Android files directory to native code for SQLite storage. */
    private native void setFilesDir(String path);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        setFilesDir(getFilesDir().getAbsolutePath());
        super.onCreate(savedInstanceState);
    }
}
