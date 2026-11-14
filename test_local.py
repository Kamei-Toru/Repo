#!/usr/bin/env python3
"""Exercise all three implementations with real Git and a local fake gh CLI."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FAKE_GH = r'''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
args = sys.argv[1:]
base = pathlib.Path(os.environ['FAKE_REMOTES'])
def git(*a):
    subprocess.run(['git', *a], check=True, stdout=subprocess.DEVNULL)
if args[:2] == ['auth','status']:
    pass
elif args[:2] == ['api','user']:
    print('tester')
elif args[:1] == ['api']:
    name = args[1].split('/')[-1]
    if (base/name).exists(): print('tester/'+name)
    else:
        print('gh: Not Found (HTTP 404)', file=sys.stderr); sys.exit(1)
elif args[:2] == ['repo','create']:
    git('init','--bare','--initial-branch=main',str(base/args[2].split('/')[-1]))
elif args[:2] == ['repo','view']:
    with open(os.environ['WEB_LOG'],'a') as f: f.write(args[2]+'\n')
elif args[:2] == ['repo','clone']:
    git('clone',str(base/args[2].split('/')[-1]),args[3])
    git('-C',args[3],'remote','set-url','origin','https://github.com/'+args[2]+'.git')
else:
    print('Unexpected fake gh invocation: '+repr(args),file=sys.stderr); sys.exit(2)
'''

class RepositoryTests(unittest.TestCase):
    def test_all_engines(self):
        for executable, script in [('zsh', 'repo.zsh'), ('perl', 'repo.pl'), ('python3', 'repo.py')]:
            with self.subTest(engine=script), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                projects, remotes, binary = [root/p for p in ('Projects','remotes','bin')]
                for p in (projects, remotes, binary): p.mkdir()
                gh = binary/'gh'; gh.write_text(FAKE_GH); gh.chmod(0o755)
                ghq = binary/'ghq'; ghq.write_text('#!/bin/sh\nexit 0\n'); ghq.chmod(0o755)
                config = root/'gitconfig'
                config.write_text('[user]\n name = Test User\n email = test@example.invalid\n'
                                  f'[url "file://{remotes}/"]\n insteadOf = https://github.com/tester/\n')
                env = dict(os.environ, PATH=f'{binary}:'+os.environ['PATH'],
                           HOME=str(root), R_PROJECTS=str(projects), FAKE_REMOTES=str(remotes),
                           WEB_LOG=str(root/'web'), GIT_CONFIG_GLOBAL=str(config),
                           GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
                # Redirect URLs ending in .git to bare repositories with .git suffix.
                # Fake remotes use unsuffixed paths, so add one mapping per repository.
                def mapping(name):
                    with config.open('a') as f:
                        f.write(f'[url "file://{remotes/name}"]\n insteadOf = https://github.com/tester/{name}.git\n')
                for name in ('alpha','beta','prompted','dirty','diverged','existing','nested'):
                    mapping(name)
                def invoke(*args, data=None, ok=True):
                    p = subprocess.run([executable, str(HERE/script), *args], input=data,
                                       text=True, capture_output=True, env=env, cwd=root)
                    if ok: self.assertEqual(p.returncode, 0, p.stderr)
                    else: self.assertNotEqual(p.returncode, 0, p.stderr)
                    return p
                def git(*args):
                    return subprocess.run(['git',*map(str,args)], env=env, cwd=root,
                                          text=True, capture_output=True, check=True).stdout.strip()
                self.assertIn('Usage:', invoke('--help').stdout)
                (projects/'alpha').mkdir(); (projects/'alpha'/'hello.txt').write_text('hello\n')
                p = invoke('alpha','beta')
                self.assertEqual(p.stdout.strip(), str(projects/'alpha'))
                self.assertEqual(git('--git-dir',remotes/'alpha','show','main:hello.txt'), 'hello')
                self.assertEqual((root/'web').read_text().splitlines(), ['tester/alpha','tester/beta'])
                invoke('bad/name',data='..\nprompted\n')
                invoke(data='existing\n')
                # Reuse an existing clone even when its directory name differs.
                (projects/'alpha').rename(projects/'renamed')
                self.assertEqual(invoke('alpha').stdout.strip(), str(projects/'renamed'))
                # Fast-forward from a second clone.
                other = root/'other'
                git('clone',remotes/'alpha',other)
                (other/'hello.txt').write_text('updated\n')
                git('-C',other,'add','--all'); git('-C',other,'commit','-m','Update')
                git('-C',other,'push','origin','main')
                invoke('alpha')
                self.assertEqual((projects/'renamed'/'hello.txt').read_text(), 'updated\n')
                (projects/'renamed'/'hello.txt').write_text('dirty\n')
                invoke('alpha',ok=False)
                invoke('alpha','beta',ok=False)
                # A later failure must retain the first successful destination.
                self.assertEqual(invoke('beta','alpha',ok=False).stdout.strip(),str(projects/'beta'))
                # Verify parent-shell cd for each engine and fuzzy navigation.
                for command in ('rz', 'rp', 'ry'):
                    p = subprocess.run(['zsh', '-c',
                        'source "$1"; '+command+' beta || exit $?; print -r -- "$PWD"',
                        'test', str(HERE/'shell.zsh')], env=env, cwd=root,
                        text=True, capture_output=True)
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertEqual(p.stdout.strip(), str(projects/'beta'))
                fzf = binary/'fzf'
                fzf.write_text('#!/usr/bin/env python3\nimport sys\nitems=sys.stdin.buffer.read().split(b"\\0")\nsys.stdout.buffer.write(next(x for x in items if x.endswith(b"/beta"))+b"\\0")\n')
                fzf.chmod(0o755)
                p = subprocess.run(['zsh', '-c',
                    'source "$1"; rf || exit $?; print -r -- "$PWD"',
                    'test', str(HERE/'shell.zsh')], env=env, cwd=root,
                    text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout.strip(), str(projects/'beta'))
                # Reject conflicting remotes before creating a remote repository.
                d = projects/'dirty'; d.mkdir(); git('-C',d,'init','-b','main')
                git('-C',d,'remote','add','origin','https://github.com/other/dirty.git')
                invoke('dirty',ok=False); self.assertFalse((remotes/'dirty').exists())
                # Reject destinations nested in another worktree.
                git('-C', projects,'init','-b','main')
                (projects/'nested').mkdir(); (projects/'nested'/'x').write_text('x')
                invoke('nested',ok=False); self.assertFalse((remotes/'nested').exists())

if __name__ == '__main__':
    unittest.main()
