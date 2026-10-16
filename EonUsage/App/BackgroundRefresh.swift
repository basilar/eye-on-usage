import BackgroundTasks
import Foundation

/// Runs the feed-in check while the app is closed.
///
/// iOS decides when — and whether — an app refresh task actually runs, so this is a
/// best-effort backstop, not a guarantee. The check also runs whenever the dashboard
/// loads, which is what catches the fault for anyone who opens the app regularly.
enum BackgroundRefresh {
    static let taskID = "hu.randart.EonUsage.feedInCheck"

    /// `BGAppRefreshTask` is a non-Sendable class, but the scheduler explicitly allows
    /// completing a task from any context. This wrapper states that intent rather than
    /// leaving the compiler to guess at it.
    private struct Handle: @unchecked Sendable {
        let task: BGAppRefreshTask
    }

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(Handle(task: refresh))
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        // Readings only move once a day, so asking more often than this burns the budget
        // iOS allots and makes it less likely to run when it matters.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
    }

    private static func run(_ handle: Handle) {
        // Queue the next one first: if this run is killed, the chain survives.
        schedule()

        let work = Task { @MainActor in
            let outcome = await FeedInMonitor.shared.check(force: true)
            if case .failed = outcome {
                handle.task.setTaskCompleted(success: false)
            } else {
                handle.task.setTaskCompleted(success: true)
            }
        }

        handle.task.expirationHandler = { work.cancel() }
    }
}
