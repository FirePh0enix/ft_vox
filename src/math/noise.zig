// https://github.com/SRombauts/SimplexNoise/blob/master/src/SimplexNoise.cpp

const perm: [256]u8 = .{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103, 30,  69,  142,
    8,   99,  37,  240, 21,  10,  23,  190, 6,   148, 247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203,
    117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175, 74,  165,
    71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,  41,
    55,  46,  245, 40,  244, 102, 143, 54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,
    18,  169, 200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250,
    124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207, 206, 59,  227, 47,  16,  58,  17,  182, 189,
    28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104, 218, 246, 97,  228, 251, 34,
    242, 193, 238, 210, 144, 12,  191, 179, 162, 241, 81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,
    181, 199, 106, 157, 184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,  222, 114,
    67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

inline fn hash(v: i32) i32 {
    @setRuntimeSafety(false);
    return @intCast(perm[@as(u8, @truncate(@as(u32, @bitCast(v))))]);
}

fn grad2D(hash_value: i32, x: f32, y: f32) f32 {
    const h = hash_value & 0x3F;
    const u = if (h < 4) x else y;
    const v = if (h < 4) y else x;
    return (if (h & 1 == 1) -u else u) + (if (h & 2 == 2) -2.0 * v else 2.0 * v);
}

pub fn simplex2D(x: f32, y: f32) f32 {
    var n0: f32 = 0.0;
    var n1: f32 = 0.0;
    var n2: f32 = 0.0;

    const F2 = 0.366025403;
    const G2 = 0.211324865;

    const s = (x + y) * F2;
    const xs = x + s;
    const ys = y + s;
    const i: f32 = @floor(xs);
    const j: f32 = @floor(ys);

    const t: f32 = (i + j) * G2;
    const X0: f32 = i - t;
    const Y0: f32 = j - t;
    const x0 = x - X0;
    const y0 = y - Y0;

    var @"i1": f32 = 0.0;
    var j1: f32 = 0.0;
    if (x0 > y0) {
        @"i1" = 1.0;
        j1 = 0.0;
    } else {
        @"i1" = 0.0;
        j1 = 1.0;
    }

    const x1 = x0 - @"i1" + G2;
    const y1 = y0 - j1 + G2;
    const x2 = x0 - 1.0 + 2.0 * G2;
    const y2 = y0 - 1.0 + 2.0 * G2;

    const gi0 = hash(@as(i32, @intFromFloat(i)) + hash(@intFromFloat(j)));
    const gi1 = hash(@as(i32, @intFromFloat(i + @"i1")) + hash(@intFromFloat(j + j1)));
    const gi2 = hash(@as(i32, @intFromFloat(i + 1)) + hash(@intFromFloat(j + 1)));

    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 < 0.0) {
        n0 = 0.0;
    } else {
        t0 *= t0;
        n0 = t0 * t0 * grad2D(gi0, x0, y0);
    }

    var t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 < 0.0) {
        n1 = 0.0;
    } else {
        t1 *= t1;
        n1 = t1 * t1 * grad2D(gi1, x1, y1);
    }

    // Calculate the contribution from the third corner
    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 < 0.0) {
        n2 = 0.0;
    } else {
        t2 *= t2;
        n2 = t2 * t2 * grad2D(gi2, x2, y2);
    }

    // Add contributions from each corner to get the final noise value.
    // The result is scaled to return values in the interval [-1,1].
    return 45.23065 * (n0 + n1 + n2);
}

fn fractalNoise(x: f32, z: f32, octaves: usize, frequency: f32, amplitude: f32, lacunarity: f32, persistence: f32) f32 {
    var output: f32 = 0.0;
    var denom: f32 = 0.0;
    var f: f32 = frequency;
    var a: f32 = amplitude;

    for (0..octaves) |i| {
        _ = i;
        output += a * simplex2D(x * f, z * f);
        denom += a;

        f *= lacunarity;
        a *= persistence;
    }

    return output / denom;
}
