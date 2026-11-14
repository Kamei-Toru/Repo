#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Spec;
use File::Path qw(make_path);
use File::Find;
use File::Temp qw(tempfile);
$ENV{GH_HOST} = 'github.com';

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
    my ($code, $out, $err) = run('ghq', 'list', '--full-path');
    if (!$code) { push @paths, split /\n/, $out; }
    elsif ($code != 127) { die $err || "ghq list failed.\n"; }
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
    git($p, 'fetch', $r, '--prune');
    die "Working tree has changes; synchronize manually: $p\n" if length git($p, 'status', '--porcelain');
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
            for my $r (split /\n/, git($dest, 'remote')) {
                my $url = git($dest, 'config', '--get', "remote.$r.url");
                die "Conflicting remote $r: $url\n" unless remote_id($url) eq lc $full;
            }
        } else {
            my ($inside) = attempt($dest, 'rev-parse', '--show-toplevel');
            die "Destination is inside another repository: $dest\n" unless $inside;
            die "Nonempty unlinked directory: $dest\n" if !$new && nonempty($dest);
        }
    }
    cmd('gh', 'repo', 'create', $full, '--private') if $new;
    my ($web) = run('gh', 'repo', 'view', $full, '--web');
    print STDERR "Open https://github.com/$full\n" if $web;
    if (!-e $dest || (!isroot($dest) && !nonempty($dest))) {
        cmd('gh', 'repo', 'clone', $full, $dest);
    } else {
        git($dest, 'init', '-b', 'main') unless isroot($dest);
        my ($missing) = attempt($dest, 'config', '--get', "remote.$remote.url");
        git($dest, 'remote', 'add', $remote, "https://github.com/$full.git") if $missing;
        if ($new) {
            git($dest, 'add', '--all');
            my ($diff, undef, $error) = attempt($dest, 'diff', '--cached', '--quiet');
            die $error if $diff > 1;
            git($dest, 'commit', '-m', 'Import existing files') if $diff == 1;
            my ($nohead) = attempt($dest, 'rev-parse', '--verify', 'HEAD');
            git($dest, 'push', '--set-upstream', $remote, 'HEAD') unless $nohead;
        } else { sync_repo($dest, $remote); }
    }
    print STDERR "Ready: $dest\n";
    return abs_path($dest);
}
sub main {
    if (grep { $_ eq '-h' || $_ eq '--help' || $_ eq "\x{2014}help" || $_ eq "\xE2\x80\x94help" } @ARGV) {
        print <<'HELP';
Usage: repo.pl [--] [NAME ...]
Prepare private GitHub repositories for the authenticated user.
Prompt for missing/invalid names and open every repository in the browser.
Reuse linked repositories under Projects, ghq roots, or the current directory.
Otherwise clone to ~/Projects/NAME. Import existing files into new remotes.
Existing remotes: fetch and fast-forward only with a clean working tree.
Use shell.zsh to change the caller's directory. R_PROJECTS overrides ~/Projects.
Names: 1-100 ASCII letters, digits, dots, underscores, hyphens; not ., .., or names ending in .git.
Dependencies: git, gh, Perl core modules. Optional fuzzy navigation: ghq and fzf.
-h, --help  Show this help.
HELP
        return 0;
    }
    shift @ARGV if @ARGV && $ARGV[0] eq '--';
    my @names = map { read_name($_) } (@ARGV ? @ARGV : ('') );
    cmd('git', '--version'); cmd('gh', 'auth', 'status', '--hostname', 'github.com');
    my $owner = cmd('gh', 'api', 'user', '--jq', '.login');
    my $root = $ENV{R_PROJECTS} // "$ENV{HOME}/Projects";
    $root =~ s{\A~/}{$ENV{HOME}/};
    make_path($root); $root = abs_path($root);
    my ($first, $failed) = ('', 0);
    for my $i (0..$#names) {
        eval { my $p = prepare($root, $owner, $names[$i]); $first = $p if $i == 0; 1 }
            or do { print STDERR "Error [$names[$i]]: $@"; $failed = 1; };
    }
    print "$first\n" if length $first;
    return $failed;
}
my $status;
eval { $status = main(); 1 } or do { print STDERR "Error: $@"; $status = 1; };
exit $status;
