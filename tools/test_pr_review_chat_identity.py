"""Optional reviewer chat identity preserves canonical invocation and JSON."""
import importlib.util
import json
import os
import signal
import time
import textwrap
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
                with self.subTest(bundle=name), mock.patch.object(m,'run_chat_reviewer',return_value=subprocess.CompletedProcess([],0,output,'')) as spawn:
                    result=m.run(command,cwd=ROOT,input_text='prompt')
                    self.assertEqual(spawn.call_args.args,(prefix,command))
                    self.assertEqual(spawn.call_args.kwargs['input_text'],'prompt')
                    self.assertEqual(result.stdout,output)
            finally:
                m.CHAT_REVIEW_COMMAND.reset(token)

    def test_wrapped_codex_retains_result_without_altering_provider_options(self):
        prefix=['/pchat','agent','run','--project','synarchy']
        command=['codex','exec','--ephemeral','--output-schema','schema.json','-o','result.json','-']
        for name,m in self.modules.items():
            token=m.CHAT_REVIEW_COMMAND.set(prefix)
            try:
                with self.subTest(bundle=name), mock.patch.object(m,'run_chat_reviewer',return_value=subprocess.CompletedProcess([],0,'transcript','')) as spawn:
                    m.run(command,cwd=ROOT,input_text='prompt')
                    self.assertEqual(spawn.call_args.args,(prefix+['--result-file','result.json'],command))
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


# Reproduce pchat's detached child and cancellation handler with real processes.
# The reviewer ignores TERM, so merely forwarding a signal cannot pass. The
# rmtree assertion is inside run_reviews' actual finally, before source removal.
FAKE_PCHAT = r"""
import os, signal, subprocess, sys, time
from pathlib import Path
child = None
def stop(signum, frame):
    if child and child.poll() is None:
        os.killpg(child.pid, signum)
    raise KeyboardInterrupt
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, stop)
try:
    payload = sys.stdin.read()
    child = subprocess.Popen(sys.argv[sys.argv.index('--')+1:],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True)
    if os.environ['EXIT_MODE'] in ('normal', 'error'):
        # Also prove ownership when the wrapper abandons a live reviewer.
        child.stdin.write(payload)
        child.stdin.close()
        while not Path(os.environ['PID_FILE']).exists():
            time.sleep(.01)
        sys.exit(0 if os.environ['EXIT_MODE'] == 'normal' else 7)
    out, err = child.communicate(payload, timeout=60)
    sys.stdout.write(out)
    sys.stderr.write(err)
except KeyboardInterrupt:
    if child and child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
    if child:
        child.communicate()
    sys.exit(130)
"""

FAKE_REVIEWER = r"""#!/usr/bin/env python3
import os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
payload = sys.stdin.read()
assert payload == 'fixture prompt'
Path(os.environ['PID_FILE']).write_text(str(os.getpid()))
if os.environ['EXIT_MODE'] == 'complete':
    import json
    print(json.dumps({'argv': sys.argv[1:], 'prompt': payload}))
    print('fixture stderr', file=sys.stderr)
    sys.exit(0)
while True:
    time.sleep(.01)
"""

COORDINATOR = r"""
import importlib.util, os, signal, sys
from pathlib import Path
from unittest import mock
spec = importlib.util.spec_from_file_location('lifetime_coordinator', sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)
source, wrapper, pid_file, evidence = map(Path, sys.argv[2:])
original = m.shutil.rmtree
def remove(path, *args, **kwargs):
    if Path(path) == source:
        pid = int(pid_file.read_text())
        # A killed process can remain a zombie briefly when a deliberately
        # broken wrapper exits without reaping it. Zombies cannot use source.
        status = __import__('subprocess').run(
            ['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True
        ).stdout.strip()
        assert not status or status.startswith('Z'), 'reviewer survived source cleanup'
        assert source.is_dir()
        evidence.write_text('reviewer ended before source cleanup')
    return original(path, *args, **kwargs)
def invoke(*args):
    return m.run(['claude'], cwd=source, input_text='fixture prompt',
                 timeout=2 if os.environ['EXIT_MODE'] == 'timeout' else 20)
try:
    with mock.patch.object(m, 'prepare_review_prompt', return_value='fixture prompt'), \
         mock.patch.object(m, 'chat_reviewer_command', return_value=[sys.executable, str(wrapper)]), \
         mock.patch.object(m, 'invoke_reviewer', side_effect=invoke), \
         mock.patch.object(m.shutil, 'rmtree', side_effect=remove):
        m.run_reviews([m.CLAUDE_REVIEWER], {}, lambda: source, False)
except (KeyboardInterrupt, SystemExit, m.WorkflowError):
    pass
"""


class DetachedReviewerLifetimeTests(unittest.TestCase):
    def wait_for(self, predicate, process, timeout=10):
        deadline = time.monotonic() + timeout
        while not predicate():
            if process.poll() is not None:
                self.fail('coordinator exited before reviewer started: ' + process.communicate()[1])
            if time.monotonic() >= deadline:
                self.fail('reviewer did not start')
            time.sleep(.01)

    def exercise(self, bundle, mode):
        with tempfile.TemporaryDirectory(prefix='review-lifetime-test-') as directory:
            folder = Path(directory)
            source = folder/'extracted-source'
            source.mkdir()
            wrapper, coordinator = folder/'pchat.py', folder/'coordinator.py'
            wrapper.write_text(textwrap.dedent(FAKE_PCHAT))
            coordinator.write_text(textwrap.dedent(COORDINATOR))
            reviewer = folder/'claude'
            reviewer.write_text(textwrap.dedent(FAKE_REVIEWER))
            reviewer.chmod(0o755)
            pid_file, evidence = folder/'reviewer.pid', folder/'cleanup-evidence'
            env = dict(os.environ, PATH=str(folder)+os.pathsep+os.environ['PATH'],
                       PID_FILE=str(pid_file), EXIT_MODE=mode)
            process = subprocess.Popen([sys.executable, str(coordinator),
                str(PATHS[bundle]), str(source), str(wrapper), str(pid_file), str(evidence)],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            pid = None
            try:
                self.wait_for(pid_file.exists, process)
                pid = int(pid_file.read_text())
                if mode in ('interrupt', 'terminate'):
                    process.send_signal(signal.SIGINT if mode == 'interrupt' else signal.SIGTERM)
                out, err = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, out+err)
                self.assertEqual(evidence.read_text(), 'reviewer ended before source cleanup')
                self.assertFalse(source.exists())
                status = subprocess.run(['ps','-o','stat=','-p',str(pid)],
                    capture_output=True, text=True).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'), 'reviewer still running')
                if mode in ('interrupt', 'terminate', 'timeout'):
                    # The pchat-compatible wrapper must also have reaped it.
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                # Baseline failures must not leak the deliberately orphaned child.
                if pid_file.exists():
                    pid = int(pid_file.read_text())
                if pid:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if process.poll() is None:
                    process.kill()
                process.communicate()

    def test_real_wrapped_success_preserves_provider_argv_and_streams(self):
        for bundle, path in PATHS.items():
            with self.subTest(bundle=bundle), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                wrapper, reviewer = folder/'pchat.py', folder/'claude'
                wrapper.write_text(textwrap.dedent(FAKE_PCHAT))
                reviewer.write_text(textwrap.dedent(FAKE_REVIEWER))
                reviewer.chmod(0o755)
                m = load('success_'+bundle, path)
                env = dict(os.environ, PATH=str(folder)+os.pathsep+os.environ['PATH'],
                           PID_FILE=str(folder/'pid'), EXIT_MODE='complete')
                token = m.CHAT_REVIEW_COMMAND.set([sys.executable, str(wrapper)])
                try:
                    with mock.patch.dict(os.environ, env):
                        result = m.run(['claude', '-p', '--output-format', 'json'],
                                       cwd=folder, input_text='fixture prompt')
                    self.assertEqual(json.loads(result.stdout),
                                     {'argv': ['-p','--output-format','json'],
                                      'prompt': 'fixture prompt'})
                    self.assertEqual(result.stderr, 'fixture stderr\n')
                finally:
                    m.CHAT_REVIEW_COMMAND.reset(token)

    def test_detached_reviewer_ends_before_source_cleanup_on_every_exit(self):
        for bundle in PATHS:
            for mode in ('interrupt', 'terminate', 'timeout', 'normal', 'error'):
                with self.subTest(bundle=bundle, exit=mode):
                    self.exercise(bundle, mode)


if __name__=='__main__': unittest.main()
