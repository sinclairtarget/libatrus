// It's easier to debug a panic than a hang
pub const loop_bound: u32 = 16_777_215;
pub const loop_bound_panic_msg = "HANG: loop safety bound exceeded";
