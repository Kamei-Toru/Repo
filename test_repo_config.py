#!/usr/bin/env python3
# Version: 1.7a
"""Isolated configuration and runtime tests; no real GitHub or GUI calls."""
import json
import sys
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT_VERSION = "1.7a"

HERE = Path(__file__).resolve().parent
FAKE_GH = r'''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]
with open(os.environ['FAKE_LOG'],'a') as f: f.write(json.dumps(['gh',*args])+'\n')
base=pathlib.Path(os.environ['FAKE_REMOTES'])
def git(*a): subprocess.run(['git',*a],check=True,stdout=subprocess.DEVNULL)
if args[:2]==['auth','status']: pass
elif args[:2]==['api','user']: print('tester')
elif args[:1]==['api']:
 name=args[1].split('/')[-1]
 if (base/(name+'.git')).exists(): print('tester/'+name)
 else: print('gh: Not Found (HTTP 404)',file=sys.stderr);sys.exit(1)
elif args[:2]==['repo','create']:
 git('init','--bare','--initial-branch=main',str(base/(args[2].split('/')[-1]+'.git')))
elif args[:2]==['repo','clone']:
 git('clone',str(base/(args[2].split('/')[-1]+'.git')),args[3])
 git('-C',args[3],'remote','set-url','origin','https://github.com/'+args[2]+'.git')
elif args[:2]==['repo','view']: pass
else: print('Unexpected fake gh call',file=sys.stderr);sys.exit(2)
'''
FAKE_OSA = r'''#!/usr/bin/env python3
import json,os,sys
if 'AXRaise' in sys.argv[2]:
 with open(os.environ['FAKE_LOG'],'a') as f: f.write(json.dumps(['focus',os.getcwd()])+'\n')
 if os.environ.get('FOCUS_FAIL'):
  print('Simulated activation failure',file=sys.stderr);sys.exit(3)
 print(os.environ.get('FOCUS_RESULT','TTY'))
else: print('/Applications/Terminal.app/')
'''


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.home=Path(self.temp.name).resolve()
        self.actual=self.home/'Projects/Repo';self.actual.mkdir(parents=True)
        self.public=self.home/'Repo';self.public.mkdir()
        for name in ('repo_conf.zsh','repo_term.zsh','repo.py','repo.pl','repo.zsh','repo_shell.zsh'):
            shutil.copy2(HERE/name,self.actual/name)
            (self.public/name).symlink_to(self.actual/name)
        self.binary=self.home/'bin';self.binary.mkdir()
        self.remotes=self.home/'remotes';self.remotes.mkdir()
        self.log=self.home/'calls.jsonl';self.log.write_text('')
        self.exe('gh',FAKE_GH);self.exe('osascript',FAKE_OSA)
        self.exe('ghq', '#!/usr/bin/env python3\nimport json,os\nwith open(os.environ["FAKE_LOG"],"a") as f: f.write(json.dumps(["ghq"])+"\\n")\n')
        self.exe('fzf','#!/usr/bin/env python3\nimport sys\nitems=[x for x in sys.stdin.buffer.read().split(b"\\0") if x]\nsys.stdout.buffer.write(items[0]+b"\\0")\n')
        gitconfig=self.home/'gitconfig'
        gitconfig.write_text('[user]\n name = Test User\n email = test@example.invalid\n'+
                             f'[url "file://{self.remotes}/"]\n insteadOf = https://github.com/tester/\n')
        self.env=dict(os.environ,HOME=str(self.home),PATH=str(self.binary)+':'+os.environ['PATH'],
                      R_HOME=str(self.public),FAKE_REMOTES=str(self.remotes),FAKE_LOG=str(self.log),
                      GIT_CONFIG_GLOBAL=str(gitconfig),GIT_CONFIG_NOSYSTEM='1',GIT_TERMINAL_PROMPT='0')
        for key in ('R_PROJECTS','R_ENGINE','R_FOCUS_DEBUG','R_DEFER_FOCUS','R_RETURN_APP','R_CALLER_TTY'):
            self.env.pop(key,None)

    def tearDown(self): self.temp.cleanup()
    def exe(self,name,text):
        p=self.binary/name;p.write_text(text);p.chmod(0o755)
    def run_command(self,args,ok=True,extra=None,data=None):
        p=subprocess.run(list(map(str,args)),cwd=self.home,env=dict(self.env,**(extra or {})),
                         text=True,input=data,capture_output=True,timeout=30)
        if ok: self.assertEqual(p.returncode,0,p.stderr)
        else: self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        return p
    def conf(self,*args,**kw): return self.run_command(['zsh',self.public/'repo_conf.zsh',*args],**kw)
    def values(self): return dict(line.split('=',1) for line in self.conf('--env').stdout.splitlines())
    def calls(self): return [json.loads(x) for x in self.log.read_text().splitlines()]
    def git(self,*args): return self.run_command(['git',*args]).stdout.strip()
    def repo(self,engine,*args,**kw):
        return self.run_command([{'zsh':'zsh','perl':'perl','python':'python3'}[engine],
                                 self.public/('repo.'+{'zsh':'zsh','perl':'pl','python':'py'}[engine]),*args],**kw)
    def shell(self,code,**kw):
        return self.run_command(['zsh','-c','source "$HOME/Repo/repo_shell.zsh"; '+code],**kw)

    def test_help_has_no_config_side_effect(self):
        for option in ('-h','--help','—help'):
            p=self.conf(option);self.assertIn('Exit status:',p.stdout)
        for engine in ('zsh','perl','python'):
            self.assertIn('Usage:',self.repo(engine,'-h').stdout)
        self.assertFalse((self.actual/'rep.conf').exists())

    def test_defaults_update_spaces_and_missing_real_file(self):
        cfg=self.values()
        self.assertEqual(cfg['PROJECTS_DIR'],str(self.home/'Projects'))
        self.assertEqual(cfg['VISIBILITY'],'private')
        self.assertIn('# Version: 1.7a',(self.actual/'rep.conf').read_text())
        self.assertTrue((self.public/'rep.conf').is_symlink())
        root=self.home/'Work projects'
        self.conf('--dir',root,'--visibility','public','ENGINE=python')
        self.assertTrue(root.is_dir())
        self.conf('OPEN_WEB=false')
        self.assertEqual(self.values()['VISIBILITY'],'public')
        self.assertEqual(self.values()['ENGINE'],'python')
        (self.actual/'rep.conf').unlink()
        self.assertEqual(self.values()['VISIBILITY'],'private')
        self.assertTrue((self.actual/'rep.conf').is_file())

    def test_directory_link_and_invalid_settings(self):
        for link in self.public.iterdir(): link.unlink()
        self.public.rmdir();self.public.symlink_to(self.actual,target_is_directory=True)
        self.conf()
        original=(self.actual/'rep.conf').read_bytes()
        for invalid in ('VISIBILITY=internal','OPEN_WEB=maybe','UNKNOWN=x','DEFAULT_BRANCH=bad name','PROJECTS_DIR=relative','COMMIT_MESSAGE=bad\x01value'):
            self.conf(invalid,ok=False)
            self.assertEqual((self.actual/'rep.conf').read_bytes(),original)
        (self.actual/'rep.conf').write_text('OPEN_WEB=true\nOPEN_WEB=false\n')
        self.conf('--env',ok=False)
        self.conf('--reset')
        self.assertEqual(self.values()['OPEN_WEB'],'true')

    def test_literal_values_are_not_executed(self):
        marker=self.home/'SHOULD_NOT_EXIST'
        text=f'$(touch {marker}) `touch {marker}` "quoted" = literal'
        self.conf('COMMIT_MESSAGE='+text)
        self.assertEqual(self.values()['COMMIT_MESSAGE'],text)
        self.assertFalse(marker.exists())

    def test_all_engines_visibility_import_and_paths(self):
        for engine in ('zsh','perl','python'):
            with self.subTest(engine=engine):
                root=self.home/('Work '+engine)
                self.conf('--dir',root,'--visibility','public','OPEN_WEB=false','USE_GHQ=false',
                          'COMMIT_MESSAGE=Configured import','DEFAULT_BRANCH=develop')
                name='import-'+engine;local=root/name;local.mkdir();(local/'hello.txt').write_text('hello\n')
                self.log.write_text('')
                p=self.repo(engine,name)
                self.assertEqual(p.stdout.strip(),str(local))
                self.assertIn(['gh','repo','create','tester/'+name,'--public'],self.calls())
                self.assertFalse(any(c[0]=='ghq' or c[:3]==['gh','repo','view'] or c[0]=='focus' for c in self.calls()))
                self.assertEqual(self.git('-C',local,'branch','--show-current'),'develop')
                self.assertEqual(self.git('-C',local,'log','-1','--format=%s'),'Configured import')
                self.assertEqual(self.git('--git-dir',self.remotes/(name+'.git'),'show','develop:hello.txt'),'hello')
                self.conf('--visibility','private')
                self.repo(engine,'private-'+engine)
                self.assertIn(['gh','repo','create','tester/private-'+engine,'--private'],self.calls())

    def test_repo_recreates_missing_config_and_retains_dirty_navigation(self):
        for engine in ('zsh','perl','python'):
            with self.subTest(engine=engine):
                # Defaults are recreated before any GitHub operation.
                real=self.actual/'rep.conf'
                if real.exists(): real.unlink()
                name='default-'+engine
                self.repo(engine,name)
                self.assertTrue(real.is_file())
                self.assertIn(['gh','repo','create','tester/'+name,'--private'],self.calls())
                local=self.home/'Projects'/name
                (local/'untracked.txt').write_text('retain\n')
                p=self.repo(engine,name,ok=False)
                self.assertEqual(p.stdout.strip(),str(local))
                self.assertEqual((local/'untracked.txt').read_text(),'retain\n')
                self.conf('SYNC_EXISTING=false','OPEN_WEB=false')
                self.repo(engine,name)

    def test_import_disable_and_engine_selection(self):
        self.conf('IMPORT_EXISTING=false','OPEN_WEB=false','USE_GHQ=false','ENGINE=python')
        root=Path(self.values()['PROJECTS_DIR'])
        for engine in ('zsh','perl','python'):
            local=root/('no-import-'+engine);local.mkdir();(local/'file.txt').write_text('keep')
            self.repo(engine,local.name)
            p=self.run_command(['git','-C',local,'rev-parse','--verify','HEAD'],ok=False)
            self.assertNotEqual(p.returncode,0)
            self.assertTrue((local/'file.txt').is_file())
        p=self.shell('repo selected; result=$?; print -r -- "$PWD"; exit $result')
        self.assertEqual(p.stdout.strip(),str(root/'selected'))
        self.assertEqual(self.values()['ENGINE'],'python')
        self.assertIn('1.7a',self.shell('repo --version').stdout)

    def test_web_focus_controls_and_rf(self):
        self.conf('ENGINE=zsh','USE_GHQ=false','RETURN_TERMINAL=false')
        self.log.write_text('');self.shell('repo web1')
        self.assertTrue(any(c[:3]==['gh','repo','view'] for c in self.calls()))
        self.assertFalse(any(c[0]=='focus' for c in self.calls()))
        self.conf('RETURN_TERMINAL=true','FOCUS_DEBUG=false')
        self.log.write_text('');p=self.shell('repo web1')
        self.assertTrue(any(c[0]=='focus' for c in self.calls()))
        self.assertNotIn('Terminal restored',p.stderr)
        self.conf('FOCUS_DEBUG=true')
        self.assertIn('Terminal restored',self.shell('repo web1').stderr)
        self.conf('OPEN_WEB=false')
        self.log.write_text('')
        p=self.shell('rf; print -r -- "$PWD"')
        self.assertIn('/web1',p.stdout)
        self.assertEqual(self.calls(),[])

    def test_tilde_sparse_config_and_invalid_runtime_config(self):
        self.conf('--dir','~/Nested Work/root')
        self.assertEqual(self.values()['PROJECTS_DIR'],str(self.home/'Nested Work/root'))
        self.assertTrue((self.home/'Nested Work/root').is_dir())
        self.conf('OPEN_WEB=false')
        self.log.write_text('')
        (self.actual/'rep.conf').write_text('VISIBILITY=invalid\n')
        for engine in ('zsh','perl','python'):
            self.repo(engine,'must-not-create',ok=False)
        self.assertEqual(self.calls(),[])
        self.assertEqual((self.actual/'rep.conf').read_text(),'VISIBILITY=invalid\n')
        (self.actual/'rep.conf').write_text('VISIBILITY=public\n')
        self.assertEqual(self.values()['ENGINE'],'zsh')
        self.assertEqual(self.values()['VISIBILITY'],'public')

    def test_installer_accepts_directory_link_and_numbers_startup_backup(self):
        for link in self.public.iterdir(): link.unlink()
        self.public.rmdir();self.public.symlink_to(self.actual,target_is_directory=True)
        startup=self.home/'Projects/Dotfiles/.zshrc';startup.parent.mkdir()
        startup.write_text('source "$HOME/Projects/Repo/repo_shell.zsh"\n')
        (self.home/'.zshrc').symlink_to(startup)
        from datetime import datetime
        backup=self.home/('.zshrc.'+datetime.now().strftime('%Y%m%d'))
        backup.write_text('Existing backup')
        self.run_command(['zsh',HERE/'repo_install.zsh'])
        self.assertTrue(self.public.is_symlink())
        self.assertEqual(backup.read_text(),'Existing backup')
        self.assertIn('Projects/Repo/repo_shell.zsh',backup.with_name(backup.name+'.1').read_text())
        self.assertTrue((self.public/'rep.conf').is_file())

    def test_install_preserves_config_git_and_startup_backups(self):
        self.conf('VISIBILITY=public','OPEN_WEB=false')
        config=(self.actual/'rep.conf').read_bytes()
        (self.actual/'.git').mkdir();(self.actual/'.git/marker').write_text('preserve')
        startup=self.home/'Projects/Dotfiles/.zshrc';startup.parent.mkdir()
        startup.write_text('# Custom\nsource "$HOME/Projects/Repo/repo_shell.zsh"\n')
        (self.home/'.zshrc').symlink_to(startup)
        for _ in range(2):
            self.run_command(['zsh',HERE/'repo_install.zsh'])
            self.assertEqual((self.actual/'rep.conf').read_bytes(),config)
            self.assertEqual((self.actual/'.git/marker').read_text(),'preserve')
            self.assertTrue((self.public/'repo_conf.zsh').is_symlink())
            self.assertTrue((self.public/'rep.conf').is_symlink())
        self.assertIn('source "$HOME/Repo/repo_shell.zsh"',startup.read_text())
        self.assertEqual(len(list(self.home.glob('.zshrc.[0-9]*'))),1)

    def test_check_mode_is_read_only_and_rejects_empty_keys(self):
        absent=self.home/'Must not be created'
        self.conf('--dir',absent,'--check')
        self.assertFalse(absent.exists())
        self.assertFalse((self.actual/'rep.conf').exists())
        self.assertFalse((self.public/'rep.conf').is_symlink())
        self.assertFalse((self.home/'.repo-locks').exists())
        self.conf('=bad',ok=False)
        self.assertFalse((self.actual/'rep.conf').exists())
        self.conf('VISIBILITY=private')
        original=(self.actual/'rep.conf').read_bytes()
        self.conf('VISIBILITY=public','--check')
        self.assertEqual((self.actual/'rep.conf').read_bytes(),original)

    def test_conflicting_modes_and_invalid_encoding_are_rejected(self):
        self.conf('--check','--show',ok=False)
        self.assertFalse((self.actual/'rep.conf').exists())
        self.conf('COMMIT_MESSAGE=日本語のメッセージ')
        self.assertEqual(self.values()['COMMIT_MESSAGE'],'日本語のメッセージ')
        real=self.actual/'rep.conf'
        for data in (b'COMMIT_MESSAGE=bad\xfftext\n',b'COMMIT_MESSAGE=bad\x00text\n'):
            real.write_bytes(data)
            self.conf('--env',ok=False)
            self.assertEqual(real.read_bytes(),data)

    def test_concurrent_updates_do_not_lose_settings(self):
        self.conf()
        real_git=shutil.which('git',path=self.env['PATH'])
        self.exe('git', '#!/usr/bin/env python3\nimport os,sys,time\nif sys.argv[1:3]==["check-ref-format","--branch"]: time.sleep(0.2)\nos.execv('+repr(real_git)+',[ '+repr(real_git)+' ,*sys.argv[1:]])\n'.replace('\\n','\n'))
        updates={'VISIBILITY':'public','ENGINE':'python','OPEN_WEB':'false','COMMIT_MESSAGE':'Concurrent update'}
        jobs=[subprocess.Popen(['zsh',str(self.public/'repo_conf.zsh'),key+'='+value],
                               cwd=self.home,env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
              for key,value in updates.items()]
        for job in jobs:
            out,err=job.communicate(timeout=20)
            self.assertEqual(job.returncode,0,err+out)
        cfg=self.values()
        for key,value in updates.items(): self.assertEqual(cfg[key],value)
        self.assertEqual(list(self.actual.glob('.rep.conf.*')),[])

    def test_physical_config_symlink_is_rejected(self):
        self.conf()
        real=self.actual/'rep.conf';outside=self.home/'outside.conf'
        real.rename(outside);before=outside.read_bytes();real.symlink_to(outside)
        self.conf('VISIBILITY=public',ok=False)
        self.assertTrue(real.is_symlink())
        self.assertEqual(outside.read_bytes(),before)

    def test_invalid_config_aborts_install_before_writes(self):
        (self.actual/'rep.conf').write_text('VISIBILITY=invalid\n'.replace('\\n','\n'))
        (self.actual/'repo_shell.zsh').write_text('# Keep installed integration\n'.replace('\\n','\n'))
        before={p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        links={p.name:p.readlink() for p in self.public.iterdir() if p.is_symlink()}
        self.run_command(['zsh',HERE/'repo_install.zsh'],ok=False)
        self.assertEqual({p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()},before)
        self.assertEqual({p.name:p.readlink() for p in self.public.iterdir() if p.is_symlink()},links)
        self.assertFalse((self.home/'.repo-backups').exists())
        self.assertFalse((self.home/'.zshrc').exists())

    def test_installer_rolls_back_after_provisioning_failure(self):
        self.conf('OPEN_WEB=false')
        (self.actual/'repo_shell.zsh').write_text('# Original integration\n'.replace('\\n','\n'))
        (self.actual/'.git').mkdir();(self.actual/'.git/marker').write_text('keep')
        before={p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        links={p.name:p.readlink() for p in self.public.iterdir() if p.is_symlink()}
        real_zsh=shutil.which('zsh',path=self.env['PATH'])
        self.exe('zsh', '#!/usr/bin/env python3\nimport os,sys\nif sys.argv[-1:]==["--env"]:\n print("Simulated configuration provisioning failure",file=sys.stderr);sys.exit(1)\nos.execv('+repr(real_zsh)+',[ '+repr(real_zsh)+' ,*sys.argv[1:]])\n'.replace('\\n','\n'))
        p=self.run_command([real_zsh,HERE/'repo_install.zsh'],ok=False)
        self.assertIn('Simulated configuration provisioning failure',p.stderr)
        self.assertEqual({p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()},before)
        self.assertEqual({p.name:p.readlink() for p in self.public.iterdir() if p.is_symlink()},links)
        self.assertEqual((self.actual/'.git/marker').read_text(),'keep')
        self.assertFalse((self.home/'.zshrc').exists())

    def test_non_utf8_startup_aborts_before_replacing_files(self):
        self.conf()
        startup = self.home / 'Projects/Dotfiles/.zshrc'
        startup.parent.mkdir()
        startup.write_bytes(b'# invalid startup \xff\n')
        (self.home / '.zshrc').symlink_to(startup)
        (self.actual / 'repo_shell.zsh').write_text('# Original integration\n')
        before = {p.name: p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        self.run_command(['zsh', HERE / 'repo_install.zsh'], ok=False)
        self.assertEqual({p.name: p.read_bytes() for p in self.actual.iterdir() if p.is_file()}, before)
        self.assertFalse((self.home / '.repo-backups').exists())

    def test_concurrent_startup_edit_is_not_overwritten(self):
        self.conf('OPEN_WEB=false')
        startup = self.home / 'Projects/Dotfiles/.zshrc'
        startup.parent.mkdir()
        startup.write_text('source "$HOME/Projects/Repo/repo_shell.zsh"\n')
        (self.home / '.zshrc').symlink_to(startup)
        (self.actual / 'repo_shell.zsh').write_text('# Original integration\n')
        before = {p.name: p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        real_zsh = shutil.which('zsh', path=self.env['PATH'])
        wrapper = (
            '#!/usr/bin/env python3\n'
            'import os, sys, pathlib\n'
            'if sys.argv[-1:] == ["--env"]:\n'
            '    (pathlib.Path.home()/"Projects/Dotfiles/.zshrc").write_text("# User edit during install\\n")\n'
            f'os.execv({real_zsh!r}, [{real_zsh!r}, *sys.argv[1:]])\n'
        )
        self.exe('zsh', wrapper)
        result = self.run_command([real_zsh, HERE / 'repo_install.zsh'], ok=False)
        self.assertIn('changed during installation', result.stderr)
        self.assertEqual(startup.read_text(), '# User edit during install\n')
        self.assertEqual({p.name: p.read_bytes() for p in self.actual.iterdir() if p.is_file()}, before)

    def test_installer_rolls_back_on_termination(self):
        self.conf('OPEN_WEB=false')
        (self.actual/'repo_shell.zsh').write_text('# Keep this integration\n'.replace('\\n','\n'))
        before={p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        real_zsh=shutil.which('zsh',path=self.env['PATH'])
        self.exe('zsh', '#!/usr/bin/env python3\nimport os,sys,signal,time\nif sys.argv[-1:]==["--env"]:\n os.kill(os.getppid(),signal.SIGTERM);time.sleep(0.1);sys.exit(1)\nos.execv('+repr(real_zsh)+',[ '+repr(real_zsh)+' ,*sys.argv[1:]])\n'.replace('\\n','\n'))
        p=self.run_command([real_zsh,HERE/'repo_install.zsh'],ok=False)
        self.assertEqual(p.returncode,130,p.stderr)
        self.assertEqual({p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()},before)
        self.assertFalse((self.home/'.zshrc').exists())

    def test_empty_push_url_is_rejected(self):
        self.conf('OPEN_WEB=false','USE_GHQ=false','IMPORT_EXISTING=false')
        root=Path(self.values()['PROJECTS_DIR'])
        for engine in ('zsh','perl','python'):
            name='empty-url-'+engine;local=root/name;local.mkdir()
            self.git('-C',local,'init','-b','main')
            self.git('-C',local,'remote','add','origin','https://github.com/tester/'+name+'.git')
            self.git('-C',local,'config','remote.origin.pushurl','')
            self.log.write_text('')
            p=self.repo(engine,name,ok=False)
            self.assertIn('Conflicting remote pushurl',p.stderr)
            self.assertFalse(any(c[:3]==['gh','repo','create'] for c in self.calls()))

    def test_push_and_multiple_fetch_urls_are_checked_before_creation(self):
        self.conf('OPEN_WEB=false','USE_GHQ=false')
        root=Path(self.values()['PROJECTS_DIR'])
        forbidden=self.home/'forbidden.git';self.git('init','--bare',forbidden)
        for engine in ('zsh','perl','python'):
            for field in ('pushurl','url'):
                with self.subTest(engine=engine,field=field):
                    name='unsafe-'+field+'-'+engine;local=root/name;local.mkdir()
                    self.git('-C',local,'init','-b','main');(local/'keep.txt').write_text('keep')
                    if field=='pushurl':
                        self.git('-C',local,'remote','add','origin','https://github.com/tester/'+name+'.git')
                        self.git('-C',local,'config','remote.origin.pushurl',forbidden.as_uri())
                    else:
                        self.git('-C',local,'remote','add','origin',forbidden.as_uri())
                        self.git('-C',local,'config','--add','remote.origin.url','https://github.com/tester/'+name+'.git')
                    self.log.write_text('')
                    p=self.repo(engine,name,ok=False)
                    self.assertIn('Conflicting remote '+field,p.stderr)
                    self.assertFalse(any(c[:3]==['gh','repo','create'] for c in self.calls()))
                    self.assertFalse((self.remotes/(name+'.git')).exists())
                    self.assertEqual((local/'keep.txt').read_text(),'keep')
                    self.run_command(['git','-C',local,'rev-parse','--verify','HEAD'],ok=False)

    def test_dirty_worktree_returns_path_before_fetch_failure(self):
        self.conf('OPEN_WEB=false','USE_GHQ=false')
        root=Path(self.values()['PROJECTS_DIR'])
        for engine in ('zsh','perl','python'): self.repo(engine,'dirty-'+engine)
        real_git=shutil.which('git',path=self.env['PATH'])
        marker=self.home/'FETCH_CALLED'
        self.exe('git', '#!/usr/bin/env python3\nimport os,sys,pathlib\nif "fetch" in sys.argv[1:]:\n pathlib.Path('+repr(str(marker))+').touch();sys.exit(77)\nos.execv('+repr(real_git)+',[ '+repr(real_git)+' ,*sys.argv[1:]])\n'.replace('\\n','\n'))
        for engine in ('zsh','perl','python'):
            local=root/('dirty-'+engine);(local/'retain.txt').write_text('retain')
            p=self.repo(engine,local.name,ok=False)
            self.assertIn('Working tree has changes',p.stderr)
            self.assertEqual(p.stdout.strip(),str(local))
            self.assertEqual((local/'retain.txt').read_text(),'retain')
        self.assertFalse(marker.exists())

    def test_shared_focus_results_and_direct_exit_status(self):
        for result in ('TTY','FRONT'):
            p=self.run_command(['zsh',self.public/'repo_term.zsh','restore','/Applications/Terminal.app/','/dev/example','false'],extra={'FOCUS_RESULT':result})
            self.assertEqual(p.stdout,'');self.assertEqual(p.stderr,'')
            p=self.run_command(['zsh',self.public/'repo_term.zsh','restore','/Applications/Terminal.app/','/dev/example','true'],extra={'FOCUS_RESULT':result})
            self.assertIn('Terminal restored',p.stderr)
        p=self.run_command(['zsh',self.public/'repo_term.zsh','restore','/Applications/Terminal.app/','','false'],extra={'FOCUS_RESULT':'ACTIVE_ONLY'})
        self.assertIn('Warning:',p.stderr)
        self.conf('USE_GHQ=false')
        root=Path(self.values()['PROJECTS_DIR'])
        for engine in ('zsh','perl','python'):
            p=self.repo(engine,'focus-'+engine,ok=False,extra={'FOCUS_FAIL':'1'})
            self.assertIn('Simulated activation failure',p.stderr)
            self.assertEqual(p.stdout.strip(),str(root/('focus-'+engine)))
            self.assertTrue((root/('focus-'+engine)/'.git').is_dir())

    def test_installer_rejects_unknown_options_without_side_effects(self):
        p=self.run_command(['zsh',HERE/'repo_install.zsh','--unexpected'],ok=False)
        self.assertEqual(p.returncode,2)
        self.assertFalse((self.home/'.repo-backups').exists())


    def test_all_script_versions_are_read_only(self):
        scripts = {
            'repo_conf.zsh': 'zsh', 'repo_install.zsh': 'zsh',
            'repo_shell.zsh': 'zsh', 'repo_term.zsh': 'zsh',
            'repo.zsh': 'zsh', 'repo.pl': 'perl', 'repo.py': 'python3',
            'test_repo_config.py': 'python3', 'test_repo_local.py': 'python3',
        }
        for name, runtime in scripts.items():
            with self.subTest(script=name):
                result = self.run_command([runtime, HERE/name, '--version'])
                self.assertEqual(result.stdout.strip(), name + ' 1.7a')
                self.assertEqual(result.stderr, '')
                self.assertIn('# Version: 1.7a', (HERE/name).read_text())
                result = self.run_command([HERE/name, '--version'])
                self.assertEqual(result.stdout.strip(), name + ' 1.7a')
        self.assertFalse((self.actual/'rep.conf').exists())
        self.assertFalse((self.home/'.zshrc').exists())
        self.assertEqual(self.calls(), [])

    def test_sourcing_shell_with_version_argument_does_not_exit(self):
        result = self.run_command([
            'zsh', '-c', 'source "$1" --version; print -r -- alive; repo --version',
            'test', HERE/'repo_shell.zsh',
        ])
        self.assertEqual(result.stdout.splitlines(), ['alive', 'repo 1.7a'])
        self.assertFalse((self.actual/'rep.conf').exists())

    def test_legacy_source_migration_and_numbered_dotfiles_backup(self):
        self.conf('OPEN_WEB=false')
        startup = self.home/'Projects/Dotfiles/.zshrc'
        startup.parent.mkdir()
        original = ('# User settings\n'
                    'source "$HOME/Other/shell.zsh"\n'
                    'source "$HOME/Repo/shell.zsh"\n')
        startup.write_text(original)
        (self.home/'.zshrc').symlink_to(startup)
        other = self.home/'Other'; other.mkdir()
        foreign = other/'shell.zsh'; foreign.write_text('# Another project\n')
        (self.public/'shell.zsh').symlink_to(foreign)
        from datetime import datetime
        base = self.home/('.zshrc.'+datetime.now().strftime('%Y%m%d'))
        base.write_text('Existing zero')
        base.with_name(base.name+'.1').write_text('Existing one')
        self.run_command(['zsh', HERE/'repo_install.zsh'])
        self.assertEqual(base.read_text(), 'Existing zero')
        self.assertEqual(base.with_name(base.name+'.1').read_text(), 'Existing one')
        self.assertEqual(base.with_name(base.name+'.2').read_text(), original)
        updated = startup.read_text()
        self.assertIn('source "$HOME/Other/shell.zsh"', updated)
        self.assertNotIn('source "$HOME/Repo/shell.zsh"', updated)
        self.assertIn('source "$HOME/Repo/repo_shell.zsh"', updated)
        self.assertEqual(foreign.read_text(), '# Another project\n')
        self.assertTrue((self.public/'shell.zsh').is_symlink())
        for name in ('repo_install.zsh','repo_shell.zsh','repo_term.zsh'):
            self.assertTrue((self.public/name).is_symlink())
            self.assertEqual((self.public/name).resolve(), (self.actual/name).resolve())
        self.run_command(['zsh', HERE/'repo_install.zsh'])
        self.assertFalse(base.with_name(base.name+'.3').exists())

    def test_equivalent_dotfiles_alias_retains_startup_link(self):
        self.conf('OPEN_WEB=false')
        startup = self.home/'Projects/Dotfiles/.zshrc'
        startup.parent.mkdir()
        startup.write_text('source "$HOME/Projects/Repo/shell.zsh"\n')
        alias = self.home/'Projects/dotfiles'
        if not alias.exists():
            alias.symlink_to(startup.parent, target_is_directory=True)
        original_link = alias/'.zshrc'
        (self.home/'.zshrc').symlink_to(original_link)
        self.run_command(['zsh', HERE/'repo_install.zsh'])
        self.assertEqual((self.home/'.zshrc').readlink(), original_link)
        self.assertTrue((self.home/'.zshrc').samefile(startup))
        self.assertIn('source "$HOME/Repo/repo_shell.zsh"', startup.read_text())

    def test_unrelated_startup_link_is_not_retargeted(self):
        foreign = self.home/'foreign.zshrc'; foreign.write_text('# Keep this file\n')
        (self.home/'.zshrc').symlink_to(foreign)
        before = {p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()}
        self.run_command(['zsh', HERE/'repo_install.zsh'], ok=False)
        self.assertEqual(foreign.read_text(), '# Keep this file\n')
        self.assertEqual((self.home/'.zshrc').resolve(), foreign)
        self.assertEqual({p.name:p.read_bytes() for p in self.actual.iterdir() if p.is_file()}, before)


    def test_separate_hard_link_is_not_accepted_as_startup_target(self):
        startup = self.home/'Projects/Dotfiles/.zshrc'
        startup.parent.mkdir()
        startup.write_text('# Preserve both entries\n')
        foreign = self.home/'foreign.zshrc'
        os.link(startup, foreign)
        (self.home/'.zshrc').symlink_to(foreign)
        self.run_command(['zsh', HERE/'repo_install.zsh'], ok=False)
        self.assertEqual(startup.read_text(), '# Preserve both entries\n')
        self.assertEqual(foreign.read_text(), '# Preserve both entries\n')
        self.assertEqual((self.home/'.zshrc').resolve(), foreign)


if __name__ == '__main__':
    if '--version' in sys.argv[1:]:
        print(f'test_repo_config.py {SCRIPT_VERSION}')
    else:
        unittest.main()
