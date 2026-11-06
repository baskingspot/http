//! Shared HTTP client types and adapters.

pub const common = @import("common.zig");
pub const frame_queue = @import("frame_queue.zig");
pub const blocking = @import("blocking.zig");
pub const Protocol = common.Protocol;
pub const Scheme = common.Scheme;
pub const Request = common.Request;
pub const ResponseHead = common.ResponseHead;
pub const Body = common.Body;
pub const Response = common.Response;
pub const GoAway = common.GoAway;
pub const BodyResult = common.BodyResult;
pub const BodyError = common.BodyError;
pub const Local = common.Local;
pub const BodyStep = common.BodyStep;
pub const BodyStepError = common.BodyStepError;
pub const Config = common.Config;

test {
    _ = common;
    _ = blocking;
    _ = frame_queue;
}
