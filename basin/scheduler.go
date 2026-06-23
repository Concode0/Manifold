package basin

import (
	"math"
)

const (
	Alpha = 1.0 // load exponent in the potential denominator
	Beta  = 0.5 // queue-pressure exponent in the potential denominator

	// MaxHops is the routing diameter ceiling. Once a task has been
	// forwarded this many times it is accepted locally regardless of
	// potential comparison. This prevents pathological oscillation in
	// symmetric topologies where every node always sees a peer as better.
	MaxHops = 8
)

// MigrationHysteresis is the minimum relative potential drop a peer must
// offer before a task is forwarded.
//
// The queue-pressure contribution to V at queue=1 is 1 − exp(−Beta) ≈ 0.39.
// Set below 0.39 the system oscillates by design: the holder always sees
// its own queue=1 vs peer queue=0 and migrates; the receiver then sees the
// mirror image and migrates back, until MaxHops force-accepts. Set above
// 0.39 to suppress that asymmetry and study convergence instead.
var MigrationHysteresis = 0.15

// EvaluatePotential returns V = (mass + phi) / (exp(−alphaL − betaQ) · tau) for a task
// against a candidate (res, load, queue, trust) tuple. Returns +Inf when
// the task cannot fit the candidate's available resources or when trust
// has collapsed to zero — either way the candidate is unschedulable.
func (n *Node) EvaluatePotential(t Task, res Multivector, load, queue, trust float64) float64 {
	if t.Requirement[1] > res[1] ||
		t.Requirement[2] > res[2] ||
		t.Requirement[4] > res[4] {
		return math.MaxFloat64
	}

	if trust < 1e-4 {
		return math.MaxFloat64
	}

	phi := CalculatePhi(res, t.Requirement)
	softField := math.Exp(-Alpha*load-Beta*queue) * trust

	if softField < 1e-9 {
		return math.MaxFloat64
	}

	return (t.Mass + phi) / softField
}

// ShouldMigrate reports whether candidate potential is meaningfully lower
// than current — by at least MigrationHysteresis relative — to justify a hop.
func ShouldMigrate(current, candidate float64) bool {
	if candidate >= current {
		return false
	}
	return (current-candidate)/current > MigrationHysteresis
}
