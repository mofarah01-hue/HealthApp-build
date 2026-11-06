import Foundation

// Support for the Swift ports of Mo's master script (WP-17). Everything here is internal to MGSignal and prefixed
// Script… (MGSignal is one module). None of it is part of Mo's script: it only checks inputs and re-creates the three
// numpy routines MS-07 uses (np.arange, np.interp, np.convolve(…, 'same')) and np.fft.rfft, so the port follows the
// script step by step. Python mirror of the same steps: scratchpad wp17 (verified against numpy on the PC).

/// Input checks. A failed check is a `Missing` that names the argument (R6): the script itself would return NaN or
/// raise, and a NaN must never reach a `Metric`.
enum ScriptGuard {
    static func finite(_ pairs: (String, Double)...) -> Missing? {
        for (name, value) in pairs where !value.isFinite {
            return Missing("\(name) is not a finite number")
        }
        return nil
    }

    static func positive(_ pairs: (String, Double)...) -> Missing? {
        for (name, value) in pairs where !(value > 0) {
            return Missing("\(name) must be greater than 0 (got \(value))")
        }
        return nil
    }

    static func allFinite(_ name: String, _ values: [Double]) -> Missing? {
        values.allSatisfy { $0.isFinite } ? nil : Missing("\(name) holds a value that is not a finite number")
    }
}

/// The numpy routines MS-07 calls, written to give the same numbers as numpy for the inputs MS-07 passes.
enum ScriptNumpy {
    /// np.cumsum
    static func cumsum(_ x: [Double]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(x.count)
        var acc = 0.0
        for v in x {
            acc += v
            out.append(acc)
        }
        return out
    }

    /// np.arange(start, stop, step) for float arguments: length ceil((stop − start) / step); element 1 is start + step;
    /// element i ≥ 2 is start + i · ((start + step) − start) (numpy's fill rule).
    static func arange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let count = Int(((stop - start) / step).rounded(.up))
        if count <= 0 { return [] }
        var out = [Double](repeating: start, count: count)
        if count > 1 {
            let next = start + step
            out[1] = next
            let delta = next - start
            if count > 2 {
                for i in 2..<count { out[i] = start + Double(i) * delta }
            }
        }
        return out
    }

    /// np.interp(x, xp, fp) for increasing x and strictly increasing xp: end values are held outside the range,
    /// inside it value = slope · (x − xp[j]) + fp[j] with j the last xp not above x.
    static func interp(_ x: [Double], _ xp: [Double], _ fp: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        var j = 0
        for (i, v) in x.enumerated() {
            if v <= xp[0] {
                out[i] = fp[0]
                continue
            }
            if v >= xp[xp.count - 1] {
                out[i] = fp[fp.count - 1]
                continue
            }
            while j < xp.count - 2 && xp[j + 1] <= v { j += 1 }
            let slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j])
            out[i] = slope * (v - xp[j]) + fp[j]
        }
        return out
    }

    /// np.diff
    static func diff(_ y: [Double]) -> [Double] {
        if y.count < 2 { return [] }
        return (0..<(y.count - 1)).map { y[$0 + 1] - y[$0] }
    }

    /// np.convolve(x, kernel, 'same') for an odd-length kernel and x.count ≥ kernel.count: the centred part of the
    /// full convolution, zeros beyond the ends.
    static func convolveSame(_ x: [Double], _ kernel: [Double]) -> [Double] {
        let n = x.count
        let half = (kernel.count - 1) / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for j in 0..<kernel.count {
                let idx = i + half - j
                if idx >= 0 && idx < n { s += kernel[j] * x[idx] }
            }
            out[i] = s
        }
        return out
    }
}

/// A Fourier transform of any length (Bluestein chirp-z over radix-2 FFTs), enough for `np.fft.rfft(x)` squared.
enum ScriptFFT {
    /// |np.fft.rfft(x)|² for bins 0 … n/2.
    static func rfftPower(_ x: [Double]) -> [Double] {
        let n = x.count
        let (re, im) = dft(re: x, im: [Double](repeating: 0, count: n))
        return (0...(n / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    /// Forward DFT, X[k] = Σ x[j] e^(−2πi jk/n), for any n ≥ 1.
    /// Bluestein: with w[k] = e^(−iπk²/n), X[k] = w[k] · Σ_j (x[j] w[j]) · conj(w[k − j]) — a convolution, done with
    /// zero-padded radix-2 FFTs of length m ≥ 2n − 1. k² is reduced modulo 2n so the angle stays small and exact.
    static func dft(re: [Double], im: [Double]) -> (re: [Double], im: [Double]) {
        let n = re.count
        if n == 1 { return (re, im) }
        var wr = [Double](repeating: 0, count: n)
        var wi = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let angle = Double.pi * Double((k * k) % (2 * n)) / Double(n)
            wr[k] = cos(angle)
            wi[k] = -sin(angle)
        }
        var m = 1
        while m < 2 * n - 1 { m <<= 1 }
        var ar = [Double](repeating: 0, count: m)
        var ai = [Double](repeating: 0, count: m)
        for k in 0..<n {
            ar[k] = re[k] * wr[k] - im[k] * wi[k]
            ai[k] = re[k] * wi[k] + im[k] * wr[k]
        }
        var br = [Double](repeating: 0, count: m)
        var bi = [Double](repeating: 0, count: m)
        br[0] = wr[0]
        bi[0] = -wi[0]
        for k in 1..<n {
            br[k] = wr[k]
            bi[k] = -wi[k]
            br[m - k] = wr[k]
            bi[m - k] = -wi[k]
        }
        radix2(&ar, &ai, inverse: false)
        radix2(&br, &bi, inverse: false)
        for k in 0..<m {
            let pr = ar[k] * br[k] - ai[k] * bi[k]
            let pi = ar[k] * bi[k] + ai[k] * br[k]
            ar[k] = pr
            ai[k] = pi
        }
        radix2(&ar, &ai, inverse: true)
        var outRe = [Double](repeating: 0, count: n)
        var outIm = [Double](repeating: 0, count: n)
        for k in 0..<n {
            outRe[k] = ar[k] * wr[k] - ai[k] * wi[k]
            outIm[k] = ar[k] * wi[k] + ai[k] * wr[k]
        }
        return (outRe, outIm)
    }

    /// In-place iterative radix-2 Cooley–Tukey FFT; the length must be a power of two ≥ 2. `inverse` flips the sign of
    /// the exponent and divides by the length.
    static func radix2(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var cosTable = [Double](repeating: 0, count: n / 2)
        var sinTable = [Double](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) {
            let angle = 2.0 * Double.pi * Double(k) / Double(n)
            cosTable[k] = cos(angle)
            sinTable[k] = inverse ? sin(angle) : -sin(angle)
        }
        var length = 2
        while length <= n {
            let half = length / 2
            let stride = n / length
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosTable[k * stride]
                    let wi = sinTable[k * stride]
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                re[i] *= scale
                im[i] *= scale
            }
        }
    }
}
