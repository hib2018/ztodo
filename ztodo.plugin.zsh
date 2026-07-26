# Optional Zsh integration entry point for plugin managers.
typeset -gU fpath
fpath=("${${(%):-%x}:A:h}/extras/zsh/completions" $fpath)

# Register immediately when completion has already been initialized.
if (( $+functions[compdef] )); then
  autoload -Uz _ztodo
  compdef _ztodo ztodo
fi
