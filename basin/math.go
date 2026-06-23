package basin

import (
	"math"
	"math/bits"
)

// Multivector represents an element of Cl(3,0) as a dense 8-component array.
// Basis indices are bitmasks:
//
//	000 (0): 1    (scalar)
//	001 (1): e1   (compute)
//	010 (2): e2   (memory)
//	100 (4): e3   (network)
//	011 (3): e12  (compute-memory plane)
//	101 (5): e13  (compute-network plane)
//	110 (6): e23  (memory-network plane)
//	111 (7): e123 (unit pseudoscalar)
type Multivector [8]float64

var (
	cayleyRes  [8][8]int
	cayleySign [8][8]float64
	gradeTable [8]int
)

func init() {
	// Precompute the Cl(3,0) Cayley tables once at startup.
	for i := 0; i < 8; i++ {
		gradeTable[i] = bits.OnesCount(uint(i))
		for j := 0; j < 8; j++ {
			cayleyRes[i][j] = i ^ j
			cayleySign[i][j] = computeCanonicalSign(i, j)
		}
	}
}

func computeCanonicalSign(a, b int) float64 {
	swaps := 0
	for i := 1; i < 3; i++ {
		mask := (1 << i) - 1
		bLower := b & mask
		ones := bits.OnesCount(uint(bLower))
		if (a>>i)&1 == 1 {
			swaps += ones
		}
	}
	if swaps%2 == 1 {
		return -1.0
	}
	return 1.0
}

// NewVector injects raw orthogonal capacities into the grade-1 subspace.
func NewVector(compute, memory, network float64) Multivector {
	var mv Multivector
	mv[1] = compute // e1
	mv[2] = memory  // e2
	mv[4] = network // e3
	return mv
}

// GeometricProduct computes AB = A.B + A^B.
func GeometricProduct(a, b Multivector) Multivector {
	var res Multivector
	for i := 0; i < 8; i++ {
		if a[i] == 0 {
			continue
		}
		for j := 0; j < 8; j++ {
			if b[j] == 0 {
				continue
			}
			target := cayleyRes[i][j]
			res[target] += a[i] * b[j] * cayleySign[i][j]
		}
	}
	return res
}

// Wedge computes the outer (exterior) product A^B. Only disjoint basis
// components survive — sharing any axis annihilates the term.
func Wedge(a, b Multivector) Multivector {
	var res Multivector
	for i := 0; i < 8; i++ {
		if a[i] == 0 {
			continue
		}
		for j := 0; j < 8; j++ {
			if b[j] == 0 {
				continue
			}
			if (i & j) == 0 {
				target := cayleyRes[i][j]
				res[target] += a[i] * b[j] * cayleySign[i][j]
			}
		}
	}
	return res
}

// GradeProjection returns the homogeneous-grade slice of mv.
func GradeProjection(mv Multivector, grade int) Multivector {
	var res Multivector
	for i := 0; i < 8; i++ {
		if gradeTable[i] == grade {
			res[i] = mv[i]
		}
	}
	return res
}

// NormSq returns <A.~A>_0. In Cl(3,0) this collapses to the Euclidean
// sum of squared components.
func (mv Multivector) NormSq() float64 {
	sum := 0.0
	for i := 0; i < 8; i++ {
		sum += mv[i] * mv[i]
	}
	return sum
}

// Norm returns the multivector magnitude.
func (mv Multivector) Norm() float64 {
	return math.Sqrt(mv.NormSq())
}

// CalculatePhi returns the scale-free shape mismatch phi ∈ [0, 1] between
// two resource vectors, defined as ||a^r|| / (||a||·||r||). phi = 0 means the
// vectors are parallel (same shape), phi = 1 means they are orthogonal.
func CalculatePhi(a, r Multivector) float64 {
	denom := a.Norm() * r.Norm()
	if denom < 1e-9 {
		return 0.0
	}
	w := Wedge(a, r)
	return w.Norm() / denom
}
