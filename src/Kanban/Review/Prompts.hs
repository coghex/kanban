-- | Every literal the embedded review session hands to the Codex
-- app-server: the developer instructions, the opening prompt, the three
-- dynamic tools' names and JSON schemas, and the final output schema.
--
-- Held apart from the client because nothing here is logic — no other
-- module's behavior depends on these strings, and keeping them together
-- makes the tool contracts (@kanban_prompt_user@, @kanban_run_claude@,
-- @kanban_github_issue@) readable as one document.
module Kanban.Review.Prompts
  ( claudeTool,
    claudeToolName,
    finalOutputSchema,
    githubTool,
    githubToolName,
    questionTool,
    questionToolName,
    reviewDeveloperInstructions,
    reviewPrompt,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (WorkflowConfig (..))
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

claudeTool :: Value
claudeTool =
  object
    [ "type" .= ("function" :: Text),
      "name" .= claudeToolName,
      "description"
        .= ( "Run the authenticated Claude Sonnet 5 high specification-revision agent through Kanban outside the Codex command sandbox. Provide a standalone prompt containing the issue, effective specification, repository evidence, blockers, and exact requested amendment output."
               :: Text
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

reviewDeveloperInstructions :: WorkflowConfig -> Text
reviewDeveloperInstructions workflowConfig =
  Text.unlines
    [ "You are the interactive issue-review and specification-revision coordinator embedded inside the Kanban terminal dashboard.",
      "Never run ~/work/approve-issues.py, the installed tools/approve_issues.py backend from any path, or any background approval daemon.",
      "Advance exactly ONE workflow stage per invocation. Do not edit repository files, edit the issue body, or implement the issue.",
      "All questions requiring user input MUST use the kanban_prompt_user tool. Never ask a question in ordinary assistant prose.",
      "Use kind=choice with 2-5 concrete options when possible. Set multiple=false and ask one decision per tool call. Use kind=text only for genuinely free-form context.",
      "Read the live GitHub issue, all of its comments in chronological order, and its labels. The effective specification is the issue body plus canonical issue-comment amendments, with explicit later amendments superseding earlier conflicting text.",
      "Find the hidden <!-- issue-origin:claude --> or <!-- issue-origin:codex --> marker in the issue body.",
      "You MUST use kanban_github_issue for every GitHub issue read, comment, or review-label mutation. Never invoke gh, curl, or a GitHub API through a shell or command tool. The Kanban tool is already authenticated and its update operation is restricted to one issue comment and the three review workflow labels.",
      "Whenever revision requires Claude Sonnet 5 high, you MUST call kanban_run_claude. Never invoke claude, claude-code, or another Claude executable through a shell or command tool. The Kanban tool owns authenticated execution and returns Sonnet's text.",
      "The kanban_run_claude prompt must be standalone: include the issue body, relevant chronological comments/effective specification, repository evidence, blockers, and request exact amendment content. Sonnet runs in plan mode and must not be asked to edit files, post comments, or change labels.",
      "Choose the one stage from live labels: reviewed:revised means REREVIEW; otherwise "
        <> workflowConfig.changesRequestedLabel
        <> " means REVISION; otherwise INITIAL REVIEW.",
      "INITIAL REVIEW and REREVIEW are owned by the canonical approve-issues.py v2 backend and must never be performed in this app-server thread. This thread performs REVISION only.",
      "REVISION switches back to the issue author's brand: Codex-origin amendment content is authored by you as GPT-5.4 high; Claude-origin amendment content is authored by Claude Sonnet 5 high; unmarked issues default to you as GPT-5.4 high.",
      "During REVISION, classify every latest review blocker. Resolve mechanical, repository-verifiable, or clearly implied omissions without asking. If two or more reasonable answers would change behavior, compatibility, scope, policy, migration semantics, or user-visible outcomes, ask the user through kanban_prompt_user before proceeding.",
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
