package com.eqengine.app;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/**
 * Keeps the EQ attached while EQ Engine is on. Started by the NEMESIS boot step once Android has
 * finished starting, and by the EQ Engine screen. Stops itself when EQ Engine is off.
 */
public class EqService extends Service {
    @Override
    public void onCreate() {
        super.onCreate();
        EqLog.init(getFilesDir());
        EqLog.i("EQ service created");
        Engine.get(this).start(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Engine.get(this).start(this);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        Engine e = Engine.get(this);
        if (e.isRunning()) e.stop("service destroyed");
        EqLog.i("EQ service destroyed");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
