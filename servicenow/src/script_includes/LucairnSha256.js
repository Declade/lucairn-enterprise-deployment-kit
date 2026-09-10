/*
 * LucairnSha256 — Script Include (Lucairn for Now Assist)
 *
 * Pure-JavaScript SHA-256 producing LOWERCASE HEX over the UTF-8 encoding of a
 * string. No platform API is used.
 *
 * Why pure JS rather than GlideDigest: the Lucairn service's seal-cert contract
 * requires `sha256:<64 lowercase hex>` (see servicenow/README.md § Wire
 * contract). The GlideDigest helpers documented for scoped apps return BASE64,
 * and the availability of a hex variant differs across releases. Rather than
 * guess a platform API we cannot verify before the instance test, this
 * implementation is self-contained and locally unit-tested against the NIST
 * FIPS 180-4 example vectors plus the RFC-4231-style empty-string vector.
 *
 * If a hex-capable platform digest is confirmed on the target release during the
 * PDI verification run, swapping the body of hexOfUtf8() is a one-function
 * change; the unit tests in servicenow/test/sha256.test.js are the contract.
 *
 * ES5 only (Rhino-compatible). No let/const/arrow functions/template literals.
 */
var LucairnSha256 = (function () {
    'use strict';

    var K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];

    /**
     * Encode a JS string as an array of UTF-8 byte values (0-255).
     *
     * Surrogate pairs are combined into a single code point; a lone (unpaired)
     * surrogate is encoded as U+FFFD so the function is total — it never throws
     * and never emits invalid UTF-8. That matters because the hashed bytes are
     * what the certificate binds to: a throw here would surface as a generic
     * adapter error and, under fail-closed, block a run for a reason nobody can
     * diagnose.
     */
    function utf8Bytes(str) {
        var out = [];
        var i;
        var cp;
        var s = String(str);
        for (i = 0; i < s.length; i++) {
            cp = s.charCodeAt(i);
            if (cp >= 0xd800 && cp <= 0xdbff) {
                var next = (i + 1 < s.length) ? s.charCodeAt(i + 1) : 0;
                if (next >= 0xdc00 && next <= 0xdfff) {
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (next - 0xdc00);
                    i++;
                } else {
                    cp = 0xfffd;
                }
            } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                cp = 0xfffd;
            }

            if (cp < 0x80) {
                out.push(cp);
            } else if (cp < 0x800) {
                out.push(0xc0 | (cp >> 6));
                out.push(0x80 | (cp & 0x3f));
            } else if (cp < 0x10000) {
                out.push(0xe0 | (cp >> 12));
                out.push(0x80 | ((cp >> 6) & 0x3f));
                out.push(0x80 | (cp & 0x3f));
            } else {
                out.push(0xf0 | (cp >> 18));
                out.push(0x80 | ((cp >> 12) & 0x3f));
                out.push(0x80 | ((cp >> 6) & 0x3f));
                out.push(0x80 | (cp & 0x3f));
            }
        }
        return out;
    }

    function rotr(x, n) {
        return ((x >>> n) | (x << (32 - n))) >>> 0;
    }

    function toHex32(x) {
        var hex = (x >>> 0).toString(16);
        while (hex.length < 8) {
            hex = '0' + hex;
        }
        return hex;
    }

    /** SHA-256 over an array of byte values; returns lowercase hex. */
    function hexOfBytes(bytes) {
        var h = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ];

        var msg = bytes.slice(0);
        var bitLenHi = Math.floor(bytes.length / 0x20000000);
        var bitLenLo = (bytes.length * 8) >>> 0;

        msg.push(0x80);
        while ((msg.length % 64) !== 56) {
            msg.push(0x00);
        }
        msg.push((bitLenHi >>> 24) & 0xff);
        msg.push((bitLenHi >>> 16) & 0xff);
        msg.push((bitLenHi >>> 8) & 0xff);
        msg.push(bitLenHi & 0xff);
        msg.push((bitLenLo >>> 24) & 0xff);
        msg.push((bitLenLo >>> 16) & 0xff);
        msg.push((bitLenLo >>> 8) & 0xff);
        msg.push(bitLenLo & 0xff);

        var w = new Array(64);
        var block;
        var i;

        for (block = 0; block < msg.length; block += 64) {
            for (i = 0; i < 16; i++) {
                w[i] = ((msg[block + i * 4] << 24) |
                        (msg[block + i * 4 + 1] << 16) |
                        (msg[block + i * 4 + 2] << 8) |
                        (msg[block + i * 4 + 3])) >>> 0;
            }
            for (i = 16; i < 64; i++) {
                var s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
                var s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
                w[i] = (((w[i - 16] + s0) >>> 0) + ((w[i - 7] + s1) >>> 0)) >>> 0;
            }

            var a = h[0], b = h[1], c = h[2], d = h[3];
            var e = h[4], f = h[5], g = h[6], hh = h[7];

            for (i = 0; i < 64; i++) {
                var S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
                var ch = ((e & f) ^ ((~e >>> 0) & g)) >>> 0;
                var temp1 = (hh + S1) >>> 0;
                temp1 = (temp1 + ch) >>> 0;
                temp1 = (temp1 + K[i]) >>> 0;
                temp1 = (temp1 + w[i]) >>> 0;
                var S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
                var maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
                var temp2 = (S0 + maj) >>> 0;

                hh = g;
                g = f;
                f = e;
                e = (d + temp1) >>> 0;
                d = c;
                c = b;
                b = a;
                a = (temp1 + temp2) >>> 0;
            }

            h[0] = (h[0] + a) >>> 0;
            h[1] = (h[1] + b) >>> 0;
            h[2] = (h[2] + c) >>> 0;
            h[3] = (h[3] + d) >>> 0;
            h[4] = (h[4] + e) >>> 0;
            h[5] = (h[5] + f) >>> 0;
            h[6] = (h[6] + g) >>> 0;
            h[7] = (h[7] + hh) >>> 0;
        }

        return toHex32(h[0]) + toHex32(h[1]) + toHex32(h[2]) + toHex32(h[3]) +
               toHex32(h[4]) + toHex32(h[5]) + toHex32(h[6]) + toHex32(h[7]);
    }

    return {
        /** Lowercase hex SHA-256 of the UTF-8 encoding of `str`. */
        hexOfUtf8: function (str) {
            return hexOfBytes(utf8Bytes(str));
        },

        /** Wire-shaped digest: "sha256:<64 lowercase hex>". */
        wireOfUtf8: function (str) {
            return 'sha256:' + hexOfBytes(utf8Bytes(str));
        },

        /** Exposed for unit tests only. */
        _utf8Bytes: utf8Bytes,

        type: 'LucairnSha256'
    };
})();

/* Node test-harness export. Ignored by the ServiceNow (Rhino) runtime, which
 * has no `module` global. */
if (typeof module !== 'undefined' && module.exports) {
    module.exports = LucairnSha256;
}
