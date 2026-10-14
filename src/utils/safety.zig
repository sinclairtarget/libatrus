// It's easier to debug a panic than a hang
pub const loop_bound: u32 = 100_000; // Low - make higher for production builds?
pub const loop_bound_panic_msg = "HANG: loop safety bound exceeded";
