package com.miyin.app;

/** Deterministic slow-writer and cancellation checks, runnable without Android. */
public final class PcmAdmissionGateTest {
    public static void main(String[] args) {
        PcmAdmissionGate gate = new PcmAdmissionGate(1024, 512);
        int[] accepted = {0}, cancelled = {0};
        PcmAdmissionGate.Ack ack = ok -> { if (ok) accepted[0]++; else cancelled[0]++; };
        gate.acknowledgeOrWait(900, ack);
        check(accepted[0] == 1, "Below high water must not wait for playback");
        gate.acknowledgeOrWait(1050, ack);
        gate.onDrain(800);
        check(accepted[0] == 1, "Slow writer must retain backpressure above low water");
        gate.onDrain(512);
        check(accepted[0] == 2, "Resume synthesis while queued audio remains, before this chunk is written");
        gate.onDrain(0);
        check(accepted[0] == 2, "Late writer progress must not acknowledge twice");
        gate.acknowledgeOrWait(1100, ack);
        gate.cancel(); gate.cancel(); gate.onDrain(0);
        check(cancelled[0] == 1 && accepted[0] == 2, "Stop cancels a waiting append exactly once");
        gate.acknowledgeOrWait(0, ack);
        check(cancelled[0] == 2, "A closed stream cannot accept late audio");
        PcmAdmissionGate next = new PcmAdmissionGate(1024, 512);
        next.acknowledgeOrWait(1100, ack);
        gate.onDrain(0);
        check(accepted[0] == 2, "Old stream progress cannot release the next stream");
        next.onDrain(400);
        check(accepted[0] == 3, "Next stream owns its acknowledgements");
        System.out.println("8 PCM admission checks passed");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
