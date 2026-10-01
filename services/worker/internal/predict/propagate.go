package predict

import "time"

const _delayDecayBase = 0.9

const _propagationStaleAfter = 3 * time.Minute

// UpstreamObs is one fresh observation of a specific vehicle (plate) at a stop
// on a sub_route/Direction: its position (StopSequence) and how far ahead or
// behind schedule it was there (delaySeconds, positive = late), as of observedAt.
type UpstreamObs struct {
	StopSequence int
	DelaySeconds float64
	ObservedAt   time.Time
}

func latestUpstreamDelay(obs []UpstreamObs, targetSeq int, now time.Time) (delay float64, seq int, ok bool) {
	seq = -1
	for _, o := range obs {
		if o.StopSequence >= targetSeq {
			continue
		}
		if now.Sub(o.ObservedAt) > _propagationStaleAfter {
			continue
		}
		if o.StopSequence > seq {
			seq = o.StopSequence
			delay = o.DelaySeconds
			ok = true
		}
	}
	return delay, seq, ok
}

// decayDelay applies the per-stop exponential decay across a sequence gap. A
// zero or negative gap returns the delay unchanged (the observation is at or
// past the target, which callers should already have filtered out).
func decayDelay(delay float64, seqGap int) float64 {
	if seqGap <= 0 {
		return delay
	}
	factor := 1.0
	for range seqGap {
		factor *= _delayDecayBase
	}
	return delay * factor
}

func PropagateDelay(baseline time.Time, targetSeq int, obs []UpstreamObs, now time.Time) (time.Time, bool) {
	if baseline.IsZero() {
		return time.Time{}, false
	}
	delay, seq, ok := latestUpstreamDelay(obs, targetSeq, now)
	if !ok {
		return time.Time{}, false
	}
	decayed := decayDelay(delay, targetSeq-seq)
	return baseline.Add(time.Duration(decayed) * time.Second), true
}
