import Foundation

/// Answers recorded on 2026-11-24 with gh 2.103.3 against the public `cli/cli` repository, the rollup cut to three
/// of its thirty checks (the same three on both sides).
enum PullRequestBatchFixtures {
    /// The branch of a merged Dependabot pull request.
    static let branch = "dependabot/go_modules/github.com/charmbracelet/x/ansi-0.11.10"

    /// `gh api graphql -f query=<PullRequestBatch.query>` for that branch, a branch without a pull request, and a
    /// repository that does not exist: `gh` exited 1 and printed this.
    static let answer = #"""
{
 "data": {
  "r0": {
   "b0": {
    "nodes": [
     {
      "number": 15145,
      "title": "chore(deps): Bump github.com/charmbracelet/x/ansi from 0.11.9 to 0.11.10",
      "author": {
       "__typename": "Bot",
       "login": "dependabot"
      },
      "headRefName": "dependabot/go_modules/github.com/charmbracelet/x/ansi-0.11.10",
      "headRefOid": "b7d38765850266766f6f4662808dca6f84789afd",
      "baseRefName": "trunk",
      "isDraft": false,
      "reviewDecision": "APPROVED",
      "updatedAt": "2026-11-23T18:24:29Z",
      "url": "https://github.com/cli/cli/pull/15145",
      "isCrossRepository": false,
      "headRepositoryOwner": {
       "login": "cli"
      },
      "mergeable": "UNKNOWN",
      "state": "MERGED",
      "createdAt": "2026-11-23T14:03:33Z",
      "mergedAt": "2026-11-23T18:24:25Z",
      "closedAt": "2026-11-23T18:24:26Z",
      "additions": 3,
      "deletions": 3,
      "statusCheckRollup": {
       "nodes": [
        {
         "commit": {
          "statusCheckRollup": {
           "contexts": {
            "nodes": [
             {
              "__typename": "CheckRun",
              "name": "label-external",
              "status": "COMPLETED",
              "conclusion": "SKIPPED",
              "detailsUrl": "https://github.com/cli/cli/actions/runs/45190148370/job/137746127991",
              "startedAt": "2026-11-23T14:03:51Z",
              "checkSuite": {
               "workflowRun": {
                "workflow": {
                 "name": "PR Triaging"
                }
               }
              }
             },
             {
              "__typename": "CheckRun",
              "name": "CodeQL-Build (go, manual, ./.github/codeql/codeql-config.yml)",
              "status": "COMPLETED",
              "conclusion": "SUCCESS",
              "detailsUrl": "https://github.com/cli/cli/actions/runs/45190145097/job/137746020384",
              "startedAt": "2026-11-23T14:03:43Z",
              "checkSuite": {
               "workflowRun": {
                "workflow": {
                 "name": "Code Scanning"
                }
               }
              }
             },
             {
              "__typename": "CheckRun",
              "name": "lint",
              "status": "COMPLETED",
              "conclusion": "SUCCESS",
              "detailsUrl": "https://github.com/cli/cli/actions/runs/45190145113/job/137746020291",
              "startedAt": "2026-11-23T14:03:43Z",
              "checkSuite": {
               "workflowRun": {
                "workflow": {
                 "name": "Lint"
                }
               }
              }
             }
            ]
           }
          }
         }
        }
       ]
      }
     }
    ]
   },
   "b1": {
    "nodes": []
   }
  },
  "r1": null
 },
 "errors": [
  {
   "type": "NOT_FOUND",
   "path": [
    "r1"
   ],
   "locations": [
    {
     "line": 6,
     "column": 3
    }
   ],
   "message": "Could not resolve to a Repository with the name 'cli/no-such-repo-xyz'."
  }
 ]
}
"""#

    /// What `gh` wrote on stderr with it.
    static let stderr = "gh: Could not resolve to a Repository with the name 'cli/no-such-repo-xyz'."

    /// `gh pr list --repo cli/cli --state all --head <branch> --json <PullRequest.jsonFields>` at the same moment.
    static let list = #"""
[
 {
  "additions": 3,
  "author": {
   "is_bot": true,
   "login": "app/dependabot"
  },
  "baseRefName": "trunk",
  "closedAt": "2026-11-23T18:24:26Z",
  "createdAt": "2026-11-23T14:03:33Z",
  "deletions": 3,
  "headRefName": "dependabot/go_modules/github.com/charmbracelet/x/ansi-0.11.10",
  "headRefOid": "b7d38765850266766f6f4662808dca6f84789afd",
  "headRepositoryOwner": {
   "id": "MDEyOk9yZ2FuaXphdGlvbjU5NzA0NzEx",
   "login": "cli"
  },
  "isCrossRepository": false,
  "isDraft": false,
  "mergeable": "UNKNOWN",
  "mergedAt": "2026-11-23T18:24:25Z",
  "number": 15145,
  "reviewDecision": "APPROVED",
  "state": "MERGED",
  "statusCheckRollup": [
   {
    "__typename": "CheckRun",
    "completedAt": "2026-11-23T14:03:42Z",
    "conclusion": "SKIPPED",
    "detailsUrl": "https://github.com/cli/cli/actions/runs/45190148370/job/137746127991",
    "name": "label-external",
    "startedAt": "2026-11-23T14:03:51Z",
    "status": "COMPLETED",
    "workflowName": "PR Triaging"
   },
   {
    "__typename": "CheckRun",
    "completedAt": "2026-11-23T14:06:40Z",
    "conclusion": "SUCCESS",
    "detailsUrl": "https://github.com/cli/cli/actions/runs/45190145097/job/137746020384",
    "name": "CodeQL-Build (go, manual, ./.github/codeql/codeql-config.yml)",
    "startedAt": "2026-11-23T14:03:43Z",
    "status": "COMPLETED",
    "workflowName": "Code Scanning"
   },
   {
    "__typename": "CheckRun",
    "completedAt": "2026-11-23T14:06:46Z",
    "conclusion": "SUCCESS",
    "detailsUrl": "https://github.com/cli/cli/actions/runs/45190145113/job/137746020291",
    "name": "lint",
    "startedAt": "2026-11-23T14:03:43Z",
    "status": "COMPLETED",
    "workflowName": "Lint"
   }
  ],
  "title": "chore(deps): Bump github.com/charmbracelet/x/ansi from 0.11.9 to 0.11.10",
  "updatedAt": "2026-11-23T18:24:29Z",
  "url": "https://github.com/cli/cli/pull/15145"
 }
]
"""#

    /// A query GitHub refused whole: errors, no `data`.
    static let refused = #"""
{"errors":[{"path":["query","r0","nope"],"extensions":{"code":"undefinedField","typeName":"Repository","fieldName":"nope"},"locations":[{"line":1,"column":53}],"message":"Field 'nope' doesn't exist on type 'Repository'"}]}
"""#
}
