import Foundation

/// Renders a meeting to Markdown and writes it to disk.
/// Stateless and nonisolated: safe to call from any task.
enum MarkdownExporter {
    nonisolated static let defaultFolder = "~/Documents/MeetingNotes"

    // MARK: - Rendering

    nonisolated static func render(meeting: Meeting, summary: MeetingSummary) -> String {
        var lines: [String] = []

        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append(metaLine(start: meeting.startDate, end: meeting.endDate))
        lines.append("")

        lines.append("## Summary")
        lines.append("")
        lines.append(summary.summary.isEmpty ? "_No summary._" : summary.summary)
        lines.append("")

        lines.append("## Key decisions")
        lines.append("")
        lines.append(contentsOf: bullets(summary.keyDecisions.map { decision in
            if let context = decision.context, !context.isEmpty {
                return "\(decision.decision) — \(context)"
            }
            return decision.decision
        }))
        lines.append("")

        lines.append("## Action points")
        lines.append("")
        if summary.actionPoints.isEmpty {
            lines.append("_None._")
        } else {
            for point in summary.actionPoints {
                let owner = point.isAssigned && !point.owner.isEmpty ? point.owner : "Unassigned"
                lines.append("- [ ] \(point.task) — \(owner) · \(dueText(for: point))")
            }
        }
        lines.append("")

        lines.append("## Open questions")
        lines.append("")
        lines.append(contentsOf: bullets(summary.openQuestions.map { question in
            if let context = question.context, !context.isEmpty {
                return "\(question.question) — \(context)"
            }
            return question.question
        }))
        lines.append("")

        lines.append("## Key topics")
        lines.append("")
        lines.append(contentsOf: bullets(summary.keyTopics))
        lines.append("")

        lines.append("## Transcript")
        lines.append("")
        let transcript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append(transcript.isEmpty ? "_No transcript._" : transcript)
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Writing

    /// `yyyy-MM-dd HH-mm - <title>.md`, with path-hostile characters removed.
    nonisolated static func fileName(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = formatter.string(from: meeting.startDate)

        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var title = meeting.title.components(separatedBy: illegal).joined(separator: "-")
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if title.isEmpty { title = "Meeting" }
        if title.count > 80 { title = String(title.prefix(80)) }
        return "\(stamp) - \(title).md"
    }

    /// Expands `~` and falls back to the default folder when the setting is empty.
    nonisolated static func folderURL(from setting: String) -> URL {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? defaultFolder : trimmed
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Creates the folder if needed and writes atomically. Never overwrites an
    /// existing note: a second meeting in the same minute gets " (2)", " (3)"…
    nonisolated static func write(_ markdown: String, to folder: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var url = folder.appendingPathComponent(fileName, isDirectory: false)
        if fm.fileExists(atPath: url.path) {
            let base = url.deletingPathExtension().lastPathComponent
            var n = 2
            repeat {
                url = folder.appendingPathComponent("\(base) (\(n)).md", isDirectory: false)
                n += 1
            } while fm.fileExists(atPath: url.path)
        }

        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private nonisolated static func bullets(_ items: [String]) -> [String] {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? ["_None._"] : cleaned.map { "- \($0)" }
    }

    private nonisolated static func dueText(for point: ActionPoint) -> String {
        if let text = point.dueDateString?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "Due \(text)"
        }
        if let date = point.dueDate {
            return "Due \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "No date"
    }

    private nonisolated static func metaLine(start: Date, end: Date?) -> String {
        let date = start.formatted(date: .complete, time: .shortened)
        guard let end else { return "**Date:** \(date)" }
        return "**Date:** \(date) · **Duration:** \(durationText(end.timeIntervalSince(start)))"
    }

    private nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "< 1 min" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) h \(String(format: "%02d", minutes)) min" : "\(minutes) min"
    }
}
