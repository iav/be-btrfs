# be-btrfs — fish tab-completion
# Completes commands, flags, BE names, snapshot names, and directories.
#
# Install (per-user):
#   cp be-btrfs.fish ~/.config/fish/completions/be-btrfs.fish
# Install (system-wide):
#   cp be-btrfs.fish /etc/fish/completions/be-btrfs.fish

function __be_btrfs_bes
    be-btrfs list -H 2>/dev/null | string split ';' -f1
end

function __be_btrfs_snaps
    be-btrfs list -sH 2>/dev/null | string match -r '^@.*' | string split ';' -f1
end

function __be_btrfs_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __be_btrfs_using_command
    set -l cmd (commandline -opc)
    test (count $cmd) -gt 1; and test $cmd[2] = $argv[1]
end

# Commands
complete -c be-btrfs -n __be_btrfs_needs_command -f -a create    -d 'Create BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a destroy   -d 'Delete BE or snapshot'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a list      -d 'List BEs'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a mount     -d 'Mount a BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a unmount   -d 'Unmount a BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a rename    -d 'Rename a BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a activate  -d 'Activate BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a snapshot  -d 'Snapshot current system'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a clone     -d 'Clone from snapshot'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a shell     -d 'Chroot into BE'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a upgrade   -d 'Clone + upgrade + activate'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a prune     -d 'Cleanup by rules'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a rescue    -d 'Activate from rescue'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a check     -d 'Check compatibility'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a status    -d 'Current state'
complete -c be-btrfs -n __be_btrfs_needs_command -f -a apt-hook-install -d 'Install APT hook'

# create flags
complete -c be-btrfs -n '__be_btrfs_using_command create' -s a -d 'Activate immediately'
complete -c be-btrfs -n '__be_btrfs_using_command create' -s d -r -d 'Description'
complete -c be-btrfs -n '__be_btrfs_using_command create' -s e -r -f -a '(__be_btrfs_bes) (__be_btrfs_snaps)' -d 'Source'

# destroy flags + BE names
complete -c be-btrfs -n '__be_btrfs_using_command destroy' -s f -d 'Force unmount'
complete -c be-btrfs -n '__be_btrfs_using_command destroy' -s F -d 'No confirmation'
complete -c be-btrfs -n '__be_btrfs_using_command destroy' -f -a '(__be_btrfs_bes)' -d 'BE'

# list flags
complete -c be-btrfs -n '__be_btrfs_using_command list' -s a -d 'Show all'
complete -c be-btrfs -n '__be_btrfs_using_command list' -s d -d 'Show nested subvolumes'
complete -c be-btrfs -n '__be_btrfs_using_command list' -s s -d 'Show snapshots'
complete -c be-btrfs -n '__be_btrfs_using_command list' -s H -d 'Machine-parseable'

# Commands that take BE name
complete -c be-btrfs -n '__be_btrfs_using_command activate' -f -a '(__be_btrfs_bes)' -d 'BE'
complete -c be-btrfs -n '__be_btrfs_using_command shell'    -f -a '(__be_btrfs_bes)' -d 'BE'
complete -c be-btrfs -n '__be_btrfs_using_command mount'    -f -a '(__be_btrfs_bes)' -d 'BE'
complete -c be-btrfs -n '__be_btrfs_using_command rename'   -f -a '(__be_btrfs_bes)' -d 'BE'

# unmount flags + BE names
complete -c be-btrfs -n '__be_btrfs_using_command unmount' -s f -d 'Force unmount'
complete -c be-btrfs -n '__be_btrfs_using_command unmount' -f -a '(__be_btrfs_bes)' -d 'BE'

# clone: source names
complete -c be-btrfs -n '__be_btrfs_using_command clone' -f -a '(__be_btrfs_bes) (__be_btrfs_snaps)' -d 'Source'

# upgrade flags
complete -c be-btrfs -n '__be_btrfs_using_command upgrade' -s d -r -d 'Description'

# rescue: directory
complete -c be-btrfs -n '__be_btrfs_using_command rescue' -F -d 'Mountpoint'
