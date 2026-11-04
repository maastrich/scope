import Foundation

/// What a pull request's checks really say once the runs GitHub cancelled to make way for newer ones are set aside.
///
/// A workflow with `concurrency: cancel-in-progress` cancels its running run when a newer one of the same group
/// starts. On one head commit (a PR edited, labelled, reopened: every event a run) the rollup then lists the
/// cancelled job next to the job that replaced it, and reading the cancelled one as a failure turns a green pull
/// request red. Here:
///
/// - a cancelled check with a newer check of the same workflow and the same job name (a matrix leg's name carries
///   its parameters) is dropped: its successor is already a row of its own, with its own state and link;
/// - a cancelled check with no successor in sight is asked about once (`supersededJobs`): GitHub annotates a
///   concurrency cancellation, so one that says so is a replacement whose jobs have not reached the rollup yet —
///   pending, never failing;
/// - any other cancellation (by hand, a matrix leg stopped by `fail-fast`, a timeout GitHub reports as cancelled)
///   stays, as `.cancelled`: neutral, not red, and not green either.
public enum CheckResolution {
    /// Drops every cancelled check a newer one of the same workflow and job replaced. Order is the job id of the
    /// Actions link, then the run id, then the start date; a check with none of them is never anyone's successor.
    public static func resolve(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        checks.enumerated().compactMap { index, check in
            guard check.state == .cancelled, let mine = order(of: check) else { return check }
            let replaced = checks.enumerated().contains { other, candidate in
                other != index && key(of: candidate) == key(of: check)
                    && order(of: candidate).map { $0 > mine } == true
            }
            return replaced ? nil : check
        }
    }

    /// The cancelled checks left once `resolve` ran turned pending when their job is one GitHub cancelled for a
    /// newer run (`supersededJobs`, job ids). Idempotent: a check already resolved is left as it is.
    public static func following(_ checks: [PullRequestCheck], supersededJobs: Set<Int>) -> [PullRequestCheck] {
        checks.map { check in
            guard check.state == .cancelled, let job = check.actionsJob?.job, supersededJobs.contains(job) else { return check }
            return check.with(state: .pending, awaitingReplacement: true)
        }
    }

    /// The Actions jobs of the checks still cancelled: the ones worth one question to GitHub.
    public static func unexplainedCancellations(_ checks: [PullRequestCheck]) -> [ActionsJob] {
        checks.compactMap { check in
            guard check.state == .cancelled, let job = check.actionsJob, job.job != nil else { return nil }
            return job
        }
    }

    /// The fold of a list of checks: a failure beats a pending check, which beats a cancellation, which beats
    /// success. Skipped checks count for nothing; only skipped ones make a pass.
    public static func summarize(_ states: [PullRequestCheck.State]) -> PullRequest.Checks {
        guard !states.isEmpty else { return .none }
        if states.contains(.failing) { return .failing }
        if states.contains(.pending) { return .pending }
        if states.contains(.cancelled) { return .cancelled }
        return .passing
    }

    /// `true` when the annotations of a cancelled job (`gh api repos/<repo>/check-runs/<job>/annotations`) carry
    /// the message GitHub writes when `concurrency` cancels a run for a newer one:
    /// "Canceling since a higher priority waiting request for <group> exists".
    public static func isConcurrencyCancellation(annotationsJSON data: Data) throws -> Bool {
        struct Annotation: Decodable { var message: String? }
        return try JSONDecoder().decode([Annotation].self, from: data)
            .contains { ($0.message ?? "").lowercased().contains("higher priority waiting request") }
    }

    private struct Key: Equatable {
        var workflow: String
        var name: String
    }

    private static func key(of check: PullRequestCheck) -> Key {
        Key(workflow: check.workflow ?? "", name: check.name)
    }

    /// Job ids and run ids only grow; a third-party check run has neither, its start date stands in.
    private static func order(of check: PullRequestCheck) -> Order? {
        if let job = check.actionsJob {
            return Order(primary: Double(job.job ?? 0), secondary: Double(job.run))
        }
        return check.startedAt.map { Order(primary: $0.timeIntervalSince1970, secondary: 0) }
    }

    private struct Order: Comparable {
        var primary: Double
        var secondary: Double
        static func < (lhs: Order, rhs: Order) -> Bool {
            (lhs.primary, lhs.secondary) < (rhs.primary, rhs.secondary)
        }
    }
}
