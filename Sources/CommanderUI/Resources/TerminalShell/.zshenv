# Restore the user's startup directory before loading their normal configuration.
if [[ -n ${COMMANDER_ORIGINAL_ZDOTDIR+x} ]]; then
    ZDOTDIR=$COMMANDER_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi
[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source -- "${ZDOTDIR:-$HOME}/.zshenv"
if [[ -o interactive ]]; then
    _commander_initialize() {
        precmd_functions=(${precmd_functions:#_commander_initialize})
        builtin source -- "$COMMANDER_SHELL_RESOURCES/integration.zsh"
        _commander_precmd
        unfunction _commander_initialize
    }
    typeset -ga precmd_functions
    precmd_functions+=(_commander_initialize)
fi
