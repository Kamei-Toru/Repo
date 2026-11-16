#!/usr/bin/env perl
# Version: 1.6
# This script was generated using GitHub.
use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Find;
use File::Temp qw(tempfile);
$ENV{GH_HOST} = 'github.com';
my %CONFIG;
my $terminal_failed = 0;

# Capture commands using temporary files to avoid pipe-buffer deadlocks.
sub run {
    my @args = @_;
    my ($out, $op) = tempfile(UNLINK => 1);
    my ($err, $ep) = tempfile(UNLINK => 1);
    my $pid = fork();
    die "Cannot fork: $!\n" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>&', $out or die "Cannot redirect stdout: $!\n";
        open STDERR, '>&', $err or die "Cannot redirect stderr: $!\n";
        exec { $args[0] } @args;
        exit 127;
    }
    waitpid($pid, 0);
    my $status = $?;
    seek $out, 0, 0; seek $err, 0, 0;
    local $/;
    my $o = <$out> // ''; my $e = <$err> // '';
    return ($status == -1 ? 127 : $status & 127 ? 128 + ($status & 127) : $status >> 8, $o, $e);
}
sub cmd {
    my @args = @_;
    my ($code, $out, $err) = run(@args);
    die($err || $out || "Command failed: $args[0]\n") if $code;
    $out =~ s/\r?\n\z//;
    return $out;
}
sub load_config {
    my $manager = ($ENV{R_HOME} // "$ENV{HOME}/Repo") . '/conf.zsh';
    die "Missing configuration manager: $manager. Run install.zsh.\n" unless -f $manager;
    my $data = cmd('zsh', $manager, '--env');
    my %settings;
    for my $line (split /\n/, $data) {
        my ($key, $value) = split /=/, $line, 2;
        $settings{$key} = $value;
    }
    return %settings;
}
sub git { my $p = shift; return cmd('git', '-C', $p, @_); }
sub attempt { my $p = shift; return run('git', '-C', $p, @_); }
sub isroot {
    my ($p) = @_;
    return 0 unless -d $p;
    my ($code, $top) = attempt($p, 'rev-parse', '--show-toplevel');
    chomp $top;
    return !$code && abs_path($top) eq abs_path($p);
}
sub remote_id {
    my ($url) = @_;
    return '' unless $url =~ m{\A(?:https?://github\.com/|ssh://git\@github\.com/|git\@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?\z};
    return lc $1;
}
sub valid { return $_[0] =~ /\A[A-Za-z0-9_.-]{1,100}\z/ && $_[0] ne '.' && $_[0] ne '..' && $_[0] !~ /\.git\z/i; }
sub read_name {
    my ($n) = @_;
    while (!valid($n)) {
        print STDERR "Invalid repository name: '$n'\n" if length $n;
        print STDERR 'Repository name: ';
        $n = <STDIN>;
        die "Input ended before a valid name was provided.\n" unless defined $n;
        $n =~ s/[\r\n]+\z//;
    }
    return $n;
}
sub nonempty {
    opendir my $dh, $_[0] or die "Cannot read directory: $!\n";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    return scalar @entries;
}
sub candidates {
    my ($root) = @_;
    my @paths = (getcwd());
    if ($CONFIG{USE_GHQ} eq 'true') {
    my ($code, $out, $err) = run('ghq', 'list', '--full-path');
    if (!$code) { push @paths, split /\n/, $out; }
    elsif ($code != 127) { die $err || "ghq list failed.\n"; }
    }
    find({no_chdir => 1, wanted => sub {
        return unless -d $_;
        my $p = $File::Find::name;
        if (-e "$p/.git") { push @paths, $p; $File::Find::prune = 1; }
        elsif ($p =~ m{/(?:node_modules|\.cache|\.Trash)\z}) { $File::Find::prune = 1; }
    }}, $root);
    return @paths;
}
sub sync_repo {
    my ($p, $r) = @_;
    if (length git($p, 'status', '--porcelain')) {
        die bless { path => abs_path($p), message => "Working tree has changes; synchronization skipped: $p\n" }, 'RepoDirty';
    }
    git($p, 'fetch', $r, '--prune');
    my $branch = git($p, 'symbolic-ref', '--quiet', '--short', 'HEAD');
    my $refs = git($p, 'for-each-ref', '--format=%(refname)', "refs/remotes/$r/");
    return unless length $refs;
    my $target = "refs/remotes/$r/$branch";
    die "No matching remote branch: $branch\n" unless grep { $_ eq $target } split /\n/, $refs;
    my ($code) = attempt($p, 'rev-parse', '--verify', 'HEAD');
    if (!$code) { git($p, 'merge', '--ff-only', $target); }
    else { git($p, 'checkout', '-B', $branch, $target); }
    git($p, 'branch', "--set-upstream-to=$r/$branch", $branch);
    my $ahead = git($p, 'rev-list', '--count', "$target..HEAD");
    print STDERR "Local commits ahead ($ahead); push manually: $p\n" if $ahead ne '0';
}
sub open_web {
    my ($full) = @_;
    return unless $CONFIG{OPEN_WEB} eq 'true';
    my $restore = $CONFIG{RETURN_TERMINAL} eq 'true' && ($ENV{R_DEFER_FOCUS} // '') ne '1';
    my $helper = ($ENV{R_HOME} // "$ENV{HOME}/Repo") . '/term.zsh';
    my $app = $ENV{R_RETURN_APP} // '';
    if ($restore && !length $app) {
        my ($code, $out) = run('zsh', $helper, 'capture');
        chomp $out;
        $app = $code ? '' : $out;
    }
    my ($web) = run('gh', 'repo', 'view', $full, '--web');
    print STDERR "Open https://github.com/$full\n" if $web;
    if ($restore) {
        if (!length $app) {
            print STDERR "Could not identify the invoking terminal; focus return was not attempted.\n";
            $terminal_failed = 1;
            return;
        }
        my $caller_tty = $ENV{R_CALLER_TTY} // '';
        if (!length $caller_tty) {
            my ($no_tty, $detected) = run('tty');
            chomp $detected;
            $caller_tty = $detected unless $no_tty;
        }
        my ($code, undef, $error) = run('zsh', $helper, 'restore', $app, $caller_tty,
                                      $ENV{R_FOCUS_DEBUG} // $CONFIG{FOCUS_DEBUG});
        print STDERR $error if length $error;
        $terminal_failed = 1 if $code;
    }
}
sub validate_remotes {
    my ($path, $full) = @_;
    for my $remote (split /\n/, git($path, 'remote')) {
        for my $field ('url', 'pushurl') {
            my ($code, $out) = attempt($path, 'config', '--get-all', "remote.$remote.$field");
            next if $code == 1 && $field eq 'pushurl';
            die "Cannot read remote $field for $remote: $path\n" if $code;
            my @urls = split /\n/, $out;
            die "Conflicting remote $field for $remote: $path\n" unless @urls;
            for my $url (@urls) {
                die "Conflicting remote $field for $remote: $path\n" unless remote_id($url) eq lc $full;
            }
        }
    }
}
sub prepare {
    my ($root, $owner, $name) = @_;
    my $full = "$owner/$name";
    my ($code, $out, $err) = run('gh', 'api', "repos/$full", '--jq', '.full_name');
    my $new = $code != 0;
    die($err || "GitHub lookup failed.\n") if $new && $err !~ /\(HTTP 404\)/;
    if (!$new) { chomp $out; $full = $out; }
    my $dest = "$root/$name"; my $remote = 'origin';
    FIND: for my $p ($dest, candidates($root)) {
        next unless isroot($p);
        for my $r (split /\n/, git($p, 'remote')) {
            if (remote_id(git($p, 'config', '--get', "remote.$r.url")) eq lc $full) {
                ($dest, $remote) = ($p, $r); last FIND;
            }
        }
    }
    die "Symbolic-link destination: $dest\n" if -l $dest;
    if (-e $dest) {
        die "Destination is not a directory: $dest\n" unless -d $dest;
        if (isroot($dest)) {
            validate_remotes($dest, $full);
        } else {
            my ($inside) = attempt($dest, 'rev-parse', '--show-toplevel');
            die "Destination is inside another repository: $dest\n" unless $inside;
            die "Nonempty unlinked directory: $dest\n" if !$new && nonempty($dest);
        }
    }
    cmd('gh', 'repo', 'create', $full, '--' . $CONFIG{VISIBILITY}) if $new;
    open_web($full);
    if (!-e $dest || (!isroot($dest) && !nonempty($dest))) {
        cmd('gh', 'repo', 'clone', $full, $dest);
    } else {
        git($dest, 'init', '-b', $CONFIG{DEFAULT_BRANCH}) unless isroot($dest);
        my ($missing) = attempt($dest, 'config', '--get', "remote.$remote.url");
        git($dest, 'remote', 'add', $remote, "https://github.com/$full.git") if $missing;
        if ($new && $CONFIG{IMPORT_EXISTING} eq 'true') {
            git($dest, 'add', '--all');
            my ($diff, undef, $error) = attempt($dest, 'diff', '--cached', '--quiet');
            die $error if $diff > 1;
            git($dest, 'commit', '-m', $CONFIG{COMMIT_MESSAGE}) if $diff == 1;
            my ($nohead) = attempt($dest, 'rev-parse', '--verify', 'HEAD');
            git($dest, 'push', '--set-upstream', $remote, 'HEAD') unless $nohead;
        } elsif (!$new && $CONFIG{SYNC_EXISTING} eq 'true') { sync_repo($dest, $remote); }
    }
    print STDERR "Ready: $dest\n";
    return abs_path($dest);
}
sub main {
    if (grep { $_ eq '-h' || $_ eq '--help' || $_ eq "\x{2014}help" || $_ eq "\xE2\x80\x94help" } @ARGV) {
        print <<'HELP';
repo - Prepare GitHub repositories for local development.
Settings: ~/Repo/rep.conf (created automatically when missing).

Usage: repo [NAME ...]

Examples:
  repo                 Prompt for a repository name.
  repo alpha beta      Prepare both; enter alpha via shell integration.

Arguments:
  NAME ...             Repository names; prompt if omitted or invalid.

Options:
  -h, --help           Show this help.

Exit status:
  0                    Success (including help).
  nonzero              Failure or cancellation.
HELP
        return 0;
    }
    %CONFIG = load_config();
    shift @ARGV if @ARGV && $ARGV[0] eq '--';
    my @names = map { read_name($_) } (@ARGV ? @ARGV : ('') );
    cmd('git', '--version'); cmd('gh', 'auth', 'status', '--hostname', 'github.com');
    my $owner = cmd('gh', 'api', 'user', '--jq', '.login');
    my $root = $ENV{R_PROJECTS} // $CONFIG{PROJECTS_DIR};
    $root =~ s{\A~/}{$ENV{HOME}/};
    make_path($root); $root = abs_path($root);
    my ($first, $failed) = ('', 0);
    for my $i (0..$#names) {
        eval { my $p = prepare($root, $owner, $names[$i]); $first = $p if $i == 0; 1 }
            or do {
                my $error = $@;
                if (ref($error) eq 'RepoDirty') {
                    $first = $error->{path} if $i == 0;
                    $error = $error->{message};
                }
                print STDERR "Error [$names[$i]]: $error";
                $failed = 1;
            };
    }
    print "$first\n" if length $first;
    return ($failed || $terminal_failed) ? 1 : 0;
}
my $status;
eval { $status = main(); 1 } or do { print STDERR "Error: $@"; $status = 1; };
exit $status;
