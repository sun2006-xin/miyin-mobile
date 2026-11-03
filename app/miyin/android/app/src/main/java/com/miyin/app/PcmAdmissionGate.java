package com.miyin.app;

import java.util.ArrayList;
import java.util.List;

/** Main-thread admission acknowledgements; audio remains in the bounded writer queue. */
final class PcmAdmissionGate {
    interface Ack { void complete(boolean accepted); }
    private final int highWaterBytes;
    private final int lowWaterBytes;
    private final List<Ack> pending = new ArrayList<>();
    private boolean closed;

    PcmAdmissionGate(int highWaterBytes, int lowWaterBytes) {
        if (lowWaterBytes < 0 || lowWaterBytes >= highWaterBytes) {
            throw new IllegalArgumentException("Invalid PCM watermarks");
        }
        this.highWaterBytes = highWaterBytes;
        this.lowWaterBytes = lowWaterBytes;
    }

    void acknowledgeOrWait(int queuedBytes, Ack ack) {
        if (closed) ack.complete(false);
        else if (queuedBytes >= highWaterBytes) pending.add(ack);
        else ack.complete(true);
    }

    void onDrain(int queuedBytes) {
        if (!closed && queuedBytes <= lowWaterBytes) completePending(true);
    }

    void cancel() {
        closed = true;
        completePending(false);
    }

    private void completePending(boolean accepted) {
        List<Ack> ready = new ArrayList<>(pending);
        pending.clear();
        for (Ack ack : ready) ack.complete(accepted);
    }
}
