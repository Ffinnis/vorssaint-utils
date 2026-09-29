// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Progress saved by one launch and picked up by the next must leave the
/// store exactly as reading every log from its start would.
enum AgentUsageArchiveTests {
    private static let build = "1.0-1"

    private static func codex(_ time: String, _ json: String) -> String {
        #"{"timestamp":"\#(time)","type":\#(json)}"#
    }

    private static let firstHalf = [
        codex("2026-09-22T14:44:23.000Z", #""session_meta","payload":{"id":"s9","cwd":"/Users/me/code/web"}"#),
        codex("2026-09-22T14:44:24.000Z", #""turn_context","payload":{"model":"gpt-6-astra","cwd":"/Users/me/code/web","service_tier":"fast"}"#),
        codex("2026-09-22T14:44:25.000Z", #""event_msg","payload":{"type":"task_started"}"#),
        codex("2026-09-22T14:44:53.000Z", #""token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":15,"reasoning_output_tokens":4}}"#),
        codex("2026-09-22T14:44:54.000Z", #""event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1790100000},"secondary":null,"plan_type":"pro"}}"#)
    ]

    private static let secondHalf = [
        codex("2026-09-22T14:50:00.000Z", #""token_usage_record","payload":{"response_id":"r2","usage":{"input_tokens":400,"cached_input_tokens":300,"output_tokens":20}}"#),
        // A duplicate of an earlier response only raises what it counted.
        codex("2026-09-22T14:50:01.000Z", #""token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":18,"reasoning_output_tokens":4}}"#),
        codex("2026-09-22T14:52:00.000Z", #""event_msg","payload":{"type":"task_complete","duration_ms":20000}"#)
    ]

    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { suite.expect(false, "the archive fixture creates its folder: \(error)"); return }
        let log = folder.appending(path: "rollout.jsonl")
        let now = AgentTimestamp.parse("2026-09-22T15:00:00.000Z")!

        func read(_ cursor: AgentLogCursor, into store: AgentUsageStore) {
            AgentLogReader.readAppended(cursor) { line in
                let entries = AgentLogParser.parseCodex(line, state: &cursor.state, now: now)
                store.apply(entries, file: cursor.path, provider: .codex, tracksTurns: cursor.tracksTurns,
                            parent: cursor.parent, modified: cursor.modified, now: now)
            }
        }
        func write(_ lines: [String], ending: String = "\n") {
            try? Data((lines.joined(separator: "\n") + ending).utf8).write(to: log)
        }

        // One launch reads the first half, with the next line half written.
        let partial = #"{"timestamp":"2026-09-22T14:49:59.000Z","type":"event_msg","payload":{"type":"task_star"#
        write(firstHalf + [partial], ending: "")
        let first = AgentUsageStore()
        let cursor = AgentLogCursor(path: log.path, provider: .codex)
        read(cursor, into: first)
        suite.expect(!cursor.pending.isEmpty && cursor.saved.offset == cursor.offset - UInt64(cursor.pending.count),
                     "progress is saved at the start of a line still being written")
        let contents = AgentUsageArchive.Contents(providers: [.codex], store: first.saved, cursors: [cursor.saved])
        let data = AgentUsageArchive.encode(contents, build: build)
        let decoded = AgentUsageArchive.decode(data, build: build)
        suite.expect(decoded == contents, "saved progress reads back as it was written")
        suite.expect(!first.saved.records.isEmpty && !first.saved.limits.isEmpty && first.saved.codexPlan != nil
                        && !first.saved.turns.isEmpty && cursor.state.fast && !cursor.state.model.isEmpty,
                     "the fixture saves records, limits, a plan, an open turn and parser context")

        // The next launch picks up there while the agent keeps writing.
        write(firstHalf + secondHalf)
        let resumed = AgentUsageStore(saved: decoded?.store ?? .init())
        let restored = decoded?.cursors.first.flatMap(AgentLogCursor.init(saved:))
        var resumedLines = 0
        if let restored {
            AgentLogReader.readAppended(restored) { line in
                resumedLines += 1
                let entries = AgentLogParser.parseCodex(line, state: &restored.state, now: now)
                resumed.apply(entries, file: restored.path, provider: .codex, tracksTurns: restored.tracksTurns,
                              parent: restored.parent, modified: restored.modified, now: now)
            }
        }
        let fresh = AgentUsageStore()
        let freshCursor = AgentLogCursor(path: log.path, provider: .codex)
        read(freshCursor, into: fresh)
        suite.expect(resumedLines == secondHalf.count, "a resumed launch reads only what was written since")
        suite.expect(resumed.saved == fresh.saved && restored?.state == freshCursor.state
                        && restored?.offset == freshCursor.offset,
                     "resuming leaves the same records, limits, turns and context as reading from the start")

        // A log replaced meanwhile is read again whole; nothing counts twice.
        let identity = restored?.identity
        try? Data(((firstHalf + secondHalf).joined(separator: "\n") + "\n").utf8).write(to: log, options: .atomic)
        var replacedLines = 0
        if let restored {
            AgentLogReader.readAppended(restored) { line in
                replacedLines += 1
                let entries = AgentLogParser.parseCodex(line, state: &restored.state, now: now)
                resumed.apply(entries, file: restored.path, provider: .codex, tracksTurns: restored.tracksTurns,
                              parent: restored.parent, modified: restored.modified, now: now)
            }
        }
        suite.expect(restored?.identity != identity && replacedLines == firstHalf.count + secondHalf.count
                        && resumed.saved.records == fresh.saved.records,
                     "a replaced log read again from its start merges into what was already counted")

        suite.expect(AgentUsageArchive.decode(data, build: "1.0-2") == nil,
                     "progress another build saved is not used")
        let damaged = [Data(), data.prefix(4), data.prefix(data.count / 2), data.dropLast(), data + Data([0])]
        suite.expect(damaged.allSatisfy { AgentUsageArchive.decode($0, build: build) == nil },
                     "a short, cut or padded file reads as nothing")
        // One changed bit can turn a count of 1 into -2 and still decode.
        var flipped = data
        var accepted: [Int] = []
        for position in 4..<flipped.count {
            for bit in 0..<8 {
                flipped[position] ^= 1 << bit
                if AgentUsageArchive.decode(flipped, build: build) != nil { accepted.append(position) }
                flipped[position] ^= 1 << bit
            }
        }
        suite.expect(accepted.isEmpty && AgentUsageArchive.decode(flipped, build: build) == contents,
                     "every changed bit is rejected rather than restored as other counts")
        var negative = contents
        if let first = negative.store.records.first {
            var record = first.record
            record.tokens.output = -2
            negative.store.records[0] = .init(key: first.key, record: record, billable: first.billable)
        }
        suite.expect(AgentUsageArchive.decode(AgentUsageArchive.encode(negative, build: build), build: build) == nil,
                     "a negative count is rejected even under a valid checksum, as the parser rejects it")

        // A log cut short and written again in place keeps its inode but
        // not its contents, and here grows past where reading stopped.
        func inode() -> UInt64 {
            var info = stat()
            return stat(log.path, &info) == 0 ? UInt64(info.st_ino) : 0
        }
        write(firstHalf + secondHalf)
        let before = AgentLogCursor(path: log.path, provider: .codex)
        read(before, into: AgentUsageStore())
        let savedBefore = before.saved
        let inodeBefore = inode()
        suite.expect(AgentLogCursor(saved: savedBefore) != nil, "an unchanged log resumes")
        let rewritten = [codex("2026-09-23T09:00:00.000Z", #""session_meta","payload":{"id":"s10","cwd":"/Users/me/code/api"}"#)]
            + firstHalf.dropFirst() + secondHalf + secondHalf
        if let handle = try? FileHandle(forWritingTo: log) {
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: Data((rewritten.joined(separator: "\n") + "\n").utf8))
            try? handle.close()
        }
        let rewrittenStore = AgentUsageStore()
        let rewrittenCursor = AgentLogCursor(saved: savedBefore) ?? AgentLogCursor(path: log.path, provider: .codex)
        read(rewrittenCursor, into: rewrittenStore)
        let expected = AgentUsageStore()
        let expectedCursor = AgentLogCursor(path: log.path, provider: .codex)
        read(expectedCursor, into: expected)
        suite.expect(inode() == inodeBefore && AgentLogCursor(saved: savedBefore) == nil
                        && rewrittenStore.saved == expected.saved && rewrittenCursor.state == expectedCursor.state,
                     "a log rewritten in place on the same inode is read again from its start, with fresh context")

        // A log gone while the app was closed takes its open turn with it.
        let pruned = AgentUsageStore(saved: first.saved)
        pruned.forgetTurns(outside: [])
        let kept = AgentUsageStore(saved: first.saved)
        kept.forgetTurns(outside: [log.path])
        suite.expect(!first.saved.turns.isEmpty && pruned.saved.turns.isEmpty && pruned.saved.waiting.isEmpty
                        && kept.saved.turns == first.saved.turns,
                     "restored turns of logs that are gone end, while those of logs still there stay")
    }
}

/// The production settle method against a recording archive: turning the
/// section off and quitting at once must still remove saved progress.
enum AgentUsageArchiveSettleTests {
    enum AgentUsageArchive {
        static var removed = 0
        static func remove() { removed += 1 }
    }

    class Fixture {
        let queue = DispatchQueue(label: "com.vorssaint.agent-usage.settle-test")
        var saved = 0
        func saveProgress() { saved += 1 }
    }

    static func run(_ suite: TestSuite) {
        defer { AgentUsageArchive.removed = 0 }
        let host = Host()
        // A first read still going when the section is turned off.
        let reading = DispatchSemaphore(value: 0)
        host.queue.async {
            reading.signal()
            Thread.sleep(forTimeInterval: 0.2)
        }
        reading.wait()
        host.settleArchive(keeping: false)
        suite.expect(AgentUsageArchive.removed == 1 && host.saved == 0,
                     "turning the section off removes saved progress before stopping returns, behind a read in progress")
        host.settleArchive(keeping: true)
        suite.expect(AgentUsageArchive.removed == 1 && host.saved == 1,
                     "quitting with the section on saves progress before stopping returns")
    }
}
