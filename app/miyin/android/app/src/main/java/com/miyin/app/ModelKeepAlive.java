package com.miyin.app;

/** Keeps a loaded model across brief interruptions; no Android dependency. */
final class ModelKeepAlive {
    interface Scheduler {
        void postDelayed(Runnable task, long delayMillis);
        void removeCallbacks(Runnable task);
    }
    private final Scheduler scheduler;
    private final Runnable release;
    private final long delayMillis;
    private Runnable pending;
    private boolean foreground = true;
    private boolean disposed;

    ModelKeepAlive(Scheduler scheduler, Runnable release, long delayMillis) {
        this.scheduler = scheduler;
        this.release = release;
        this.delayMillis = delayMillis;
    }
    synchronized void foreground() {
        if (disposed) return;
        foreground = true;
        clear();
    }
    synchronized void background() {
        if (disposed) return;
        foreground = false;
        clear();
        Runnable task = new Runnable() {
            @Override public void run() {
                synchronized (ModelKeepAlive.this) {
                    if (disposed || foreground || pending != this) return;
                    pending = null;
                    release.run();
                }
            }
        };
        pending = task;
        scheduler.postDelayed(task, delayMillis);
    }
    private void clear() {
        if (pending != null) scheduler.removeCallbacks(pending);
        pending = null;
    }
    synchronized void dispose() {
        disposed = true;
        clear();
    }
}
