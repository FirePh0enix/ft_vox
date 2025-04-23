const std = @import("std");
const World = @import("voxel/World.zig");

pub const Biome = enum {
    // non-inland biomes
    cold_ocean,
    ocean,
    warm_ocean,
    mushroom_fields,
    deep_cold_ocean,
    deep_ocean,
    deep_warm_ocean,

    // inland surface biomes
    frozen_river,
    river,
    stony_shore,

    // beach biomes
    snowy_beach,
    beach,
    desert,

    // middle biomes
    snowy_plains,
    plains,
    savanna,
    forest,
    jungle,
    frozen_peaks,
    stony_peaks,

    pub fn getColor(biome: Biome) u32 {
        return switch (biome) {
            .ocean => 0xff030364,
            .cold_ocean => 0xff0e5682,
            .warm_ocean => 0xff0099cc,
            .mushroom_fields => 0xffb38c6d,

            .deep_cold_ocean => 0xff0d3b56,
            .deep_ocean => 0xff212138,
            .deep_warm_ocean => 0xff5d99a2,

            .frozen_river => 0xff98c8d1,
            .river => 0xff1313d2,
            .stony_shore => 0xff8d6e63,

            .snowy_beach => 0xffe1e1e1,
            .beach => 0xfff1e2b3,
            .desert => 0xffc2b280,

            .snowy_plains => 0xffd8d8d8,
            .plains => 0xff87aa5e,
            .savanna => 0xff9e7b43,
            .forest => 0xff355e30,
            .jungle => 0xff1b6632,

            .frozen_peaks => 0xff8f9baf,
            .stony_peaks => 0xff5f3f2a,
        };
    }
};

pub const Noise = struct {
    continentalness: f32,
    erosion: f32,
    peaks_and_valleys: f32,
    weirdness: f32,
    temperature: f32,
    humidity: f32,
};

pub const Continentalness = enum(u32) {
    mushroom_field,
    deep_ocean,
    ocean,
    coast,
    near_inland,
    mid_inland,
    far_inland,
};

pub const PeakValleys = enum(u32) {
    valleys,
    low,
    mid,
    high,
    peaks,
};

pub const Temperature = enum(u32) {
    coldest,
    cold,
    mid,
    hot,
    hottest,

    pub fn getColor(self: Temperature) u32 {
        return switch (self) {
            .coldest => 0xffa5e2fa,
            .cold => 0xff1673c9,
            .mid => 0xff7f868f,
            .hot => 0xffeb7457,
            .hottest => 0xffd92118,
        };
    }
};

const BlendedBiome = struct {
    base_height: f32,
    squish: f32,
};

/// Return a Biome by analyzing continentalness, erosion, peaks and valleys, weirdness, temperature and humidity.
/// Biome are categorized as either Non Inland Biomes (Ocean...) and Inland Biomes (plains...).
pub fn getBiome(noise: Noise) Biome {
    const cont = getContinentalnessLevel(noise.continentalness);
    const ero = getErosionLevel(noise.erosion);
    const pv = getPeaksValleysLevel(noise.peaks_and_valleys);
    const weird = noise.weirdness;

    const temp = getTemperatureLevel(noise.temperature);
    const hum = getHumidityLevel(noise.humidity);

    return switch (cont) {
        .ocean, .deep_ocean, .mushroom_field => getNonInlandBiomes(cont, temp),
        .coast, .near_inland, .mid_inland, .far_inland => getInlandSurfaceBiomes(cont, pv, ero, temp, hum, weird),
    };
}

/// Returns a non Inland biome based on continentalness and temperature.
fn getNonInlandBiomes(cont: Continentalness, temp: Temperature) Biome {
    return switch (cont) {
        .ocean => switch (temp) {
            .coldest, .cold => .cold_ocean,
            .mid => .ocean,
            .hot, .hottest => .warm_ocean,
        },
        .deep_ocean => switch (temp) {
            .cold, .coldest => .deep_cold_ocean,
            .mid => .deep_ocean,
            .hot, .hottest => .deep_warm_ocean,
        },
        .mushroom_field => .mushroom_fields,
        else => .ocean,
    };
}

/// Return an Inland Biomes based mainly on continentalness, then peaks and valleys, erosion, temperature, humidity and weirdness.
/// Inland Biomes include river, Middle Biome, Beach Biome, Plateau Biome and Shattered Biome.
fn getInlandSurfaceBiomes(cont: Continentalness, pv: PeakValleys, ero: u32, temp: Temperature, hum: u32, weird: f32) Biome {
    return switch (cont) {
        .coast, .near_inland => switch (pv) {
            .valleys => switch (temp) {
                .cold, .coldest => .frozen_river,
                .mid, .hot, .hottest => .river,
            },
            .mid => switch (ero) {
                0, 1, 2 => .stony_shore,
                3 => getMiddleBiome(temp, hum, weird),
                4, 5, 6 => if (weird < 0) getBeachBiomes(temp) else getMiddleBiome(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .low => switch (ero) {
                0, 1, 2 => .stony_shore,
                3, 4 => getBeachBiomes(temp),
                5 => if (weird < 0) getBeachBiomes(temp) else if (weird > 0 and (temp == .coldest or temp == .cold)) getMiddleBiome(temp, hum, weird) else .plains,
                6 => getMiddleBiome(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .high, .peaks => getMiddleBiome(temp, hum, weird),
        },
        .mid_inland => switch (pv) {
            .valleys => switch (ero) {
                0, 1 => getMiddleBiome(temp, hum, weird),
                2, 3, 4, 5 => if (temp == .coldest) .frozen_river else .river,
                6 => .frozen_river,
                else => .river,
            },
            .low => getMiddleBiome(temp, hum, weird),
            .mid => switch (ero) {
                0 => getPlateauBiomes(temp, hum),
                1, 2, 3, 4, 5, 6 => getMiddleBiome(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .high => switch (ero) {
                0 => .frozen_peaks,
                1, 2 => getPlateauBiomes(temp, hum),
                3, 4, 6 => getMiddleBiome(temp, hum, weird),
                5 => getShatteredBiomes(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .peaks => switch (ero) {
                0, 1 => if (temp == .coldest or temp == .cold or temp == .mid) .frozen_peaks else .stony_peaks,
                2 => getPlateauBiomes(temp, hum),
                3, 4, 6 => getMiddleBiome(temp, hum, weird),
                5 => getShatteredBiomes(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
        },
        .far_inland => switch (pv) {
            .valleys => switch (ero) {
                0, 1 => getMiddleBiome(temp, hum, weird),
                2, 3, 4, 5 => if (temp == .coldest) .frozen_river else .river,
                6 => .frozen_river,
                else => getMiddleBiome(temp, hum, weird),
            },
            .low => getMiddleBiome(temp, hum, weird),
            .mid => switch (ero) {
                0, 1, 2 => getPlateauBiomes(temp, hum),
                3, 4, 5, 6 => getMiddleBiome(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .high => switch (ero) {
                0 => .frozen_peaks,
                1, 2 => getPlateauBiomes(temp, hum),
                3, 4, 6 => getMiddleBiome(temp, hum, weird),
                5 => getShatteredBiomes(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
            .peaks => switch (ero) {
                0, 1 => if (temp == .coldest or temp == .cold or temp == .mid) .frozen_peaks else .stony_peaks,
                2 => getPlateauBiomes(temp, hum),
                3, 4, 6 => getMiddleBiome(temp, hum, weird),
                5 => getShatteredBiomes(temp, hum, weird),
                else => getMiddleBiome(temp, hum, weird),
            },
        },
        else => .plains,
    };
}

/// Returns a beach biome based on temperature.
fn getBeachBiomes(temp: Temperature) Biome {
    return switch (temp) {
        .coldest => .snowy_beach,
        .cold, .mid, .hot => .beach,
        .hottest => .desert,
    };
}

/// Returns a middle biome based on temperature, humidity, and weirdness.
/// Plains, forest, savanna, jungle, desert...
fn getMiddleBiome(temp: Temperature, hum: u32, weird: f32) Biome {
    return switch (temp) {
        .coldest => .snowy_plains,
        .cold => switch (hum) {
            0, 1 => .plains,
            2, 3, 4 => .forest,
            else => .plains,
        },
        .mid => switch (hum) {
            0, 1 => .plains,
            2, 3, 4 => .forest,
            else => .plains,
        },
        .hot => switch (hum) {
            0, 1 => .savanna,
            2 => if (weird < 0) .forest else .plains,
            3, 4 => .jungle,
            else => .plains,
        },
        .hottest => .desert,
    };
}

/// Return a shattered biomes based on temperature, humidity and weirdness.
/// Savanna, jungle, plains, desert...
fn getShatteredBiomes(temp: Temperature, hum: u32, weird: f32) Biome {
    return switch (temp) {
        .coldest, .cold, .mid, .hot => switch (hum) {
            0, 1 => .savanna,
            2 => if (weird < 0) .jungle else .plains,
            3, 4 => .jungle,
            else => .plains,
        },
        .hottest => .desert,
    };
}

/// Return a plateau biomes based on temperature, humidity.
/// Snowy plains, forest or plains...
fn getPlateauBiomes(temp: Temperature, hum: u32) Biome {
    return switch (hum) {
        0 => .snowy_plains,
        1, 2, 3, 4 => if (temp == .coldest) .snowy_plains else .forest,
        else => .plains,
    };
}

// https://gamedev.stackexchange.com/questions/208485/biome-blending-using-multiple-biome-altitude-humidity-points
// https://www.reddit.com/r/proceduralgeneration/comments/uhlkcb/any_tips_for_blending_procedurally_generated/
pub fn blendSplineAttributes(world: *const World, fx: f32, fz: f32) BlendedBiome {
    var total_weight: f32 = 0.0;
    var blended_height: f32 = 0.0;
    var blended_squish: f32 = 0.0;

    // 2 radius allows me to create a 5x5 grid to check around.
    const sample_radius: i32 = 2;
    var dx: i32 = -sample_radius;
    while (dx <= sample_radius) : (dx += 1) {
        var dz: i32 = -sample_radius;
        while (dz <= sample_radius) : (dz += 1) {
            const sx: f32 = fx + @as(f32, @floatFromInt(dx * 4));
            const sz: f32 = fz + @as(f32, @floatFromInt(dz * 4));

            const biome = getBiome(getNoise(world, sx, sz));
            const height = getSplineLevel(world, sx, sz, biome);
            const squish = getSplineFactor(world, sx, sz);

            // The distance will help us to determine which biome will affect more.
            // If it's closer then he will affect more, the most the distance longer, the less he will affect.
            const distance: f32 = std.math.sqrt(@as(f32, (@floatFromInt(@abs(dx * dx + dz * dz)))));

            // Squaring the distance causes the weight to decrease as the distance increases.
            // + 1.0 ensure we do not divide per 0.
            const weight: f32 = 1.0 / (distance * distance + 1.0);

            total_weight += weight;
            blended_height += height * weight;
            blended_squish += squish * weight;
        }
    }

    return .{ .base_height = blended_height / total_weight, .squish = blended_squish / total_weight };
}

/// Return a base height in world scale, mainly, its the noise that decide the height but each biome can affect a little bit.
/// For example I flatten more desert and elevate more peaks.
pub fn getSplineLevel(world: *const World, x: f32, z: f32, biome: Biome) f32 {
    const noise = getNoise(world, x, z);

    const c_height = calculateContHeight(noise.continentalness);
    const e_height = calculateEroHeight(noise.erosion);
    const pv_height = calculatePeaksValleyHeight(noise.weirdness);

    var adjusted_c_height = c_height;
    var adjusted_e_height = e_height;
    var adjusted_pv_height = pv_height;

    switch (biome) {
        .frozen_river, .river, .cold_ocean, .ocean, .warm_ocean, .deep_cold_ocean, .deep_ocean, .deep_warm_ocean => {
            adjusted_c_height *= 0.6;
            adjusted_e_height *= 0.5;
            adjusted_pv_height *= 0.3;
        },

        .mushroom_fields, .stony_shore, .snowy_plains, .plains, .savanna, .snowy_beach, .beach, .desert, .forest, .jungle => {
            adjusted_c_height *= 1.5;
            adjusted_e_height *= 1.2;
            adjusted_pv_height *= 0.7;
        },

        .stony_peaks, .frozen_peaks => {
            adjusted_c_height *= 1.3;
            adjusted_e_height *= 1.2;
            adjusted_pv_height *= 1.4;
        },
    }

    return adjusted_c_height + adjusted_e_height + adjusted_pv_height * getBiomeHeightMultiplier(biome);
}

/// Local multiplier, each Biome can affect themselves in his local scale.
pub fn getBiomeHeightMultiplier(biome: Biome) f32 {
    return switch (biome) {
        .deep_cold_ocean, .deep_ocean, .deep_warm_ocean => 0.4,
        .cold_ocean, .ocean, .warm_ocean, .mushroom_fields => 0.5,
        .frozen_river, .river, .stony_shore => 0.6,

        .savanna, .forest, .snowy_plains, .plains, .snowy_beach, .beach, .desert => 0.8,

        .jungle => 1.2,

        .frozen_peaks, .stony_peaks => 2.5,
    };
}

/// Segment-based interpolation (like a spline) using lerp to smoothly map continentalness to height.
fn calculateContHeight(cont: f32) f32 {
    if (cont < 0.3) {
        return std.math.lerp(25.0, 40.0, (cont + 1.0) / 1.3);
    } else if (cont < 0.6) {
        return std.math.lerp(40.0, 60.0, (cont - 0.3) / 0.3);
    } else {
        return std.math.lerp(60.0, 100.0, (cont - 0.6) / 0.4);
    }
}

/// Segment-based interpolation (like a spline) using lerp to smoothly map erosion to height.
fn calculateEroHeight(e: f32) f32 {
    return std.math.lerp(40.0, 10.0, (e + 1.0) * 0.5);
}

/// Segment-based interpolation (like a spline) using lerp to smoothly map peaks and valleys to height.
fn calculatePeaksValleyHeight(pv: f32) f32 {
    if (pv < 0.0) {
        return std.math.lerp(0.0, 5.0, (pv + 1.0));
    } else {
        return std.math.lerp(5.0, 25.0, pv);
    }
}

/// Combine continentalness, erosion, and weirdness factors to determine a density factor, which will decide if a block is solid or air.
pub fn getSplineFactor(world: *const World, x: f32, z: f32) f32 {
    const c = calculateContFactor(getContinentalness(world, x, z));
    const e = calculateEroFactor(getErosion(world, x, z));
    const pv = calculateWeirdnessFactor(getWeirdness(world, x, z));
    return c * e * pv;
}

/// Segment-based interpolation using lerp to smoothly map continentalness factor to a height multiplier.
fn calculateContFactor(c: f32) f32 {
    return std.math.lerp(0.8, 1.2, (c + 1.0) * 0.5);
}

/// Segment-based interpolation using lerp to smoothly map erosion factor to a height multiplier.
fn calculateEroFactor(e: f32) f32 {
    return std.math.lerp(0.6, 1.3, (e + 1.0) * 0.5);
}

/// Segment-based interpolation using lerp to smoothly map weirdness factor to a height multiplier.
fn calculateWeirdnessFactor(pv: f32) f32 {
    return std.math.lerp(0.7, 1.4, (pv + 1.0) * 0.5);
}

/// Return 6 parameters used in Noise: continentalness, erosion, weirdness, peaks and valleys, temperature, and humidity.
pub fn getNoise(world: *const World, x: f32, z: f32) Noise {
    const w = getWeirdness(world, x, z);

    return .{
        .continentalness = getContinentalness(world, x, z),
        .erosion = getErosion(world, x, z),
        .weirdness = w,
        .peaks_and_valleys = 1.0 - @abs(3.0 * @abs(w) - 2.0),
        .temperature = getTemperature(world, x, z),
        .humidity = getHumidity(world, x, z),
    };
}

/// Return a value between -1 and 1 representing continentalness: 0 -> non-inland biomes, and 1 -> inland biomes.
fn getContinentalness(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(5, x / 500.0, z / 500.0);
}

/// Return a value between -1 and 1 representing erosion: 0 -> flat terrain, and 1 -> bumpy terrain.
fn getErosion(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(4, x / 600.0, z / 600.0);
}

/// Return a value between -1 and 1 representing weirdness: some biomes depend on its value.
fn getWeirdness(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(3, x / 200.0, z / 200.0);
}

/// Return a value between -1 and 1 representing temperature: 0 -> cold, 1 -> hot.
fn getTemperature(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(1, x / 400.0, z / 400.0);
}

/// Return a value between -1 and 1 representing humidity: 0 -> humid, 1 -> dry.
fn getHumidity(world: *const World, x: f32, z: f32) f32 {
    return world.noise.fractal2D(2, x / 400.0, z / 400.0);
}

/// Return the Continentalness level separated by specific ranges.
pub fn getContinentalnessLevel(c: f32) Continentalness {
    if (c >= -1.0 and c < -0.9) {
        return .mushroom_field;
    } else if (c >= -0.9 and c < -0.455) {
        return .deep_ocean;
    } else if (c >= -0.455 and c < -0.19) {
        return .ocean;
    } else if (c >= -0.19 and c < -0.11) {
        return .coast;
    } else if (c >= -0.11 and c < 0.03) {
        return .near_inland;
    } else if (c >= 0.03 and c < 0.3) {
        return .mid_inland;
    } else {
        return .far_inland;
    }
}

/// Return the Erosion level separated by specific ranges.
pub fn getErosionLevel(e: f32) u32 {
    std.debug.assert(e >= -1.0 and e <= 1.0);

    if (e >= -1.0 and e < -0.78) {
        return 0;
    } else if (e >= -0.78 and e < -0.375) {
        return 1;
    } else if (e >= -0.375 and e < -0.2225) {
        return 2;
    } else if (e >= -0.2225 and e < 0.05) {
        return 3;
    } else if (e >= 0.05 and e < 0.45) {
        return 4;
    } else if (e >= 0.45 and e < 0.55) {
        return 5;
    } else {
        return 6;
    }
}

/// Return the Peaks and Valleys level separated by specific ranges.
pub fn getPeaksValleysLevel(pv: f32) PeakValleys {
    if (pv >= -1.0 and pv < -0.85) {
        return .valleys;
    } else if (pv >= -0.85 and pv < -0.6) {
        return .low;
    } else if (pv >= -0.6 and pv < 0.2) {
        return .mid;
    } else if (pv >= 0.2 and pv < -0.7) {
        return .high;
    } else {
        return .peaks;
    }
}

/// Return the Temperature level separated by specific ranges.
pub fn getTemperatureLevel(temp: f32) Temperature {
    std.debug.assert(temp >= -1.0 and temp <= 1.0);

    if (temp >= -1.0 and temp < -0.8) {
        return .coldest;
    } else if (temp >= -0.8 and temp < -0.15) {
        return .cold;
    } else if (temp >= -0.15 and temp < 0.2) {
        return .mid;
    } else if (temp >= 0.2 and temp < 0.55) {
        return .hot;
    } else {
        return .hottest;
    }
}

/// Return the Humidity level separated by specific ranges.
pub fn getHumidityLevel(hum: f32) u32 {
    std.debug.assert(hum >= -1.0 and hum <= 1.0);

    if (hum >= -1.0 and hum < -0.35) {
        return 0;
    } else if (hum >= -0.35 and hum < -0.1) {
        return 1;
    } else if (hum >= -0.1 and hum < 0.1) {
        return 2;
    } else if (hum >= 0.1 and hum < 0.3) {
        return 3;
    } else {
        return 4;
    }
}
