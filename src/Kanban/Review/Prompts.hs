-- | Everything an embedded review session is handed: the developer
-- instructions, the opening prompt, the names and JSON schemas of the three
-- dynamic tools declared here — of which a thread registers the ones its
-- install can actually reach — and the final output schema. Two of those tool declarations — the
-- question tool and the GitHub tool — are also what a Claude review thread's
-- MCP re-entry serves, translated rather than restated
-- ('Kanban.ReviewToolServer.mcpToolDescriptor'), so this module remains their
-- one declaration site on either channel. So is the policy itself: the Codex
-- app-server takes it as @thread\/start@'s @developerInstructions@ and a
-- @claude -p@ session, which has no such field, carries it into its first
-- user message through 'reviewOpeningMessage'.
--
-- Literal but for the model names it states and the one clause the install's
-- own shape decides. The names are read out of the roster it is given — the
-- running coordinator's own @issue_review@ and the @issue_revise.claude@
-- agent @kanban_run_claude@ runs — because prose that named a model the
-- operator had replaced would be telling the reviewing model it is something
-- it is not (MODEL-3), and the same reasoning is why a thread with one
-- provider is not told to hand work to an agent it cannot reach.
--
-- Held apart from the client because nothing here is logic — no other
-- module's behavior depends on these strings, and keeping them together
-- makes the tool contracts (@kanban_prompt_user@, @kanban_run_claude@,
-- @kanban_github_issue@) readable as one document.
module Kanban.Review.Prompts
  ( claudeRevisionAvailable,
    claudeTool,
    claudeToolName,
    finalOutputSchema,
    githubTool,
    githubToolName,
    questionTool,
    questionToolName,
    reviewDeveloperInstructions,
    reviewOpeningMessage,
    reviewPrompt,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (WorkflowConfig (..))
import Kanban.Models
  ( AssignmentUnavailable (..),
    ModelRoster,
    ProviderName (..),
    RoleName (..),
    assignmentFor,
  )
import Kanban.Review.Diagnostics (claudeRevisionAgent, reviewAssignmentDisplay)
import Kanban.Review.Types (reviewWorkflowLabels)

questionToolName :: Text
questionToolName = "kanban_prompt_user"

claudeToolName :: Text
claudeToolName = "kanban_run_claude"

githubToolName :: Text
githubToolName = "kanban_github_issue"

questionTool :: Value
questionTool =
  object
    [ "type" .= ("function" :: Text),
      "name" .= questionToolName,
      "description" .= ("Ask the user a structured question through the Kanban review panel and wait for the returned answer." :: Text),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["id", "question", "kind"] :: [Text]),
            "properties"
              .= object
                [ "id" .= stringSchema,
                  "header" .= stringSchema,
                  "question" .= stringSchema,
                  "kind" .= object ["type" .= ("string" :: Text), "enum" .= (["choice", "text"] :: [Text])],
                  "options"
                    .= object
                      [ "type" .= ("array" :: Text),
                        "items"
                          .= object
                            [ "type" .= ("object" :: Text),
                              "additionalProperties" .= False,
                              "required" .= (["id", "label"] :: [Text]),
                              "properties"
                                .= object
                                  [ "id" .= stringSchema,
                                    "label" .= stringSchema,
                                    "description" .= stringSchema
                                  ]
                            ]
                      ],
                  "allowOther" .= booleanSchema,
                  "multiple" .= booleanSchema
                ]
          ]
    ]
  where
    stringSchema = object ["type" .= ("string" :: Text)]
    booleanSchema = object ["type" .= ("boolean" :: Text)]

-- | The agent the @kanban_run_claude@ tool runs, as this thread's prose
-- names it: @issue_revise.claude@ (docs\/design.md §7). Resolved from the
-- roster the client holds rather than restated, and stated as unavailable
-- rather than defaulted when a valid Codex-only roster cannot supply it --
-- which 'Kanban.Review.Tools.runAuthenticatedClaude' already refuses on.
claudeRevisionName :: ModelRoster -> Text
claudeRevisionName roster =
  claudeRevisionAgent (reviewAssignmentDisplay (assignmentFor roster IssueReviseRole ClaudeProvider))

-- | The coordinator's own identity: the @issue_review@ agent of the provider
-- whose backend is actually running this thread, which
-- 'Kanban.Review.startReviewClient' has already refused to start without.
--
-- The provider is passed rather than named because single-agent mode moves it
-- ('Kanban.ProviderAdapter.embeddedReviewProvider'), and a thread told it is
-- @issue_review.codex@ while running on Claude would be telling the reviewing
-- model it is something it is not — the same reason the display comes out of
-- the roster rather than being written down here (MODEL-3).
coordinatorName :: ModelRoster -> ProviderName -> Text
coordinatorName roster provider =
  reviewAssignmentDisplay (assignmentFor roster IssueReviewRole provider)

-- | Whether this install has a /separate/ Claude revision agent for the
-- coordinator to hand Claude-origin amendment authoring to.
--
-- Two installs have none, and the prose below drops the @kanban_run_claude@
-- clauses for both. A Claude-only install's coordinator already is that agent
-- and revises inline, so its adapter registers no such tool at all
-- ('Kanban.ProviderAdapter.claudeAdapter'). A Codex-only install loads no
-- Claude provider, so the cell resolves to unavailable and
-- 'Kanban.Review.Tools.runAuthenticatedClaude' would refuse the call.
--
-- Asked of the roster rather than of the operating mode because it is the
-- roster that either loads that provider or does not, and the same lookup
-- 'claudeRevisionName' above already makes is the one that answers it.
--
-- Only 'UnloadedProvider' drops the clauses. A roster that /loads/ Claude and
-- still cannot supply the cell is a defect in a dual install, not a
-- single-provider one: the handoff is real, so the prose keeps describing it
-- and 'claudeRevisionName' states the model as unavailable in words, which is
-- what @docs\/design.md@ requires of a surface that cannot be dimmed.
claudeRevisionAvailable :: ModelRoster -> ProviderName -> Bool
claudeRevisionAvailable roster coordinator = coordinator /= ClaudeProvider && claudeLoaded
  where
    claudeLoaded = case assignmentFor roster IssueReviseRole ClaudeProvider of
      Left (UnloadedProvider _ _) -> False
      _ -> True

claudeTool :: ModelRoster -> Value
claudeTool roster =
  object
    [ "type" .= ("function" :: Text),
      "name" .= claudeToolName,
      "description"
        .= ( "Run the authenticated "
               <> claudeRevisionName roster
               <> " specification-revision agent through Kanban outside the Codex command sandbox. Provide a standalone prompt containing the issue, effective specification, repository evidence, blockers, and exact requested amendment output."
           ),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["prompt"] :: [Text]),
            "properties" .= object ["prompt" .= object ["type" .= ("string" :: Text)]]
          ]
    ]

githubTool :: WorkflowConfig -> Value
githubTool workflowConfig =
  object
    [ "type" .= ("function" :: Text),
      "name" .= githubToolName,
      "description"
        .= ( "Read the live GitHub issue and comments, or perform the review workflow's bounded comment/label update. This is the only permitted GitHub interface for the embedded workflow."
               :: Text
           ),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["operation", "issue"] :: [Text]),
            "properties"
              .= object
                [ "operation" .= object ["type" .= ("string" :: Text), "enum" .= (["read", "update"] :: [Text])],
                  "issue" .= object ["type" .= ("integer" :: Text), "minimum" .= (1 :: Int)],
                  "comment" .= object ["type" .= (["string", "null"] :: [Text])],
                  "addLabels" .= reviewLabelArraySchema,
                  "removeLabels" .= reviewLabelArraySchema
                ]
          ]
    ]
  where
    reviewLabelArraySchema =
      object
        [ "type" .= ("array" :: Text),
          "items" .= object ["type" .= ("string" :: Text), "enum" .= reviewWorkflowLabels workflowConfig],
          "uniqueItems" .= True
        ]

reviewDeveloperInstructions :: WorkflowConfig -> ModelRoster -> ProviderName -> Text
reviewDeveloperInstructions workflowConfig roster coordinator =
  Text.unlines (openingLines <> authoringLines <> closingLines)
  where
    openingLines =
      [ "You are the interactive issue-review and specification-revision coordinator embedded inside the Kanban terminal dashboard.",
        "Never run ~/work/approve-issues.py, the installed tools/approve_issues.py backend from any path, or any background approval daemon.",
        "Advance exactly ONE workflow stage per invocation. Do not edit repository files, edit the issue body, or implement the issue.",
        "All questions requiring user input MUST use the kanban_prompt_user tool. Never ask a question in ordinary assistant prose.",
        "Use kind=choice with 2-5 concrete options when possible. Set multiple=false and ask one decision per tool call. Use kind=text only for genuinely free-form context.",
        "Read the live GitHub issue, all of its comments in chronological order, and its labels. The effective specification is the issue body plus canonical issue-comment amendments, with explicit later amendments superseding earlier conflicting text.",
        "Find the hidden <!-- issue-origin:claude --> or <!-- issue-origin:codex --> marker in the issue body.",
        "You MUST use kanban_github_issue for every GitHub issue read, comment, or review-label mutation. Never invoke gh, curl, or a GitHub API through a shell or command tool. The Kanban tool is already authenticated and its update operation is restricted to one issue comment and the three review workflow labels.",
        "Choose the one stage from live labels: reviewed:revised means REREVIEW; otherwise "
          <> workflowConfig.changesRequestedLabel
          <> " means REVISION; otherwise INITIAL REVIEW.",
        "INITIAL REVIEW and REREVIEW are owned by the canonical approve-issues.py v2 backend and must never be performed in this thread. This thread performs REVISION only."
      ]

    -- Who authors the amendment, and therefore whether the handoff tool is
    -- described at all. An install with one provider has one author for every
    -- origin marker, and naming a second agent to a thread that has no tool
    -- to reach it -- or no such agent loaded -- would describe a handoff it
    -- cannot perform.
    authoringLines
      | claudeRevisionAvailable roster coordinator =
          [ "Whenever revision requires "
              <> claudeRevisionName roster
              <> ", you MUST call kanban_run_claude. Never invoke claude, claude-code, or another Claude executable through a shell or command tool. The Kanban tool owns authenticated execution and returns Sonnet's text.",
            "The kanban_run_claude prompt must be standalone: include the issue body, relevant chronological comments/effective specification, repository evidence, blockers, and request exact amendment content. Sonnet runs in plan mode and must not be asked to edit files, post comments, or change labels.",
            "REVISION switches back to the issue author's brand: Codex-origin amendment content is authored by you as "
              <> coordinatorName roster CodexProvider
              <> "; Claude-origin amendment content is authored by "
              <> claudeRevisionName roster
              <> "; unmarked issues default to you as "
              <> coordinatorName roster CodexProvider
              <> "."
          ]
      | otherwise =
          [ "This install loads one provider, so REVISION does not switch brands: you author every amendment yourself as "
              <> coordinatorName roster coordinator
              <> ", whatever origin marker the issue carries and whether or not it carries one.",
            "There is no kanban_run_claude tool in this thread. Never invoke claude, claude-code, codex, gh, curl, or any other executable through a shell or command tool to author or publish an amendment."
          ]

    closingLines =
      [ "During REVISION, classify every latest review blocker. Resolve mechanical, repository-verifiable, or clearly implied omissions without asking. If two or more reasonable answers would change behavior, compatibility, scope, policy, migration semantics, or user-visible outcomes, ask the user through kanban_prompt_user before proceeding.",
        "After resolving every blocker during REVISION, post exactly one canonical issue comment headed '## Specification amendment'. State that it supplements the issue body, list the normative clarifications and acceptance/test changes, and end with <!-- kanban-spec-amendment -->.",
        "After posting the amendment, ensure the repository has a reviewed:revised label (create it with purple color 8250DF if missing), add it to the issue, and remove "
          <> workflowConfig.changesRequestedLabel
          <> " and "
          <> workflowConfig.approvalLabel
          <> ". Do NOT rereview or approve in the same invocation.",
        "If REVISION cannot resolve every blocker, do not post a partial amendment and leave "
          <> workflowConfig.changesRequestedLabel
          <> " in place.",
        "Never close the issue. Finish with the requested structured result. Set stage to review, revision, or rereview. For revision set approved=false; commentUrl is the amendment comment and blockingReasons contains only unresolved blockers."
      ]

-- | The whole opening message for a backend that has no separate
-- instructions channel to carry the policy on.
--
-- The Codex app-server takes 'reviewDeveloperInstructions' as @thread/start@'s
-- @developerInstructions@ and then this module's 'reviewPrompt' as the turn.
-- A @claude -p@ session has no such field — the argv this launch is pinned to
-- carries the channel, the schema, and the isolation, and nothing else
-- (D-15) — so its first user message carries both, in that order. One
-- declaration either way: the instructions a Claude review runs under are the
-- ones a Codex review runs under, differing only where
-- 'reviewDeveloperInstructions' already says the coordinator does.
reviewOpeningMessage :: WorkflowConfig -> ModelRoster -> ProviderName -> Int -> Text
reviewOpeningMessage workflowConfig roster coordinator issueNumber =
  reviewDeveloperInstructions workflowConfig roster coordinator
    <> "\n"
    <> reviewPrompt issueNumber

reviewPrompt :: Int -> Text
reviewPrompt issueNumber =
  "Perform exactly the specification REVISION stage for GitHub issue #"
    <> Text.pack (show issueNumber)
    <> " in this repository now. It has canonical CHANGES_REQUESTED state from approve-issues.py. Follow the embedded revision policy, post one authoritative amendment, and leave it ready for canonical v2 rereview."

finalOutputSchema :: Value
finalOutputSchema =
  object
    [ "type" .= ("object" :: Text),
      "additionalProperties" .= False,
      "required" .= (["issue", "stage", "approved", "reviewerRoute", "models", "commentUrl", "blockingReasons"] :: [Text]),
      "properties"
        .= object
          [ "issue" .= object ["type" .= ("integer" :: Text)],
            "stage" .= object ["type" .= ("string" :: Text), "enum" .= (["review", "revision", "rereview"] :: [Text])],
            "approved" .= object ["type" .= ("boolean" :: Text)],
            "reviewerRoute" .= object ["type" .= ("string" :: Text)],
            "models" .= object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]],
            "commentUrl" .= object ["type" .= (["string", "null"] :: [Text])],
            "blockingReasons" .= object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]]
          ]
    ]
