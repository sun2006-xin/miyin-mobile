package com.miyin.app;

/** Executed with javac/java, without downloading a test framework. */
public final class ModelKeepAliveTest {
    public static void main(String[] args) {
        final Runnable[] queued = {null};
        final long[] delay = {0};
        final int[] releases = {0};
        ModelKeepAlive policy = new ModelKeepAlive(new ModelKeepAlive.Scheduler() {
            public void postDelayed(Runnable task, long millis) { queued[0] = task; delay[0] = millis; }
            public void removeCallbacks(Runnable task) { if (queued[0] == task) queued[0] = null; }
        }, () -> releases[0]++, 300_000);
        policy.background();
        Runnable old = queued[0];
        check(delay[0] == 300_000 && releases[0] == 0, "background must delay release");
        policy.foreground();
        old.run();
        check(releases[0] == 0 && queued[0] == null, "returning cancels even a late timer");
        policy.background();
        Runnable first = queued[0];
        policy.background();
        first.run();
        check(releases[0] == 0, "obsolete background timers must not release");
        Runnable current = queued[0];
        current.run(); current.run();
        check(releases[0] == 1, "one background timeout releases exactly once");
        policy.background();
        Runnable disposed = queued[0];
        policy.dispose(); disposed.run(); policy.background();
        check(releases[0] == 1 && queued[0] == null, "dispose invalidates pending timers");
        System.out.println("5 model retention checks passed");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
