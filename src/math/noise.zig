// https://github.com/SRombauts/SimplexNoise/blob/master/src/SimplexNoise.cpp
const std = @import("std");

const default_perm: [256]u8 = .{
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

var perm: [256]u8 = default_perm;

pub fn seed(seed_value: u64) void {
    var rng = std.Random.DefaultPrng.init(seed_value);

    for (0..256) |index| {
        const v: u8 = @truncate(rng.next());
        perm[index] = v;
    }
}

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

    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 < 0.0) {
        n2 = 0.0;
    } else {
        t2 *= t2;
        n2 = t2 * t2 * grad2D(gi2, x2, y2);
    }

    // The result is scaled to return values in the interval [-1,1].
    return 45.23065 * (n0 + n1 + n2);
}

fn grad3D(hash_value: i32, x: f32, y: f32, z: f32) f32 {
    const h: i32 = hash_value & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return if ((h & 1) == 1) -u else u + if ((h & 2) > 0) -v else v;
}

pub fn simplex3D(x: f32, y: f32, z: f32) f32 {
    var n0: f32 = 0.0;
    var n1: f32 = 0.0;
    var n2: f32 = 0.0;
    var n3: f32 = 0.0;

    const F3: f32 = 1.0 / 3.0;
    const G3: f32 = 1.0 / 6.0;

    const s: f32 = (x + y + z) * F3;

    const i: f32 = @floor(x + s);
    const j: f32 = @floor(y + s);
    const k: f32 = @floor(z + s);

    const t: f32 = (i + j + k) * G3;
    const X0: f32 = i - t;
    const Y0: f32 = j - t;
    const Z0: f32 = k - t;
    const x0: f32 = x - X0;
    const y0: f32 = y - Y0;
    const z0: f32 = z - Z0;

    var @"i1": f32 = 0;
    var j1: f32 = 0;
    var k1: f32 = 0;

    var @"i2": f32 = 0;
    var j2: f32 = 0;
    var k2: f32 = 0;

    if (x0 >= y0) {
        if (y0 >= z0) {
            @"i1" = 1;
            j1 = 0;
            k1 = 0;
            @"i2" = 1;
            j2 = 1;
            k2 = 0;
        } else if (x0 >= z0) {
            @"i1" = 1;
            j1 = 0;
            k1 = 0;
            @"i2" = 1;
            j2 = 0;
            k2 = 1;
        } else {
            @"i1" = 0;
            j1 = 0;
            k1 = 1;
            @"i2" = 1;
            j2 = 0;
            k2 = 1;
        }
    } else {
        if (y0 < z0) {
            @"i1" = 0;
            j1 = 0;
            k1 = 1;
            @"i2" = 0;
            j2 = 1;
            k2 = 1;
        } else if (x0 < z0) {
            @"i1" = 0;
            j1 = 1;
            k1 = 0;
            @"i2" = 0;
            j2 = 1;
            k2 = 1;
        } else {
            @"i1" = 0;
            j1 = 1;
            k1 = 0;
            @"i2" = 1;
            j2 = 1;
            k2 = 0;
        }
    }

    const x1: f32 = x0 - @"i1" + G3;
    const y1: f32 = y0 - j1 + G3;
    const z1: f32 = z0 - k1 + G3;
    const x2: f32 = x0 - @"i2" + 2.0 * G3;
    const y2: f32 = y0 - j2 + 2.0 * G3;
    const z2: f32 = z0 - k2 + 2.0 * G3;
    const x3: f32 = x0 - 1.0 + 3.0 * G3;
    const y3: f32 = y0 - 1.0 + 3.0 * G3;
    const z3: f32 = z0 - 1.0 + 3.0 * G3;

    const gi0: i32 = hash(@as(i32, @intFromFloat(i)) + hash(intFromFloat(i32, j) + hash(@intFromFloat(k))));
    const gi1: i32 = hash(@as(i32, @intFromFloat(i + @"i1")) + hash(intFromFloat(i32, j + j1) + hash(@intFromFloat(k + k1))));
    const gi2: i32 = hash(@as(i32, @intFromFloat(i + @"i2")) + hash(@as(i32, @intFromFloat(j + j2)) + hash(@intFromFloat(k + k2))));
    const gi3: i32 = hash(@as(i32, @intFromFloat(i + 1)) + hash(@as(i32, @intFromFloat(j + 1)) + hash(intFromFloat(i32, k) + 1)));

    var t0: f32 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 < 0) {
        n0 = 0.0;
    } else {
        t0 *= t0;
        n0 = t0 * t0 * grad3D(gi0, x0, y0, z0);
    }
    var t1: f32 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 < 0) {
        n1 = 0.0;
    } else {
        t1 *= t1;
        n1 = t1 * t1 * grad3D(gi1, x1, y1, z1);
    }
    var t2: f32 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 < 0) {
        n2 = 0.0;
    } else {
        t2 *= t2;
        n2 = t2 * t2 * grad3D(gi2, x2, y2, z2);
    }
    var t3: f32 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 < 0) {
        n3 = 0.0;
    } else {
        t3 *= t3;
        n3 = t3 * t3 * grad3D(gi3, x3, y3, z3);
    }

    return 32.0 * (n0 + n1 + n2 + n3);
}

fn intFromFloat(comptime T: type, f: anytype) T {
    return @intFromFloat(f);
}

pub fn fractalNoise(octaves: usize, x: f32, y: f32) f32 {
    const frequency: f32 = 1.0;
    const amplitude: f32 = 1.0;
    const lacunarity: f32 = 2.0;
    const persistence: f32 = 0.5;

    var output: f32 = 0.0;
    var denom: f32 = 0.0;
    var f: f32 = frequency;
    var a: f32 = amplitude;

    for (0..octaves) |i| {
        _ = i;
        output += a * simplex2D(x * f, y * f);
        denom += a;

        f *= lacunarity;
        a *= persistence;
    }

    return output / denom;
}
