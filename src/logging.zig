pub const ColorCode = enum(u8) {
    Grey = 90,
    Red = 31,
    Green = 32,
    Blue = 34,
    Cyan = 36,
    Reset = 0,

    pub fn toString(self: ColorCode) []const u8 {
        return switch (self) {
            .Grey => "90",
            .Red => "31",
            .Green => "32",
            .Blue => "34",
            .Cyan => "36",
            .Reset => "0",
        };
    }
};

fn color(comptime color_code: []const u8, comptime fmt: []const u8) []const u8 {
    return "\x1b[" ++ color_code ++ "m" ++ fmt ++ "\x1b[" ++ comptime ColorCode.Reset.toString() ++ "m";
}

pub fn grey(comptime fmt: []const u8) []const u8 {
    return color(ColorCode.Grey.toString(), fmt);
}

pub fn red(comptime fmt: []const u8) []const u8 {
    return color(ColorCode.Red.toString(), fmt);
}

pub fn green(comptime fmt: []const u8) []const u8 {
    return color(ColorCode.Green.toString(), fmt);
}

pub fn blue(comptime fmt: []const u8) []const u8 {
    return color(ColorCode.Blue.toString(), fmt);
}
