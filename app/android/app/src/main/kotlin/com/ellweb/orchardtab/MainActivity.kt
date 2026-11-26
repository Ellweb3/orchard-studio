package com.ellweb.orchardtab

import android.content.Context
import android.media.AudioManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // cpal (AAudio) needs JavaVM + Context in ndk-context before the
        // engine opens a stream (same as hum_flutter's plugin).
        nativeInitAndroidContext(applicationContext)
        super.onCreate(savedInstanceState)
        // hardware volume keys always control the music stream the engine plays on
        volumeControlStream = AudioManager.STREAM_MUSIC
    }

    companion object {
        init {
            System.loadLibrary("orchard_engine")
        }

        @JvmStatic
        private external fun nativeInitAndroidContext(context: Context)
    }
}
