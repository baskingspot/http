//! Shared HTTP client types and adapters.

pub const common = @import("common.zig");
pub const frame_queue = @import("frame_queue.zig");
pub const Client = @import("dispatch.zig").Client;
pub const Url = @import("../uri.zig").Url;
pub const transport = @import("transport.zig");
pub const plain = @import("plain.zig");
pub const Protocol = common.Protocol;
pub const Scheme = common.Scheme;
pub const Request = common.Request;
pub const ResponseHead = common.ResponseHead;
pub const Body = common.Body;
pub const BodyWriter = common.BodyWriter;
pub const BodyWriteError = common.BodyWriteError;
pub const Response = common.Response;
pub const GoAway = common.GoAway;
pub const Outcome = common.Outcome;
pub const ReadCause = common.ReadCause;
pub const BodyResult = common.BodyResult;
pub const BodyError = common.BodyError;
pub const Local = common.Local;
pub const BodyStep = common.BodyStep;
pub const BodyStepError = common.BodyStepError;
pub const Config = common.Config;

test {
    _ = common;
    _ = Client;
    _ = Url;
    _ = transport;
    _ = plain;
    _ = @import("../uri.zig");
    _ = frame_queue;
}
