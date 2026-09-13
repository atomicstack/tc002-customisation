//! a bounded riff/wave reader: enough of the format to play a short sound on this device, and
//! nothing more. pure -- it borrows the bytes it is given and never copies or allocates.
//!
//! the device's audio-out takes signed 16-bit pcm, so that is the one sample format carried
//! through; 8-bit unsigned is accepted and converted on the way out, because it halves the size of
//! an asset and a pixel clock's notification chirp does not need more. anything else (ima adpcm,
//! a-law, 24- and 32-bit, float) is refused by name rather than played as noise.
const std = @import("std");

pub const Error = error{
    NotRiff,
    NotWave,
    Truncated,
    NoFormatChunk,
    NoDataChunk,
    UnsupportedCodec,
    UnsupportedBitDepth,
    UnsupportedChannels,
    UnsupportedRate,
};

/// what the hardware path will take. the sigmastar audio-out is configured once per sound, so
/// these bounds are about what is sane to store on an 8 mb flash, not what the chip can do.
pub const min_rate = 8_000;
pub const max_rate = 48_000;
pub const max_channels = 2;

pub const Format = enum { pcm_u8, pcm_s16 };

pub const Wav = struct {
    format: Format,
    rate: u32,
    channels: u8,
    /// the raw sample bytes, borrowed from the input
    data: []const u8,

    /// how many sample frames (one frame is one sample per channel)
    pub fn frames(self: Wav) u32 {
        const bytes_per_frame: u32 = @as(u32, self.channels) * self.bytesPerSample();
        if (bytes_per_frame == 0) return 0;
        return @intCast(self.data.len / bytes_per_frame);
    }

    pub fn bytesPerSample(self: Wav) u32 {
        return switch (self.format) {
            .pcm_u8 => 1,
            .pcm_s16 => 2,
        };
    }

    /// how long it plays, in milliseconds
    pub fn durationMs(self: Wav) u32 {
        if (self.rate == 0) return 0;
        return @intCast(@as(u64, self.frames()) * 1000 / self.rate);
    }

    /// the number of signed 16-bit samples this sound yields once converted
    pub fn sampleCount(self: Wav) u32 {
        return self.frames() * self.channels;
    }

    /// read sample `i` as signed 16-bit, whatever it was stored as. 8-bit wave data is unsigned
    /// with 128 as silence, which is why it is centred rather than merely shifted.
    pub fn sample(self: Wav, i: u32) i16 {
        switch (self.format) {
            .pcm_u8 => {
                if (i >= self.data.len) return 0;
                const v: i16 = @as(i16, self.data[i]) - 128;
                return v * 256;
            },
            .pcm_s16 => {
                const o = i * 2;
                if (o + 1 >= self.data.len) return 0;
                return std.mem.readInt(i16, self.data[o..][0..2], .little);
            },
        }
    }
};

fn u16le(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}
fn u32le(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

/// parse a whole `.wav` held in memory. chunks are walked rather than assumed to be in order,
/// because plenty of encoders put `LIST`/`fact` between `fmt ` and `data`.
pub fn parse(bytes: []const u8) Error!Wav {
    if (bytes.len < 12) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return Error.NotRiff;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return Error.NotWave;

    var have_fmt = false;
    var codec: u16 = 0;
    var channels: u16 = 0;
    var rate: u32 = 0;
    var bits: u16 = 0;
    var data: ?[]const u8 = null;

    var o: usize = 12;
    while (o + 8 <= bytes.len) {
        const id = bytes[o..][0..4];
        const size = u32le(bytes[o + 4 ..]);
        const body = o + 8;
        // a chunk that claims more than is here is a truncated file, not a chunk to skip
        if (body + size > bytes.len) {
            // `data` is the one worth salvaging: a recorder killed mid-write leaves exactly this,
            // and the samples that did land are still playable
            if (std.mem.eql(u8, id, "data")) {
                data = bytes[body..];
                break;
            }
            return Error.Truncated;
        }
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return Error.Truncated;
            codec = u16le(bytes[body..]);
            channels = u16le(bytes[body + 2 ..]);
            rate = u32le(bytes[body + 4 ..]);
            bits = u16le(bytes[body + 14 ..]);
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            data = bytes[body .. body + size];
        }
        // chunks are word-aligned: an odd size is followed by a pad byte
        o = body + size + (size & 1);
    }

    if (!have_fmt) return Error.NoFormatChunk;
    const d = data orelse return Error.NoDataChunk;

    // 1 is pcm; 0xfffe is extensible, whose real codec lives in the extension. we do not read the
    // extension, so it is refused rather than guessed at.
    if (codec != 1) return Error.UnsupportedCodec;
    if (channels == 0 or channels > max_channels) return Error.UnsupportedChannels;
    if (rate < min_rate or rate > max_rate) return Error.UnsupportedRate;
    const format: Format = switch (bits) {
        8 => .pcm_u8,
        16 => .pcm_s16,
        else => return Error.UnsupportedBitDepth,
    };
    return .{ .format = format, .rate = rate, .channels = @intCast(channels), .data = d };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// build a minimal wave in a buffer, so the tests describe the bytes rather than ship a fixture
fn build(buf: []u8, codec: u16, channels: u16, rate: u32, bits: u16, samples: []const u8) []u8 {
    const data_len: u32 = @intCast(samples.len);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_len, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], codec, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], rate, .little);
    const block: u16 = channels * (bits / 8);
    std.mem.writeInt(u32, buf[28..32], rate * block, .little);
    std.mem.writeInt(u16, buf[32..34], block, .little);
    std.mem.writeInt(u16, buf[34..36], bits, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_len, .little);
    @memcpy(buf[44 .. 44 + samples.len], samples);
    return buf[0 .. 44 + samples.len];
}

test "a 16-bit mono wave reports its rate, frames and samples" {
    var buf: [128]u8 = undefined;
    const bytes = build(&buf, 1, 1, 8000, 16, &[_]u8{ 0x00, 0x00, 0xff, 0x7f, 0x00, 0x80, 0x01, 0x00 });
    const w = try parse(bytes);
    try testing.expectEqual(Format.pcm_s16, w.format);
    try testing.expectEqual(@as(u32, 8000), w.rate);
    try testing.expectEqual(@as(u8, 1), w.channels);
    try testing.expectEqual(@as(u32, 4), w.frames());
    try testing.expectEqual(@as(i16, 0), w.sample(0));
    try testing.expectEqual(@as(i16, 32767), w.sample(1));
    try testing.expectEqual(@as(i16, -32768), w.sample(2));
}

test "8-bit wave data is unsigned, so silence is 128 and not 0" {
    var buf: [128]u8 = undefined;
    const bytes = build(&buf, 1, 1, 16000, 8, &[_]u8{ 128, 255, 0, 192 });
    const w = try parse(bytes);
    try testing.expectEqual(Format.pcm_u8, w.format);
    try testing.expectEqual(@as(u32, 4), w.frames());
    try testing.expectEqual(@as(i16, 0), w.sample(0)); // 128 is the middle, not the bottom
    try testing.expectEqual(@as(i16, 32512), w.sample(1));
    try testing.expectEqual(@as(i16, -32768), w.sample(2));
}

test "duration is frames over rate, and stereo halves the frames for the same bytes" {
    var buf: [1024]u8 = undefined;
    const samples: [320]u8 = [_]u8{0} ** 320; // 160 s16 samples
    const mono = try parse(build(&buf, 1, 1, 8000, 16, &samples));
    try testing.expectEqual(@as(u32, 160), mono.frames());
    try testing.expectEqual(@as(u32, 20), mono.durationMs());

    var buf2: [1024]u8 = undefined;
    const stereo = try parse(build(&buf2, 1, 2, 8000, 16, &samples));
    try testing.expectEqual(@as(u32, 80), stereo.frames());
    try testing.expectEqual(@as(u32, 10), stereo.durationMs());
    try testing.expectEqual(@as(u32, 160), stereo.sampleCount()); // both channels
}

test "chunks between fmt and data are walked, not assumed away" {
    // a LIST chunk of odd length, which also exercises the pad byte
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 0, .little);
    @memcpy(buf[8..12], "WAVE");
    var n: usize = 12;
    @memcpy(buf[n..][0..4], "fmt ");
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], 16, .little);
    std.mem.writeInt(u16, buf[n + 8 ..][0..2], 1, .little);
    std.mem.writeInt(u16, buf[n + 10 ..][0..2], 1, .little);
    std.mem.writeInt(u32, buf[n + 12 ..][0..4], 16000, .little);
    std.mem.writeInt(u32, buf[n + 16 ..][0..4], 32000, .little);
    std.mem.writeInt(u16, buf[n + 20 ..][0..2], 2, .little);
    std.mem.writeInt(u16, buf[n + 22 ..][0..2], 16, .little);
    n += 24;
    @memcpy(buf[n..][0..4], "LIST");
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], 3, .little);
    buf[n + 8] = 'I';
    buf[n + 9] = 'N';
    buf[n + 10] = 'F';
    buf[n + 11] = 0; // pad
    n += 12;
    @memcpy(buf[n..][0..4], "data");
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], 2, .little);
    buf[n + 8] = 0x34;
    buf[n + 9] = 0x12;
    n += 10;
    const w = try parse(buf[0..n]);
    try testing.expectEqual(@as(u32, 16000), w.rate);
    try testing.expectEqual(@as(u32, 1), w.frames());
    try testing.expectEqual(@as(i16, 0x1234), w.sample(0));
}

test "a data chunk cut short still plays what landed" {
    // a recorder killed mid-write leaves a header promising more than is there. the samples that
    // did land are perfectly good; refusing them would be pedantry.
    var buf: [128]u8 = undefined;
    const bytes = build(&buf, 1, 1, 16000, 16, &[_]u8{ 0x01, 0x00, 0x02, 0x00 });
    std.mem.writeInt(u32, bytes[40..44], 9999, .little); // data claims far more than follows
    const w = try parse(bytes);
    try testing.expectEqual(@as(u32, 2), w.frames());
}

test "everything this device cannot play is refused by name" {
    var buf: [128]u8 = undefined;
    const s = [_]u8{ 0, 0, 0, 0 };
    try testing.expectError(Error.UnsupportedCodec, parse(build(&buf, 2, 1, 16000, 16, &s))); // adpcm
    try testing.expectError(Error.UnsupportedCodec, parse(build(&buf, 0xfffe, 1, 16000, 16, &s))); // extensible
    try testing.expectError(Error.UnsupportedBitDepth, parse(build(&buf, 1, 1, 16000, 24, &s)));
    try testing.expectError(Error.UnsupportedChannels, parse(build(&buf, 1, 3, 16000, 16, &s)));
    try testing.expectError(Error.UnsupportedChannels, parse(build(&buf, 1, 0, 16000, 16, &s)));
    try testing.expectError(Error.UnsupportedRate, parse(build(&buf, 1, 1, 4000, 16, &s)));
    try testing.expectError(Error.UnsupportedRate, parse(build(&buf, 1, 1, 96000, 16, &s)));
}

test "a file that is not a wave at all is refused before anything is read from it" {
    try testing.expectError(Error.Truncated, parse("RIFF"));
    try testing.expectError(Error.NotRiff, parse("MThd" ++ [_]u8{0} ** 16));
    try testing.expectError(Error.NotWave, parse("RIFF" ++ [_]u8{0} ** 4 ++ "AVI " ++ [_]u8{0} ** 8));
    // a wave with a format but no samples is legal and simply has nothing to play
    var buf: [64]u8 = undefined;
    const hdr = build(&buf, 1, 1, 16000, 16, &[_]u8{});
    try testing.expectEqual(@as(u32, 0), (try parse(hdr)).frames());
}
