const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

// HACK: keep this for ZLS completion, otherwise use the other definition
// const git2 = @cImport({ @cInclude("git2.h"); });
const git2 = @import("git2");

pub fn checkErr(git2_code: c_int) !void {
    if (git2_code < 0) {
        const err: ?*const git2.git_error = git2.git_error_last();
        if (err) |e| {
            std.log.debug("git2 returned an error ({}): {s} (class {})", .{ git2_code, e.message, e.klass });
        }
        return error.Git2Failed;
    }
}
pub fn promptBool(comptime message: []const u8, default: ?bool) bool {
    while (true) {
        std.io.getStdOut().writer().print(message, .{}) catch {};
        const stdin = std.io.getStdIn().reader();

        var in: [16]u8 = [_]u8{ 0 } ** 16;
        var stream = std.io.fixedBufferStream(&in);
        stdin.streamUntilDelimiter(stream.writer(), '\n', in.len) catch |e| switch (e) {
            error.StreamTooLong => {
                std.log.warn("Invalid input", .{});
                stdin.skipUntilDelimiterOrEof('\n') catch continue;
                continue;
            },
            else => continue,
        };
        if (in[1] != 0) {
            std.log.warn("Invalid input", .{});
            continue;
        }
        if (in[0] == 'y' or in[0] == 'Y') {
            return true;
        } else if (in[0] == 'n' or in[0] == 'N') {
            return false;
        } else if (in[0] == 0) {
            if (default) |d| {
                return d;
            }
        }
        std.log.warn("Invalid input", .{});
    }
}

fn printSshKey(writer: anytype, key_type: c_uint, raw: []const u8) !void {
    // Untested, will not be called anyways unless ssh is used instead of https
    switch (key_type) {
        git2.GIT_CERT_SSH_RAW_TYPE_RSA => {
            try writer.print("rsa: {s}\n", .{ raw });
        },
        git2.GIT_CERT_SSH_RAW_TYPE_DSS => {
            try writer.print("dds: {s}\n", .{ raw });
        },
        git2.GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_256 => {
            try writer.print("ECDSA 256: {s}\n", .{ raw });
        },
        git2.GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_384 => {
            try writer.print("ECDSA 384: {s}\n", .{ raw });
        },
        git2.GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_521 => {
            try writer.print("ECDSA 521: {s}\n", .{ raw });
        },
        git2.GIT_CERT_SSH_RAW_TYPE_KEY_ED25519 => {
            try writer.print("ED25519: {s}\n", .{ raw });
        },
        else => return error.InvalidKeyType,
    }
}
fn printCert(writer: anytype, cert: std.crypto.Certificate.Parsed) !void {
    const format = (
        \\Version: {s}
        \\Signature Algorithm: {s}
        \\Issuer: {s}
        \\Valid between {} and {}
        \\Subject: {s}
        \\Public Key: {s}
//         \\Public Key Algorithm: {s}
        \\
    );
    const public_key = cert.pubKey();

    try writer.print(format, .{
        @tagName(cert.version),
        @tagName(cert.signature_algorithm),
        cert.issuer(),
        cert.validity.not_before, cert.validity.not_after,
        cert.subject(),
        public_key,
//         cert.pubKeySigAlgo(),
    });
}
fn isIso8601Date(date: []const u8) bool {
    return date.len == "YYYY-MM-DD".len
        and std.ascii.isDigit(date[0])
        and std.ascii.isDigit(date[1])
        and std.ascii.isDigit(date[2])
        and std.ascii.isDigit(date[3])
        and date[4] == '-'
        and std.ascii.isDigit(date[5])
        and std.ascii.isDigit(date[6])
        and date[7] == '-'
        and std.ascii.isDigit(date[8])
        and std.ascii.isDigit(date[9]);
}



pub fn cloneRepo(alloc: Allocator, dir: [:0]const u8) !void {
    // TODO: consider replacing git2's allocator with this allocator
    _ = alloc;
    std.log.info("cloning zls into {s}", .{ dir });

    var clone_opts: git2.git_clone_options = undefined;
    try checkErr(git2.git_clone_options_init(&clone_opts, git2.GIT_CLONE_OPTIONS_VERSION));

    var checkout_opts: git2.git_checkout_options = undefined;
    try checkErr(git2.git_checkout_options_init(&checkout_opts, git2.GIT_CHECKOUT_OPTIONS_VERSION));

    var progress_tracking: ProgressTracking = .{};

    checkout_opts.checkout_strategy = git2.GIT_CHECKOUT_SAFE;
	checkout_opts.progress_cb = &checkoutCommitProgress;
    checkout_opts.progress_payload = &progress_tracking;

    clone_opts.checkout_opts = checkout_opts;
	clone_opts.fetch_opts.callbacks.transfer_progress = &fetchZlsProgress;
	clone_opts.fetch_opts.callbacks.sideband_progress = &sidebandProgress;
    clone_opts.fetch_opts.callbacks.certificate_check = &cert_check;
    clone_opts.fetch_opts.callbacks.payload = &progress_tracking;


    var repo: *git2.git_repository = undefined;
    checkErr(git2.git_clone(@ptrCast(&repo), "https://github.com/zigtools/zls.git", dir.ptr, &clone_opts))
        catch return error.FailedClone;
    defer git2.git_repository_free(repo);

    std.io.getStdOut().writeAll("\n") catch {};
}
pub fn fetchCommits(alloc: Allocator, dir: [:0]const u8) !void {
    // TODO: consider replacing git2's allocator with this allocator
    _ = alloc;
    std.log.info("fetching latest commits into zls installation {s}", .{ dir });

    var repo: *git2.git_repository = undefined;
    checkErr(git2.git_repository_open(@ptrCast(&repo), dir.ptr))
        catch return error.FailedOpen;
    defer git2.git_repository_free(repo);

    var remote: *git2.git_remote = undefined;
    checkErr(git2.git_remote_lookup(@ptrCast(&remote), repo, "origin"))
        catch return error.MissingRemote;
    defer git2.git_remote_free(remote);


    var options: git2.git_fetch_options = undefined;
    try checkErr(git2.git_fetch_options_init(&options, git2.GIT_FETCH_OPTIONS_VERSION));

    options.callbacks.certificate_check = &cert_check;
    checkErr(git2.git_remote_fetch(remote, null, &options, null))
        catch return error.FailedFetch;
}

pub fn checkout(alloc: Allocator, dir: [:0]const u8, oid: git2.git_oid) !void {
    // TODO: consider replacing git2's allocator with this allocator
    _ = alloc;
    std.log.info("checking out zls commit {}", .{ std.fmt.fmtSliceHexLower(&oid.id) });

    var repo: *git2.git_repository = undefined;
    checkErr(git2.git_repository_open(@ptrCast(&repo), dir.ptr))
        catch return error.FailedOpen;
    defer git2.git_repository_free(repo);


    var checkout_opts: git2.git_checkout_options = undefined;
    try checkErr(git2.git_checkout_options_init(&checkout_opts, git2.GIT_CHECKOUT_OPTIONS_VERSION));

    var progress_tracking: ProgressTracking = .{};

    checkout_opts.checkout_strategy = git2.GIT_CHECKOUT_SAFE;
	checkout_opts.progress_cb = &checkoutCommitProgress;
    checkout_opts.progress_payload = &progress_tracking;

    var commit: *git2.git_commit = undefined;
    checkErr(git2.git_commit_lookup(@ptrCast(&commit), repo, &oid))
        catch return error.FailedCommitLookup;
    defer git2.git_commit_free(commit);

    // although `commit` isn't a tree, it will be peeled into a tree according to libgit2 documentation
    checkErr(git2.git_checkout_tree(repo, @ptrCast(commit), &checkout_opts))
        catch return error.FailedCheckoutTree;

    checkErr(git2.git_repository_set_head_detached(repo, &oid))
        catch return error.FailedDetachHead;
}



pub fn findReference(alloc: Allocator, dir: [:0]const u8, short_name: [:0]const u8) !git2.git_oid {
    // TODO: consider replacing git2's allocator with this allocator
    _ = alloc;
    std.log.info("searching for reference {s} in {s}", .{ short_name, dir });

    var repo: *git2.git_repository = undefined;
    checkErr(git2.git_repository_open(@ptrCast(&repo), dir.ptr))
        catch return error.FailedOpen;
    defer git2.git_repository_free(repo);


    var ref: *git2.git_reference = undefined;
    if (checkErr(git2.git_reference_dwim(@ptrCast(&ref), repo, short_name))) {
        defer git2.git_reference_free(ref);

        const ref_name = git2.git_reference_name(ref);

        var oid: git2.git_oid = undefined;
        checkErr(git2.git_reference_name_to_id(&oid, repo, ref_name))
            catch return error.ReferenceNotFound;

        return oid;
    } else |_| {
        return error.ReferenceNotFound;
    }
}
pub fn findCommit(alloc: Allocator, dir: [:0]const u8, sha: [:0]const u8) !git2.git_oid {
    // TODO: consider replacing git2's allocator with this allocator
    _ = alloc;
    std.log.info("searching for commit {s} in {s}", .{ sha, dir });

    var repo: *git2.git_repository = undefined;
    checkErr(git2.git_repository_open(@ptrCast(&repo), dir.ptr))
        catch return error.FailedOpen;
    defer git2.git_repository_free(repo);


    var obj: *git2.git_object = undefined;
    if (checkErr(git2.git_revparse_single(@ptrCast(&obj), repo, sha))) {
        defer git2.git_object_free(obj);

        const oid = git2.git_object_id(obj).*;
        return oid;
    } else |_| {
        return error.ReferenceNotFound;
    }
}


/// return `git2.GIT_PASSTHROUGH` to use the existing validity determination
/// return -1 to fail, 0 to proceed
export fn cert_check(cert_generic_raw: ?*git2.git_cert, valid: c_int, host_raw: ?[*:0]const u8, payload: ?*anyopaque) c_int {
    _ = payload;

    const host = std.mem.span(host_raw.?);
    const cert_generic = cert_generic_raw.?;

    if (valid != 0) {
        std.log.info("Certificate for {s} was valid, continuing...", .{ host });
        return git2.GIT_PASSTHROUGH;
    } else {
        const stderr = std.io.getStdErr().writer();
        stderr.print("\nCertificate for {s} was invalid\n\n", .{ host }) catch {};
        stderr.print("Details: ", .{}) catch {};

        // https://libgit2.org/libgit2/#HEAD/type/git_cert_t
        switch (cert_generic.cert_type) {
            git2.GIT_CERT_NONE => {
                stderr.print("none\n", .{}) catch {};
            },
            git2.GIT_CERT_X509 => {
                const cert: *git2.git_cert_x509 = @alignCast(@ptrCast(cert_generic));
                const cert_data_raw: [*]const u8 = @ptrCast(cert.data.?);
                const cert_data = cert_data_raw[0..cert.len];

                const try_parsed_cert = std.crypto.Certificate.parse(.{
                    .buffer = cert_data,
                    .index = 0,
                });
                if (try_parsed_cert) |parsed_cert| {
                    stderr.print("x509\n", .{ }) catch {};
                    printCert(stderr, parsed_cert) catch {};
                } else |e| {
                    stderr.print("x509: unable to parse ({s})\n", .{ @errorName(e) }) catch {};
                }
            },
            git2.GIT_CERT_HOSTKEY_LIBSSH2 => {
                const cert: *git2.git_cert_hostkey = @alignCast(@ptrCast(cert_generic));
                stderr.print("hostkey cert\n", .{}) catch {};

                if ((cert.type & git2.GIT_CERT_SSH_MD5) != 0) {
                    stderr.print("md5: {s}\n", .{ cert.hash_md5 }) catch {};
                }
                if ((cert.type & git2.GIT_CERT_SSH_SHA1) != 0) {
                    stderr.print("sha1: {s}\n", .{ cert.hash_sha1 }) catch {};
                }
                if ((cert.type & git2.GIT_CERT_SSH_SHA256) != 0) {
                    stderr.print("sha256: {s}\n", .{ cert.hash_sha256 }) catch {};
                }
                if ((cert.type & git2.GIT_CERT_SSH_RAW) != 0) {
                    printSshKey(stderr, cert.raw_type, cert.hostkey[0..cert.hostkey_len])
                        catch |e| if (e == error.InvalidKeyType) unreachable;
                }
            },
            git2.GIT_CERT_STRARRAY => {
                const cert: *git2.git_strarray = @alignCast(@ptrCast(cert_generic));
                stderr.print("string array\n", .{}) catch {};

                for (cert.strings[0..cert.count]) |string| {
                    stderr.print("string: {s}\n", .{ string }) catch {};
                }
            },
            else => unreachable,

        }

        const continue_conn = promptBool("Continue connection? (y/n): ", null);
        if (continue_conn) {
            return 0;
        } else {
            return -1;
        }
    }
}

// Ported from libgit2 examples which were originally licensed under CC0
const ProgressTracking = struct {
    stats: git2.git_indexer_progress = .{},
    completed_steps: usize = 0,
    total_steps: usize = 0,
    path: ?[*:0]const u8 = null,
};
export fn sidebandProgress(str_raw: ?[*]const u8, len: c_int, payload: ?*anyopaque) c_int {
    _ = payload;

    const str = str_raw.?[0..@intCast(len)];
    std.io.getStdOut().writer().print("remote: {s}", .{ str }) catch {};
    return 0;
}
export fn fetchZlsProgress(stats: ?*const git2.git_indexer_progress, payload: ?*anyopaque) c_int {
    var tracking: *ProgressTracking = @ptrCast(@alignCast(payload.?));
    tracking.stats = stats.?.*;
    printFetchAndCheckoutProgress(tracking);
    return 0;
}
export fn checkoutCommitProgress(path: ?[*:0]const u8, current: usize, total: usize, payload: ?*anyopaque) void {
    var tracking: *ProgressTracking = @ptrCast(@alignCast(payload.?));
    tracking.completed_steps = current;
    tracking.total_steps = total;
    tracking.path = path;
    printFetchAndCheckoutProgress(tracking);
}
fn printFetchAndCheckoutProgress(tracking: *const ProgressTracking) void {
//     const net_percent = (
//         if (tracking.stats.total_objects > 0)
//             100 * tracking.stats.received_objects / tracking.stats.total_objects
//         else
//             0
//     );
//     const index_percent = (
//         if (tracking.stats.total_objects > 0)
//             100 * tracking.stats.indexed_objects / tracking.stats.total_objects
//         else
//             0
//     );
//     const checkout_percent = (
//         if (tracking.total_steps > 0)
//             100 * tracking.completed_steps / tracking.total_steps
//         else
//             0
//     );
//     const kilobytes = tracking.stats.received_bytes / 1000;

    const writer = std.io.getStdOut().writer();
    if (
        tracking.stats.total_objects > 0
        and tracking.stats.received_objects == tracking.stats.total_objects
    ) {
        writer.print("Resolving deltas {}/{}\r", .{
            tracking.stats.indexed_deltas,
            tracking.stats.total_deltas,
        }) catch {};
    } else {
//         writer.print("net {: >3}% ({: >4} kb, {: >5}/{: >5})  /  idx {: >3}% ({: >5}/{: >5})  /  chk {: >3}% ({: >4}/{: >4}){s}\n", .{
//             net_percent, kilobytes,
//             tracking.stats.received_objects, tracking.stats.total_objects,
//             index_percent, tracking.stats.indexed_objects, tracking.stats.total_objects,
//             checkout_percent,
//             tracking.completed_steps, tracking.total_steps,
//             std.mem.span(tracking.path),
//         }) catch {};
    }
}
