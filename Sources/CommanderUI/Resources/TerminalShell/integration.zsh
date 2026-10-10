# The shell owns input state. The host never reconstructs it from keystrokes.
typeset -g _commander_mailbox=$COMMANDER_DIRECTORY_MAILBOX
typeset -g _commander_last_request='' _commander_last_input='' _commander_mode='full'
typeset -g _commander_saved_prompt=$PROMPT _commander_saved_rprompt=$RPROMPT
typeset -gi _commander_sequence=0
exec {_commander_notify}<>"$_commander_mailbox/notify"
exec {_commander_events}<>"$_commander_mailbox/events"
exec {_commander_responses}<>"$_commander_mailbox/responses"

_commander_event() { builtin print -r -- "$*" >&$_commander_events; }
_commander_update_prompt() {
    emulate -L zsh
    local mode=$(<"$_commander_mailbox/mode")
    if [[ $mode != $_commander_mode ]]; then
        if [[ $mode == compact ]]; then
            _commander_saved_prompt=$PROMPT
            _commander_saved_rprompt=$RPROMPT
            PROMPT='%~ %# '
            RPROMPT=''
        else
            PROMPT=$_commander_saved_prompt
            RPROMPT=$_commander_saved_rprompt
        fi
        _commander_mode=$mode
    fi
    # End the prompt on every redraw, including SIGWINCH and reset-prompt.
    # Without OSC 133 B, Ghostty waits for its prompt redraw timeout.
    local prompt_end=$'%{\e]133;B\a%}'
    [[ $PROMPT == *"$prompt_end" ]] || PROMPT+=$prompt_end
}
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
    _commander_update_prompt
    zle reset-prompt
}
_commander_redraw() {
    emulate -L zsh
    local present=0
    [[ -n $BUFFER || $CONTEXT != start ]] && present=1
    local state="$present ${BUFFERLINES:-1}"
    if [[ $state != $_commander_last_input ]]; then
        _commander_last_input=$state
        _commander_event "input $state"
    fi
}
_commander_accept_line() {
    emulate -L zsh
    local mode=$(<"$_commander_mailbox/mode")
    if [[ $mode == compact ]]; then
        if [[ -z ${BUFFER//[[:space:]]/} && $CONTEXT == start ]]; then
            BUFFER=''
            _commander_event open
            zle redisplay
            return
        fi
        # This runs in ZLE after all preceding keystrokes, so there is no race
        # between a delayed input-state notification and pressing Enter.
        local token="$$-$((++_commander_sequence))" response
        _commander_event "execute $token"
        # Do not execute into a one-row PTY if the host is unavailable.
        while IFS= read -r -t 2 -u $_commander_responses response; do
            if [[ $response == $token ]]; then
                _commander_update_prompt
                zle .accept-line
                return
            fi
        done
        zle -M 'Commander did not acknowledge terminal expansion; press Enter to retry'
        return
    fi
    zle .accept-line
}
_commander_precmd() {
    local exit_status=$?
    _commander_apply_directory
    _commander_update_prompt
    printf '\e]133;D;%s\a\e]133;A\a' "$exit_status"
    _commander_event "prompt $exit_status"
    _commander_last_input=''
}
_commander_preexec() {
    printf '\e]133;C\a'
    _commander_event running
}
zle -F $_commander_notify _commander_directory_ready
zle -N accept-line _commander_accept_line
autoload -Uz add-zsh-hook add-zle-hook-widget
add-zle-hook-widget line-pre-redraw _commander_redraw
add-zle-hook-widget line-init _commander_redraw
add-zsh-hook precmd _commander_precmd
add-zsh-hook preexec _commander_preexec
