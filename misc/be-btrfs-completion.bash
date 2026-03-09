# be-btrfs — bash tab-completion
# Completes commands, flags, BE names, snapshot names, and directories.
#
# Install:
#   cp be-btrfs-completion.bash /etc/bash_completion.d/be-btrfs

_be_btrfs_list_bes() {
    local bes
    bes=$(be-btrfs list -H 2>/dev/null | cut -d';' -f1)
    echo "$bes"
}

_be_btrfs_list_snaps() {
    local snaps
    snaps=$(be-btrfs list -sH 2>/dev/null | awk -F';' '/^@/{print $1}')
    echo "$snaps"
}

_be_btrfs() {
    local cur prev cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="create destroy list mount unmount rename activate
        snapshot clone shell upgrade prune rescue check status
        apt-hook-install help version"

    # Find the subcommand
    cmd=""
    for (( i=1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            -*) continue ;;
            *)  cmd="${COMP_WORDS[i]}"; break ;;
        esac
    done

    # Complete command name
    if [[ -z "$cmd" ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
    fi

    # Complete flags and arguments per command
    case "$cmd" in
        create)
            case "$prev" in
                -d) return ;;  # description, free text
                -e) COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes) $(_be_btrfs_list_snaps)" -- "$cur") ) ;;
                *)  COMPREPLY=( $(compgen -W "-a -d -e" -- "$cur") ) ;;
            esac
            ;;
        destroy|rm)
            case "$cur" in
                -*)  COMPREPLY=( $(compgen -W "-f -F" -- "$cur") ) ;;
                *)   COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes)" -- "$cur") ) ;;
            esac
            ;;
        list|ls)
            COMPREPLY=( $(compgen -W "-a -d -s -H" -- "$cur") )
            ;;
        activate|shell|sh)
            COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes)" -- "$cur") )
            ;;
        mount)
            # First arg: BE name, second: directory
            local nargs=0
            for (( i=1; i < COMP_CWORD; i++ )); do
                [[ "${COMP_WORDS[i]}" == "$cmd" ]] && continue
                [[ "${COMP_WORDS[i]}" == -* ]] && continue
                (( nargs++ ))
            done
            if (( nargs == 0 )); then
                COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes)" -- "$cur") )
            else
                COMPREPLY=( $(compgen -d -- "$cur") )
            fi
            ;;
        unmount|umount)
            case "$cur" in
                -*)  COMPREPLY=( $(compgen -W "-f" -- "$cur") ) ;;
                *)   COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes)" -- "$cur") ) ;;
            esac
            ;;
        rename)
            COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes)" -- "$cur") )
            ;;
        clone)
            COMPREPLY=( $(compgen -W "$(_be_btrfs_list_bes) $(_be_btrfs_list_snaps)" -- "$cur") )
            ;;
        upgrade)
            case "$prev" in
                -d) return ;;
                *)  COMPREPLY=( $(compgen -W "-d" -- "$cur") ) ;;
            esac
            ;;
        rescue)
            COMPREPLY=( $(compgen -d -- "$cur") )
            ;;
        prune|check|status|apt-hook-install|help|version)
            ;;
    esac
}

complete -F _be_btrfs be-btrfs
