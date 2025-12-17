// It's easier to debug a panic than a hang
pub const loop_bound: u16 = 65_535;
pub const loop_bound_panic_msg = "HANG: loop safety bound exceeded";
