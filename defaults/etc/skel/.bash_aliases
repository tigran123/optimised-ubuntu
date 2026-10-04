# Read by ~/.bashrc, which also takes the ls colours from ~/.dircolors.

alias ls="/bin/ls -F --color=auto"
alias l="ls -l --color=auto"
alias ll="ls -al --color=auto"
alias md="mkdir -p"
alias rd="rmdir"
alias j="jobs -l"
alias u="uname -a"
alias up='uptime -p'
alias ups='uptime -s'
alias df="df -Th"
alias r="fc -s"
alias cls="tput clear"
alias dis="objdump --disassemble"
alias od="od -Ax -tx4z -w16"
alias m="free -m"
alias pbcopy="xclip -selection c"
alias pbpaste="xclip -selection clipboard -o"
alias t='tty-clock -bc -f "%a, %e %b %Y %z"'

export GREP_COLORS="ms=01;31:fn=1;33:ln=32:se=36"
