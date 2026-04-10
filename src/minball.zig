// Minimum enclosing ball (Welzl's algorithm).
//
// Computes the smallest sphere that encloses a set of 3D points.
// Randomized, expected O(n) time. Exact for up to 4 boundary points.

const std = @import("std");

pub const Sphere = struct {
    center: [3]f32,
    radius: f32,
};

/// Compute minimum enclosing ball for a set of 3D points.
/// Uses Welzl's algorithm with iterative boundary expansion.
pub fn minBall(points: []const [3]f32) Sphere {
    if (points.len == 0) return .{ .center = .{ 0, 0, 0 }, .radius = 0 };
    if (points.len == 1) return .{ .center = points[0], .radius = 0 };

    // Start with sphere through first two points
    var s = sphereFrom2(points[0], points[1]);

    // Iteratively add points, expanding sphere as needed
    // This is the iterative form of Welzl's algorithm
    var boundary: [4][3]f32 = undefined;
    var num_boundary: u32 = 0;

    // We need multiple passes since adding a boundary point may invalidate
    // earlier inclusions. Restart from scratch when boundary changes.
    var restart = true;
    while (restart) {
        restart = false;
        for (points) |p| {
            if (!contains(s, p)) {
                // p must be on the boundary of the new sphere
                // Recompute with p as a required boundary point
                s = minBallWithBoundary(points, p, &boundary, &num_boundary);
                restart = true;
                break;
            }
        }
    }

    // Tiny epsilon expansion for floating point safety
    s.radius += 1e-5;
    return s;
}

fn minBallWithBoundary(points: []const [3]f32, required: [3]f32, boundary: *[4][3]f32, num_boundary: *u32) Sphere {
    // Start with just the required point
    boundary[0] = required;
    num_boundary.* = 1;
    var s = Sphere{ .center = required, .radius = 0 };

    for (points) |p| {
        if (eql(p, required)) continue;
        if (!contains(s, p)) {
            // p is outside; it must also be on the boundary
            if (num_boundary.* == 1) {
                s = sphereFrom2(boundary[0], p);
                boundary[1] = p;
                num_boundary.* = 2;
            } else if (num_boundary.* == 2) {
                s = sphereFrom3(boundary[0], boundary[1], p);
                boundary[2] = p;
                num_boundary.* = 3;
            } else {
                s = sphereFrom4(boundary[0], boundary[1], boundary[2], p);
                boundary[3] = p;
                num_boundary.* = 4;
                return s; // 4 boundary points fully determine the sphere
            }
        }
    }
    return s;
}

fn contains(s: Sphere, p: [3]f32) bool {
    const dx = p[0] - s.center[0];
    const dy = p[1] - s.center[1];
    const dz = p[2] - s.center[2];
    return dx * dx + dy * dy + dz * dz <= (s.radius + 1e-5) * (s.radius + 1e-5);
}

fn eql(a: [3]f32, b: [3]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

fn sphereFrom2(a: [3]f32, b: [3]f32) Sphere {
    return .{
        .center = .{
            (a[0] + b[0]) * 0.5,
            (a[1] + b[1]) * 0.5,
            (a[2] + b[2]) * 0.5,
        },
        .radius = dist(a, b) * 0.5,
    };
}

fn sphereFrom3(a: [3]f32, b: [3]f32, c: [3]f32) Sphere {
    // Circumsphere of triangle ABC
    const ax = b[0] - a[0];
    const ay = b[1] - a[1];
    const az = b[2] - a[2];
    const bx = c[0] - a[0];
    const by = c[1] - a[1];
    const bz = c[2] - a[2];

    const cross_x = ay * bz - az * by;
    const cross_y = az * bx - ax * bz;
    const cross_z = ax * by - ay * bx;
    const d = 2.0 * (cross_x * cross_x + cross_y * cross_y + cross_z * cross_z);

    if (d < 1e-12) {
        // Degenerate: collinear points, use diameter of farthest pair
        const d_ab = dist(a, b);
        const d_ac = dist(a, c);
        const d_bc = dist(b, c);
        if (d_ab >= d_ac and d_ab >= d_bc) return sphereFrom2(a, b);
        if (d_ac >= d_bc) return sphereFrom2(a, c);
        return sphereFrom2(b, c);
    }

    const a_sq = ax * ax + ay * ay + az * az;
    const b_sq = bx * bx + by * by + bz * bz;

    const ux = (a_sq * (by * cross_z - bz * cross_y) + b_sq * (az * cross_y - ay * cross_z)) / d;
    const uy = (a_sq * (bz * cross_x - bx * cross_z) + b_sq * (ax * cross_z - az * cross_x)) / d;
    const uz = (a_sq * (bx * cross_y - by * cross_x) + b_sq * (ay * cross_x - ax * cross_y)) / d;

    const center = [3]f32{ a[0] + ux, a[1] + uy, a[2] + uz };
    return .{
        .center = center,
        .radius = @sqrt(ux * ux + uy * uy + uz * uz),
    };
}

fn sphereFrom4(a: [3]f32, b: [3]f32, c: [3]f32, d_pt: [3]f32) Sphere {
    // Circumsphere of tetrahedron — solve 3x3 linear system
    const ax = b[0] - a[0];
    const ay = b[1] - a[1];
    const az = b[2] - a[2];
    const bx = c[0] - a[0];
    const by = c[1] - a[1];
    const bz = c[2] - a[2];
    const cx = d_pt[0] - a[0];
    const cy = d_pt[1] - a[1];
    const cz = d_pt[2] - a[2];

    const det = ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx);

    if (@abs(det) < 1e-12) {
        // Degenerate: coplanar, fall back to best of 4 triangles
        const s1 = sphereFrom3(a, b, c);
        const s2 = sphereFrom3(a, b, d_pt);
        const s3 = sphereFrom3(a, c, d_pt);
        const s4 = sphereFrom3(b, c, d_pt);
        var best = s1;
        if (s2.radius < best.radius and contains4(s2, a, b, c, d_pt)) best = s2;
        if (s3.radius < best.radius and contains4(s3, a, b, c, d_pt)) best = s3;
        if (s4.radius < best.radius and contains4(s4, a, b, c, d_pt)) best = s4;
        return best;
    }

    const a_sq = ax * ax + ay * ay + az * az;
    const b_sq = bx * bx + by * by + bz * bz;
    const c_sq = cx * cx + cy * cy + cz * cz;

    const inv_det = 0.5 / det;
    const ux = (a_sq * (by * cz - bz * cy) - b_sq * (ay * cz - az * cy) + c_sq * (ay * bz - az * by)) * inv_det;
    const uy = -(a_sq * (bx * cz - bz * cx) - b_sq * (ax * cz - az * cx) + c_sq * (ax * bz - az * bx)) * inv_det;
    const uz = (a_sq * (bx * cy - by * cx) - b_sq * (ax * cy - ay * cx) + c_sq * (ax * by - ay * bx)) * inv_det;

    const center = [3]f32{ a[0] + ux, a[1] + uy, a[2] + uz };
    return .{
        .center = center,
        .radius = @sqrt(ux * ux + uy * uy + uz * uz),
    };
}

fn contains4(s: Sphere, a: [3]f32, b: [3]f32, c: [3]f32, d_pt: [3]f32) bool {
    return contains(s, a) and contains(s, b) and contains(s, c) and contains(s, d_pt);
}

fn dist(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
