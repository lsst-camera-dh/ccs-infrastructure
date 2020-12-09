# -*- mode: sh -*-
# bash completion for ccslog

_ccslogcompfunc () {
    local cur
    COMPREPLY=()                  # array of possible completions
    cur=${COMP_WORDS[COMP_CWORD]} # current word being completed

    case $cur in
        -*)
            # shellcheck disable=SC2207
            COMPREPLY=( $( compgen -W "-t -p -h --" -- "$cur" ) ) ;;
        *)
            # shellcheck disable=SC2064
            trap "$(shopt -p nullglob extglob)" RETURN
            shopt -s nullglob extglob
            local f words
            ## TODO can we make ccslog itself return these?
            for f in /var/log/ccs/ccs-logs-*.log?(.+([0-9.])); do
                f=${f##*ccs-logs-}
                f=${f%%*([0-9-]).log*}
                case $words in
                    "$f"|*\ "$f"|"$f"\ *|*\ "$f"\ *) continue ;;
                    *) words="$words $f" ;;
                esac
            done
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -W "$words" -- "$cur"))
            ;;

    esac
    return 0
}

complete -F _ccslogcompfunc ccslog
