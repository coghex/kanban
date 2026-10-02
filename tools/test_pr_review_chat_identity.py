"""Optional reviewer chat identity preserves canonical invocation and JSON."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
PATHS = {'codex': ROOT/'codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py',
         **{b: ROOT/f'{b}-plugin/plugins/kanban/scripts/review_pr.py'
            for b in ('claude','grok','kimi','google','claude-copilot')}}


def load(name, path):
    spec = importlib.util.spec_from_file_location('chat_review_'+name.replace('-','_'), path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = m
    spec.loader.exec_module(m)
    return m


class ChatReviewerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.modules = {n: load(n,p) for n,p in PATHS.items()}

    def context(self):
        return {'repository':'owner/synarchy', 'pull_request':{'number':45}}

    def test_no_pchat_and_old_pchat_leave_invocation_unchanged(self):
        for name,m in self.modules.items():
            with self.subTest(bundle=name), mock.patch.object(m.shutil,'which',return_value=None):
                self.assertEqual(m.chat_reviewer_command(self.context(),m.CLAUDE_REVIEWER),[])
            with self.subTest(bundle=name), mock.patch.object(m.shutil,'which',return_value='/pchat'), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],2,'','old CLI')):
                self.assertEqual(m.chat_reviewer_command(self.context(),m.CLAUDE_REVIEWER),[])

    def test_unconfigured_repository_is_inert(self):
        for name,m in self.modules.items():
            with self.subTest(bundle=name), mock.patch.object(m.shutil,'which',return_value='/pchat'), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'{"enabled":false}','')):
                self.assertEqual(m.chat_reviewer_command(self.context(),m.CLAUDE_REVIEWER),[])

    def test_exact_repository_context_and_parent_passed_as_arguments(self):
        data={'enabled':True,'project':'synarchy','channel':'#syn-issue-27', 'parent':'syn-solver-2','request':'request-27'}
        for name,m in self.modules.items():
            with self.subTest(bundle=name), mock.patch.object(m.shutil,'which',return_value='/pchat'), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps(data),'')) as probe:
                args=m.chat_reviewer_command(self.context(),m.CLAUDE_REVIEWER)
                self.assertEqual(probe.call_args.args[0],['/pchat','agent','review-context','--repo','owner/synarchy','--json'])
                self.assertEqual(args[:3],['/pchat','agent','run'])
                for flag,value in [('--project','synarchy'),('--parent','syn-solver-2'),('--re','request-27'),('--brand','claude'),('--task','PR #45')]:
                    self.assertEqual(args[args.index(flag)+1],value)
                self.assertLess(int(args[args.index('--timeout')+1]),m.REVIEW_TIMEOUT_SECONDS)

    def test_malformed_enabled_context_is_refused(self):
        for name,m in self.modules.items():
            with self.subTest(bundle=name), mock.patch.object(m.shutil,'which',return_value='/pchat'), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'{"enabled":true,"project":"synarchy","channel":"bad"}','')):
                with self.assertRaises(m.WorkflowError):
                    m.chat_reviewer_command(self.context(),m.CLAUDE_REVIEWER)

    def test_wrapped_claude_preserves_arguments_stdin_and_stdout(self):
        prefix=['/pchat','agent','run','--project','synarchy']
        command=['claude','-p','--model','fixture','--effort','high','--output-format','json']
        output='{"structured_output":{"verdict":"APPROVE","summary":"clean","blocking_concerns":[]}}'
        for name,m in self.modules.items():
            token=m.CHAT_REVIEW_COMMAND.set(prefix)
            try:
                with self.subTest(bundle=name), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,output,'')) as spawn:
                    result=m.run(command,cwd=ROOT,input_text='prompt')
                    self.assertEqual(spawn.call_args.args[0],prefix+['--']+command)
                    self.assertEqual(spawn.call_args.kwargs['input'],'prompt')
                    self.assertEqual(result.stdout,output)
            finally:
                m.CHAT_REVIEW_COMMAND.reset(token)

    def test_wrapped_codex_retains_result_without_altering_provider_options(self):
        prefix=['/pchat','agent','run','--project','synarchy']
        command=['codex','exec','--ephemeral','--output-schema','schema.json','-o','result.json','-']
        for name,m in self.modules.items():
            token=m.CHAT_REVIEW_COMMAND.set(prefix)
            try:
                with self.subTest(bundle=name), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'transcript','')) as spawn:
                    m.run(command,cwd=ROOT,input_text='prompt')
                    self.assertEqual(spawn.call_args.args[0],prefix+['--result-file','result.json','--']+command)
            finally:
                m.CHAT_REVIEW_COMMAND.reset(token)

    def test_chat_context_does_not_wrap_other_commands(self):
        for name,m in self.modules.items():
            token=m.CHAT_REVIEW_COMMAND.set(['/pchat','agent','run'])
            try:
                with self.subTest(bundle=name), mock.patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'','')) as spawn:
                    m.run(['gh','pr','view','45'],cwd=ROOT)
                    self.assertEqual(spawn.call_args.args[0],['gh','pr','view','45'])
            finally:
                m.CHAT_REVIEW_COMMAND.reset(token)


if __name__=='__main__': unittest.main()
