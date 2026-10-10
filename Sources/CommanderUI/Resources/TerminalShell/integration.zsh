# Directory requests travel outside stdin and are only applied by the shell.
# While a foreground job runs, the newest request waits for the next prompt.
typeset -g _commander_mailbox=$COMMANDER_DIRECTORY_MAILBOX
typeset -g _commander_last_request=''
exec {_commander_notify}<>"$_commander_mailbox/notify"

_commander_apply_directory() {
    emulate -L zsh
    local request destination
    {
        IFS= read -r -d '' request && IFS= read -r -d '' destination
    } < "$_commander_mailbox/directory" || return
    [[ $request == $_commander_last_request ]] && return
    _commander_last_request=$request
    builtin cd -- "$destination"
}
_commander_directory_ready() {
    emulate -L zsh
    local notification
    while IFS= read -r -t 0 -u $_commander_notify notification; do :; done
    _commander_apply_directory
    # Preserve the current command buffer and redraw the prompt in its new cwd.
    zle reset-prompt
}
_commander_precmd() {
    _commander_apply_directory
    printf '\e]133;A\a'
}
_commander_preexec() { printf '\e]133;C\a'; }
zle -F $_commander_notify _commander_directory_ready
autoload -Uz add-zsh-hook
add-zsh-hook precmd _commander_precmd
add-zsh-hook preexec _commander_preexec
