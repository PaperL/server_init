#!/usr/bin/env bash

set -euo pipefail

# Single-file server initializer per notes.md
# - Interactive with safe defaults
# - Installs zsh + powerlevel10k + plugins
# - Installs Miniconda and creates py12
# - Configures SSH authorized_keys, directories, and git
# - Embeds ~/.zshrc and ~/.p10k.zsh templates

# Globals
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LOG_FILE="${SCRIPT_DIR}/server_init.log"

# Initialize globals to satisfy `set -u` before detection
OS=""
ARCH=""
LINUX_ID=""

exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

run_quiet() {
  "$@" >>"$LOG_FILE" 2>&1
}

print_256_color_table_bash() {
  # Render a 256-color table using ANSI escape codes in bash
  local i
  for i in {0..255}; do
    printf "\e[48;5;%sm    \e[0m%3d " "$i" "$i"
    if (( (i + 1) % 6 == 0 )); then
      echo
    fi
  done
  echo
}

ask_yn() {
  local prompt_default="$1"; shift
  local message="$*"
  local default_char prompt
  case "$prompt_default" in
    Y|y) default_char=Y; prompt="[Y/n]" ;;
    N|n) default_char=N; prompt="[y/N]" ;;
    *) default_char=N; prompt="[y/N]" ;;
  esac
  while true; do
    read -r -p "$message $prompt " reply || reply=""
    reply=${reply:-$default_char}
    case "$reply" in
      Y|y|yes) return 0 ;;
      N|n|no)  return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    return 1
  fi
}

sudo_if_needed() {
  if [[ $EUID -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Run a command as a specific user across distros and with/without sudo.
run_as_user() {
  local target_user="$1"; shift
  if [[ -z "$target_user" ]]; then
    "$@"
    return
  fi
  if [[ $EUID -eq 0 ]]; then
    if command -v runuser &>/dev/null; then
      runuser -u "$target_user" -- "$@"
    elif command -v sudo &>/dev/null; then
      sudo -u "$target_user" "$@"
    elif command -v su &>/dev/null; then
      # Fallback: use su with a shell to preserve args safely
      local cmd
      cmd=$(printf '%q ' "$@")
      su -s /bin/bash - "$target_user" -c "$cmd"
    else
      warn "Cannot switch user to '$target_user'. Running as root."
      "$@"
    fi
  else
    local current_user
    current_user=$(id -un)
    if [[ "$current_user" == "$target_user" ]]; then
      "$@"
    elif command -v sudo &>/dev/null; then
      sudo -u "$target_user" "$@"
    else
      warn "Cannot switch user to '$target_user' without sudo; running as '$current_user'."
      "$@"
    fi
  fi
}

set_user_password() {
  local user="$1" pass1 pass2
  while true; do
    read -s -p "Enter password for '$user': " pass1; echo
    read -s -p "Confirm password: " pass2; echo
    if [[ -z "$pass1" ]]; then
      echo "Password cannot be empty."
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      echo "Passwords do not match. Try again."
      continue
    fi
    if require_cmd chpasswd; then
      # Do not echo the password to stdout; send directly to chpasswd
      echo "$user:$pass1" | sudo_if_needed chpasswd
    else
      warn "'chpasswd' not available; falling back to interactive passwd."
      sudo_if_needed passwd "$user" || err "Failed to set password for $user"
      return
    fi
    info "Password set for user '$user'."
    break
  done
}

detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  LINUX_ID=""
  if [[ "$OS" == "Linux" ]]; then
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      LINUX_ID=${ID:-}
    fi
  fi
}

apt_update_if_debian() {
  if [[ "${LINUX_ID:-}" =~ ^(debian|ubuntu)$ ]]; then
    run_quiet sudo_if_needed env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  fi
}

ensure_pkg() {
  local pkg="$1"
  if require_cmd apt-get; then
    if ! dpkg -s "$pkg" &>/dev/null; then
      run_quiet sudo_if_needed env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
    fi
  elif require_cmd yum; then
    run_quiet sudo_if_needed yum install -y -q "$pkg"
  elif require_cmd dnf; then
    run_quiet sudo_if_needed dnf install -y -q "$pkg"
  elif require_cmd pacman; then
    run_quiet sudo_if_needed pacman -S --noconfirm --quiet "$pkg"
  else
    warn "No known package manager to install $pkg. Skipping."
  fi
}

setup_hostname() {
  local current host
  current=$(hostname)
  if ask_yn N "Current hostname is '$current'. Change it?"; then
    read -r -p "Enter new hostname: " host
    if [[ -n "$host" ]]; then
      if require_cmd hostnamectl; then
        sudo_if_needed hostnamectl set-hostname "$host"
      else
        echo "$host" | sudo_if_needed tee /etc/hostname >/dev/null
        sudo_if_needed hostname "$host" || true
      fi
      # Update /etc/hosts mapping
      if [[ -w /etc/hosts || $EUID -eq 0 ]]; then
        sudo_if_needed sed -i.bak "/\s$current\s*$/d" /etc/hosts || true
        # Ensure localhost entries exist
        if ! grep -qE "^127.0.1.1\s+${host}(\s|$)" /etc/hosts 2>/dev/null; then
          echo "127.0.1.1   ${host}" | sudo_if_needed tee -a /etc/hosts >/dev/null
        fi
      fi
      info "Hostname updated to '$host'."
    else
      warn "Empty hostname provided. Skipping change."
    fi
  fi
}

create_or_select_user() {
  local current_user new_user need_sudo is_new_account="no"
  current_user=$(id -un)
  if [[ "$current_user" == "root" ]]; then
    if ask_yn Y "You are root. Create a new user?"; then
      is_new_account="yes"
      if ask_yn Y "Should the new user have sudo privileges?"; then
        need_sudo="yes"
      else
        need_sudo="no"
      fi
      while true; do
        read -r -p "Enter new username: " new_user
        [[ -n "$new_user" ]] && break
        echo "Username cannot be empty."
      done
      if ! id -u "$new_user" &>/dev/null; then
        sudo_if_needed useradd -m -s /bin/bash "$new_user"
        set_user_password "$new_user"
        if [[ "$need_sudo" == "yes" ]]; then
          ensure_pkg sudo || true
          sudo_if_needed usermod -aG sudo "$new_user" || true
        fi
        info "Created user '$new_user' (sudo: ${need_sudo:-no})."
      else
        warn "User '$new_user' already exists."
      fi
      TARGET_USER="$new_user"
    else
      TARGET_USER="root"
    fi
  else
    if ask_yn Y "Continue with current user '$current_user'?"; then
      TARGET_USER="$current_user"
    else
      is_new_account="yes"
      if ask_yn Y "Create a new user?"; then
        if ask_yn Y "Should the new user have sudo privileges?"; then
          need_sudo="yes"
        else
          need_sudo="no"
        fi
        while true; do
          read -r -p "Enter new username: " new_user
          [[ -n "$new_user" ]] && break
          echo "Username cannot be empty."
        done
        if ! id -u "$new_user" &>/dev/null; then
          sudo_if_needed useradd -m -s /bin/bash "$new_user"
          set_user_password "$new_user"
          if [[ "$need_sudo" == "yes" ]]; then
            ensure_pkg sudo || true
            sudo_if_needed usermod -aG sudo "$new_user" || true
          fi
          info "Created user '$new_user' (sudo: ${need_sudo:-no})."
        else
          warn "User '$new_user' already exists."
        fi
        TARGET_USER="$new_user"
      else
        TARGET_USER="$current_user"
      fi
    fi
  fi
  TARGET_HOME=$(eval echo ~"$TARGET_USER")
  TARGET_IS_NEW="$is_new_account"
}

prepare_user_ssh_and_dirs() {
  local ssh_dir auth_file
  info "This step may modify files under $TARGET_HOME."
  ssh_dir="$TARGET_HOME/.ssh"
  auth_file="$ssh_dir/authorized_keys"
  if [[ ! -d "$ssh_dir" ]]; then
    sudo_if_needed install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$ssh_dir"
  fi
  if [[ ! -f "$auth_file" ]]; then
    sudo_if_needed install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" /dev/null "$auth_file"
  fi

  if [[ "$TARGET_IS_NEW" == "yes" ]]; then
    if ask_yn Y "Copy authorized_keys from root if available?"; then
      if [[ -f /root/.ssh/authorized_keys ]]; then
        sudo_if_needed cp /root/.ssh/authorized_keys "$auth_file"
        sudo_if_needed chown "$TARGET_USER:$TARGET_USER" "$auth_file"
        sudo_if_needed chmod 600 "$auth_file"
      else
        warn "Root authorized_keys not found."
      fi
    fi
  fi

  if ask_yn N "Append a new public key to $auth_file?"; then
    read -r -p "Paste the public key (single line): " pubkey
    if [[ -n "$pubkey" ]]; then
      printf "%s\n" "$pubkey" | sudo_if_needed tee -a "$auth_file" >/dev/null
      sudo_if_needed chown "$TARGET_USER:$TARGET_USER" "$auth_file"
      sudo_if_needed chmod 600 "$auth_file"
    fi
  fi

  # Create folders: toolchain, temp, workspace
  for d in toolchain temp workspace; do
    sudo_if_needed install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/$d"
  done

  # Optional apt upgrade
  if [[ "${LINUX_ID:-}" =~ ^(debian|ubuntu)$ ]]; then
    if ask_yn Y "Run apt update and upgrade now?"; then
      info "Running apt update..."
      run_quiet sudo_if_needed env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      info "Running apt upgrade..."
      run_quiet sudo_if_needed env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    fi
  fi
}

install_zsh_and_plugins() {
  info "Installing zsh and plugins..."
  if require_cmd apt-get; then
    apt_update_if_debian
  fi
  ensure_pkg git || true
  ensure_pkg zsh || true

  local zsh_base="$TARGET_HOME/.zsh"
  sudo_if_needed install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$zsh_base"
  if [[ ! -d "$zsh_base/powerlevel10k" ]]; then
    run_quiet run_as_user "$TARGET_USER" git clone --quiet --depth=1 https://github.com/romkatv/powerlevel10k.git "$zsh_base/powerlevel10k"
  fi
  if [[ ! -d "$zsh_base/zsh-autosuggestions" ]]; then
    run_quiet run_as_user "$TARGET_USER" git clone --quiet https://github.com/zsh-users/zsh-autosuggestions "$zsh_base/zsh-autosuggestions"
  fi
  if [[ ! -d "$zsh_base/zsh-syntax-highlighting" ]]; then
    run_quiet run_as_user "$TARGET_USER" git clone --quiet https://github.com/zsh-users/zsh-syntax-highlighting.git "$zsh_base/zsh-syntax-highlighting"
  fi

  # Write embedded configs
  write_embedded_zsh_configs

  # Set default shell
  if command -v zsh &>/dev/null; then
    if [[ "$TARGET_USER" != "root" ]]; then
      run_quiet sudo_if_needed chsh -s "$(command -v zsh)" "$TARGET_USER" || warn "Failed to change shell."
    else
      run_quiet sudo_if_needed chsh -s "$(command -v zsh)" || warn "Failed to change shell."
    fi
  fi
}

install_miniconda() {
  info "Installing Miniconda..."
  local url filename arch
  arch="$ARCH"
  case "$arch" in
    x86_64|amd64) url="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" ;;
    aarch64|arm64) url="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh" ;;
    *) warn "Unsupported arch '$arch' for Miniconda auto install. Skipping."; return ;;
  esac

  ensure_pkg wget || ensure_pkg curl || true
  filename="$TARGET_HOME/miniconda.sh"
  if require_cmd wget; then
    run_quiet run_as_user "$TARGET_USER" wget -q -O "$filename" "$url"
  elif require_cmd curl; then
    run_quiet run_as_user "$TARGET_USER" curl -fsSL -o "$filename" "$url"
  else
    err "Neither wget nor curl available. Cannot download Miniconda."; return
  fi
  sudo_if_needed chmod +x "$filename"
  # Non-interactive install to $TARGET_HOME/toolchain/miniconda3
  run_quiet run_as_user "$TARGET_USER" bash "$filename" -b -p "$TARGET_HOME/toolchain/miniconda3"
  # Configure and create env
  if [[ -x "$TARGET_HOME/toolchain/miniconda3/bin/conda" ]]; then
    run_quiet run_as_user "$TARGET_USER" bash -lc '"$HOME/toolchain/miniconda3/bin/conda" config --set auto_activate_base false && "$HOME/toolchain/miniconda3/bin/conda" create -y -n py12 python=3.12'
  fi
}

choose_p10k_color() {
  if ask_yn Y "Customize Powerlevel10k OS icon color now?"; then
    # Show color table using bash ANSI 256-color codes
    print_256_color_table_bash
    read -r -p "Enter color id (0-255), default 38: " color
    color=${color:-38}
    local p10k_file="$TARGET_HOME/.p10k.zsh"
    if [[ -f "$p10k_file" ]]; then
      sudo_if_needed sed -i.bak "s/^\(\s*typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=\).*/\1${color}/" "$p10k_file"
      info "Updated OS icon color to $color in $p10k_file"
    else
      warn "$p10k_file not found."
    fi
  fi
}

setup_git() {
  local need_install=false
  if ! command -v git &>/dev/null; then
    if ask_yn Y "git not found. Install git?"; then
      if require_cmd apt-get; then
        apt_update_if_debian
      fi
      ensure_pkg git || true
    fi
  fi
  if ask_yn Y "Configure git user.name and user.email globally?"; then
    read -r -p "git user.name: " git_name
    read -r -p "git user.email: " git_email
    if [[ -n "$git_name" ]]; then
      run_quiet run_as_user "$TARGET_USER" git config --global user.name "$git_name"
    fi
    if [[ -n "$git_email" ]]; then
      run_quiet run_as_user "$TARGET_USER" git config --global user.email "$git_email"
    fi
  fi
}

write_embedded_zsh_configs() {
  local zshrc_path p10k_path
  zshrc_path="$TARGET_HOME/.zshrc"
  p10k_path="$TARGET_HOME/.p10k.zsh"
  # .zshrc
  sudo_if_needed install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" /dev/null "$zshrc_path"
  sudo_if_needed tee "$zshrc_path" >/dev/null <<'ZSHRC_EOF'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
# Set up the prompt
autoload -Uz promptinit
promptinit
prompt adam1
setopt histignorealldups sharehistory
# Use vi/vim keybindings
bindkey -v
# Keep 1000 lines of history within the shell and save it to ~/.zsh_history:
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history
# Use modern completion system
autoload -Uz compinit
compinit
zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select=2
eval "$(dircolors -b)"
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'
# enable zsh plugins
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
# change zsh theme
ZSH_HIGHLIGHT_STYLES[path]='fg=blue'
# launch powerlevel10k for zsh
source ~/.zsh/powerlevel10k/powerlevel10k.zsh-theme
# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
######## zsh initialization end ########
# conda initialization (managed by script)
if [ -f "$HOME/toolchain/miniconda3/etc/profile.d/conda.sh" ]; then
  . "$HOME/toolchain/miniconda3/etc/profile.d/conda.sh"
elif [ -x "$HOME/toolchain/miniconda3/bin/conda" ]; then
  __conda_setup="$( $HOME/toolchain/miniconda3/bin/conda shell.zsh hook 2> /dev/null)"
  if [ $? -eq 0 ]; then
      eval "$__conda_setup"
  else
      export PATH="$HOME/toolchain/miniconda3/bin:$PATH"
  fi
  unset __conda_setup
fi
conda activate py12
ZSHRC_EOF
  sudo_if_needed chown "$TARGET_USER:$TARGET_USER" "$zshrc_path"

  # .p10k.zsh
  sudo_if_needed install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" /dev/null "$p10k_path"
  sudo_if_needed tee "$p10k_path" >/dev/null <<'P10K_EOF'
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'
() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  autoload -Uz is-at-least && is-at-least 5.1 || return
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(background_jobs direnv asdf virtualenv anaconda pyenv goenv nodenv nvm nodeenv rust_version rbenv rvm fvm luaenv jenv plenv perlbrew phpenv scalaenv haskell_stack kubecontext terraform aws aws_eb_env azure gcloud google_app_cred toolbox nordvpn ranger nnn xplr vim_shell midnight_commander nix_shell todo timewarrior taskwarrior status command_execution_time time context newline)
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR='·'
  if [[ $POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR != ' ' ]]; then
    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=240
    typeset -g POWERLEVEL9K_EMPTY_LINE_LEFT_PROMPT_FIRST_SEGMENT_END_SYMBOL='%{%}'
    typeset -g POWERLEVEL9K_EMPTY_LINE_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL='%{%}'
  fi
  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR='\uE0B5'
  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR='\uE0B7'
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR='\uE0B4'
  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR='\uE0B6'
  typeset -g POWERLEVEL9K_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL='\uE0B4'
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL='\uE0B6'
  typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL='\uE0B6'
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_LAST_SEGMENT_END_SYMBOL='\uE0B4'
  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=38
  typeset -g POWERLEVEL9K_OS_ICON_BACKGROUND=234
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIVIS_CONTENT_EXPANSION='V'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIOWR_CONTENT_EXPANSION='▶'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OVERWRITE_STATE=true
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=25
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=117
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=250
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=3
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=false
  local anchor_files=(.bzr .citc .git .hg .node-version .python-version .go-version .ruby-version .lua-version .java-version .perl-version .php-version .tool-version .shorten_folder_marker .svn .terraform CVS Cargo.toml composer.json go.mod package.json stack.yaml)
  typeset -g POWERLEVEL9K_SHORTEN_FOLDER_MARKER="(${(j:|:)anchor_files})"
  typeset -g POWERLEVEL9K_DIR_TRUNCATE_BEFORE_MARKER=first
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=1
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS=40
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS_PCT=50
  typeset -g POWERLEVEL9K_DIR_HYPERLINK=false
  typeset -g POWERLEVEL9K_DIR_SHOW_WRITABLE=v3
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=2
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=172
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=6
  typeset -g POWERLEVEL9K_VCS_CONFLICTED_BACKGROUND=210
  typeset -g POWERLEVEL9K_VCS_LOADING_BACKGROUND=8
  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON='\uF126 '
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'
  function my_git_formatter() {
    emulate -L zsh
    if [[ -n $P9K_CONTENT ]]; then
      typeset -g my_git_format=$P9K_CONTENT
      return
    fi
    local       meta='%7F'
    local      clean='%0F'
    local   modified='%0F'
    local  untracked='%0F'
    local conflicted='%1F'
    local res
    if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
      local branch=${(V)VCS_STATUS_LOCAL_BRANCH}
      (( $#branch > 32 )) && branch[13,-13]="…"
      res+="${clean}${(g::)POWERLEVEL9K_VCS_BRANCH_ICON}${branch//\%/%%}"
    fi
    if [[ -n $VCS_STATUS_TAG
          && -z $VCS_STATUS_LOCAL_BRANCH  
        ]]; then
      local tag=${(V)VCS_STATUS_TAG}
      (( $#tag > 32 )) && tag[13,-13]="…"
      res+="${meta}#${clean}${tag//\%/%%}"
    fi
    [[ -z $VCS_STATUS_LOCAL_BRANCH && -z $VCS_STATUS_TAG ]] &&  
      res+="${meta}@${clean}${VCS_STATUS_COMMIT[1,8]}"
    if [[ -n ${VCS_STATUS_REMOTE_BRANCH:#$VCS_STATUS_LOCAL_BRANCH} ]]; then
      res+="${meta}:${clean}${(V)VCS_STATUS_REMOTE_BRANCH//\%/%%}"
    fi
    if [[ $VCS_STATUS_COMMIT_SUMMARY == (|*[^[:alnum:]])(wip|WIP)(|[^[:alnum:]]*) ]]; then
      res+=" ${modified}wip"
    fi
    (( VCS_STATUS_COMMITS_BEHIND )) && res+=" ${clean}⇣${VCS_STATUS_COMMITS_BEHIND}"
    (( VCS_STATUS_COMMITS_AHEAD && !VCS_STATUS_COMMITS_BEHIND )) && res+=" "
    (( VCS_STATUS_COMMITS_AHEAD  )) && res+="${clean}⇡${VCS_STATUS_COMMITS_AHEAD}"
    (( VCS_STATUS_PUSH_COMMITS_BEHIND )) && res+=" ${clean}⇠${VCS_STATUS_PUSH_COMMITS_BEHIND}"
    (( VCS_STATUS_PUSH_COMMITS_AHEAD && !VCS_STATUS_PUSH_COMMITS_BEHIND )) && res+=" "
    (( VCS_STATUS_PUSH_COMMITS_AHEAD  )) && res+="${clean}⇢${VCS_STATUS_PUSH_COMMITS_AHEAD}"
    (( VCS_STATUS_STASHES        )) && res+=" ${clean}*${VCS_STATUS_STASHES}"
    [[ -n $VCS_STATUS_ACTION     ]] && res+=" ${conflicted}${VCS_STATUS_ACTION}"
    (( VCS_STATUS_NUM_CONFLICTED )) && res+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"
    (( VCS_STATUS_NUM_STAGED     )) && res+=" ${modified}+${VCS_STATUS_NUM_STAGED}"
    (( VCS_STATUS_NUM_UNSTAGED   )) && res+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}"
    (( VCS_STATUS_NUM_UNTRACKED  )) && res+=" ${untracked}${(g::)POWERLEVEL9K_VCS_UNTRACKED_ICON}${VCS_STATUS_NUM_UNTRACKED}"
    (( VCS_STATUS_HAS_UNSTAGED == -1 )) && res+=" ${modified}─"
    typeset -g my_git_format=$res
  }
  functions -M my_git_formatter 2>/dev/null
  typeset -g POWERLEVEL9K_VCS_MAX_INDEX_SIZE_DIRTY=-1
  typeset -g POWERLEVEL9K_VCS_DISABLED_WORKDIR_PATTERN='~'
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_VCS_CONTENT_EXPANSION='${$((my_git_formatter()))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_{STAGED,UNSTAGED,UNTRACKED,CONFLICTED,COMMITS_AHEAD,COMMITS_BEHIND}_MAX_NUM=-1
  typeset -g POWERLEVEL9K_VCS_BACKENDS=(git)
  typeset -g POWERLEVEL9K_STATUS_EXTENDED_STATES=true
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_OK_VISUAL_IDENTIFIER_EXPANSION='✔'
  typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=2
  typeset -g POWERLEVEL9K_STATUS_OK_BACKGROUND=0
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_VISUAL_IDENTIFIER_EXPANSION='✔'
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=2
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_BACKGROUND=0
  typeset -g POWERLEVEL9K_STATUS_ERROR=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_VISUAL_IDENTIFIER_EXPANSION='✘'
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=3
  typeset -g POWERLEVEL9K_STATUS_ERROR_BACKGROUND=1
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL=true
  typeset -g POWERLEVEL9K_STATUS_VERBOSE_SIGNAME=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_VISUAL_IDENTIFIER_EXPANSION='✘'
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=3
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_BACKGROUND=1
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_VISUAL_IDENTIFIER_EXPANSION='✘'
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=3
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_BACKGROUND=1
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=218
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_BACKGROUND=234
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FORMAT='d h m s'
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_FOREGROUND=6
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_BACKGROUND=0
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
  typeset -g POWERLEVEL9K_DIRENV_FOREGROUND=3
  typeset -g POWERLEVEL9K_DIRENV_BACKGROUND=0
  typeset -g POWERLEVEL9K_ASDF_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_BACKGROUND=7
  typeset -g POWERLEVEL9K_ASDF_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_ASDF_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_ASDF_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_ASDF_RUBY_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_RUBY_BACKGROUND=1
  typeset -g POWERLEVEL9K_ASDF_PYTHON_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_PYTHON_BACKGROUND=4
  typeset -g POWERLEVEL9K_ASDF_GOLANG_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_GOLANG_BACKGROUND=4
  typeset -g POWERLEVEL9K_ASDF_NODEJS_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_NODEJS_BACKGROUND=2
  typeset -g POWERLEVEL9K_ASDF_RUST_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_RUST_BACKGROUND=208
  typeset -g POWERLEVEL9K_ASDF_DOTNET_CORE_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_DOTNET_CORE_BACKGROUND=5
  typeset -g POWERLEVEL9K_ASDF_FLUTTER_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_FLUTTER_BACKGROUND=4
  typeset -g POWERLEVEL9K_ASDF_LUA_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_LUA_BACKGROUND=4
  typeset -g POWERLEVEL9K_ASDF_JAVA_FOREGROUND=1
  typeset -g POWERLEVEL9K_ASDF_JAVA_BACKGROUND=7
  typeset -g POWERLEVEL9K_ASDF_PERL_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_PERL_BACKGROUND=4
  typeset -g POWERLEVEL9K_ASDF_ERLANG_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_ERLANG_BACKGROUND=1
  typeset -g POWERLEVEL9K_ASDF_ELIXIR_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_ELIXIR_BACKGROUND=5
  typeset -g POWERLEVEL9K_ASDF_POSTGRES_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_POSTGRES_BACKGROUND=6
  typeset -g POWERLEVEL9K_ASDF_PHP_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_PHP_BACKGROUND=5
  typeset -g POWERLEVEL9K_ASDF_HASKELL_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_HASKELL_BACKGROUND=3
  typeset -g POWERLEVEL9K_ASDF_JULIA_FOREGROUND=0
  typeset -g POWERLEVEL9K_ASDF_JULIA_BACKGROUND=2
  typeset -g POWERLEVEL9K_NORDVPN_FOREGROUND=7
  typeset -g POWERLEVEL9K_NORDVPN_BACKGROUND=4
  typeset -g POWERLEVEL9K_RANGER_FOREGROUND=3
  typeset -g POWERLEVEL9K_RANGER_BACKGROUND=0
  typeset -g POWERLEVEL9K_NNN_FOREGROUND=0
  typeset -g POWERLEVEL9K_NNN_BACKGROUND=6
  typeset -g POWERLEVEL9K_XPLR_FOREGROUND=0
  typeset -g POWERLEVEL9K_XPLR_BACKGROUND=6
  typeset -g POWERLEVEL9K_VIM_SHELL_FOREGROUND=0
  typeset -g POWERLEVEL9K_VIM_SHELL_BACKGROUND=2
  typeset -g POWERLEVEL9K_MIDNIGHT_COMMANDER_FOREGROUND=3
  typeset -g POWERLEVEL9K_MIDNIGHT_COMMANDER_BACKGROUND=0
  typeset -g POWERLEVEL9K_NIX_SHELL_FOREGROUND=0
  typeset -g POWERLEVEL9K_NIX_SHELL_BACKGROUND=4
  typeset -g POWERLEVEL9K_DISK_USAGE_NORMAL_FOREGROUND=3
  typeset -g POWERLEVEL9K_DISK_USAGE_NORMAL_BACKGROUND=0
  typeset -g POWERLEVEL9K_DISK_USAGE_WARNING_FOREGROUND=0
  typeset -g POWERLEVEL9K_DISK_USAGE_WARNING_BACKGROUND=3
  typeset -g POWERLEVEL9K_DISK_USAGE_CRITICAL_FOREGROUND=7
  typeset -g POWERLEVEL9K_DISK_USAGE_CRITICAL_BACKGROUND=1
  typeset -g POWERLEVEL9K_DISK_USAGE_WARNING_LEVEL=90
  typeset -g POWERLEVEL9K_DISK_USAGE_CRITICAL_LEVEL=95
  typeset -g POWERLEVEL9K_DISK_USAGE_ONLY_WARNING=false
  typeset -g POWERLEVEL9K_VI_MODE_FOREGROUND=0
  typeset -g POWERLEVEL9K_VI_COMMAND_MODE_STRING=NORMAL
  typeset -g POWERLEVEL9K_VI_MODE_NORMAL_BACKGROUND=2
  typeset -g POWERLEVEL9K_VI_VISUAL_MODE_STRING=VISUAL
  typeset -g POWERLEVEL9K_VI_MODE_VISUAL_BACKGROUND=4
  typeset -g POWERLEVEL9K_VI_OVERWRITE_MODE_STRING=OVERTYPE
  typeset -g POWERLEVEL9K_VI_MODE_OVERWRITE_BACKGROUND=3
  typeset -g POWERLEVEL9K_VI_MODE_INSERT_FOREGROUND=8
  typeset -g POWERLEVEL9K_RAM_FOREGROUND=0
  typeset -g POWERLEVEL9K_RAM_BACKGROUND=3
  typeset -g POWERLEVEL9K_SWAP_FOREGROUND=0
  typeset -g POWERLEVEL9K_SWAP_BACKGROUND=3
  typeset -g POWERLEVEL9K_LOAD_WHICH=5
  typeset -g POWERLEVEL9K_LOAD_NORMAL_FOREGROUND=0
  typeset -g POWERLEVEL9K_LOAD_NORMAL_BACKGROUND=2
  typeset -g POWERLEVEL9K_LOAD_WARNING_FOREGROUND=0
  typeset -g POWERLEVEL9K_LOAD_WARNING_BACKGROUND=3
  typeset -g POWERLEVEL9K_LOAD_CRITICAL_FOREGROUND=0
  typeset -g POWERLEVEL9K_LOAD_CRITICAL_BACKGROUND=1
  typeset -g POWERLEVEL9K_TODO_FOREGROUND=0
  typeset -g POWERLEVEL9K_TODO_BACKGROUND=8
  typeset -g POWERLEVEL9K_TODO_HIDE_ZERO_TOTAL=true
  typeset -g POWERLEVEL9K_TODO_HIDE_ZERO_FILTERED=false
  typeset -g POWERLEVEL9K_TIMEWARRIOR_FOREGROUND=255
  typeset -g POWERLEVEL9K_TIMEWARRIOR_BACKGROUND=8
  typeset -g POWERLEVEL9K_TIMEWARRIOR_CONTENT_EXPANSION='${P9K_CONTENT:0:24}${${P9K_CONTENT:24}:+…}'
  typeset -g POWERLEVEL9K_TASKWARRIOR_FOREGROUND=0
  typeset -g POWERLEVEL9K_TASKWARRIOR_BACKGROUND=6
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=1
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_BACKGROUND=234
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_FOREGROUND=26
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_BACKGROUND=234
  typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=3
  typeset -g POWERLEVEL9K_CONTEXT_BACKGROUND=234
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{DEFAULT,SUDO}_{CONTENT,VISUAL_IDENTIFIER}_EXPANSION=
  typeset -g POWERLEVEL9K_VIRTUALENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_VIRTUALENV_BACKGROUND=4
  typeset -g POWERLEVEL9K_VIRTUALENV_SHOW_PYTHON_VERSION=false
  typeset -g POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=false
  typeset -g POWERLEVEL9K_VIRTUALENV_{LEFT,RIGHT}_DELIMITER=
  typeset -g POWERLEVEL9K_ANACONDA_FOREGROUND=154
  typeset -g POWERLEVEL9K_ANACONDA_BACKGROUND=234
  typeset -g POWERLEVEL9K_ANACONDA_CONTENT_EXPANSION='${${${${CONDA_PROMPT_MODIFIER#\(}% }%\)}:-${CONDA_PREFIX:t}}'
  typeset -g POWERLEVEL9K_PYENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_PYENV_BACKGROUND=4
  typeset -g POWERLEVEL9K_PYENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PYENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PYENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_PYENV_CONTENT_EXPANSION='${P9K_CONTENT}${${P9K_CONTENT:#$P9K_PYENV_PYTHON_VERSION(|/*)}:+ $P9K_PYENV_PYTHON_VERSION}'
  typeset -g POWERLEVEL9K_GOENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_GOENV_BACKGROUND=4
  typeset -g POWERLEVEL9K_GOENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_GOENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_GOENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_NODENV_FOREGROUND=2
  typeset -g POWERLEVEL9K_NODENV_BACKGROUND=0
  typeset -g POWERLEVEL9K_NODENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_NODENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_NODENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_NVM_FOREGROUND=0
  typeset -g POWERLEVEL9K_NVM_BACKGROUND=5
  typeset -g POWERLEVEL9K_NODEENV_FOREGROUND=2
  typeset -g POWERLEVEL9K_NODEENV_BACKGROUND=0
  typeset -g POWERLEVEL9K_NODEENV_SHOW_NODE_VERSION=false
  typeset -g POWERLEVEL9K_NODE_VERSION_FOREGROUND=7
  typeset -g POWERLEVEL9K_NODE_VERSION_BACKGROUND=2
  typeset -g POWERLEVEL9K_NODE_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_GO_VERSION_FOREGROUND=255
  typeset -g POWERLEVEL9K_GO_VERSION_BACKGROUND=2
  typeset -g POWERLEVEL9K_GO_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_RUST_VERSION_FOREGROUND=0
  typeset -g POWERLEVEL9K_RUST_VERSION_BACKGROUND=208
  typeset -g POWERLEVEL9K_RUST_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_DOTNET_VERSION_FOREGROUND=7
  typeset -g POWERLEVEL9K_DOTNET_VERSION_BACKGROUND=5
  typeset -g POWERLEVEL9K_DOTNET_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_PHP_VERSION_FOREGROUND=0
  typeset -g POWERLEVEL9K_PHP_VERSION_BACKGROUND=5
  typeset -g POWERLEVEL9K_PHP_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_LARAVEL_VERSION_FOREGROUND=1
  typeset -g POWERLEVEL9K_LARAVEL_VERSION_BACKGROUND=7
  typeset -g POWERLEVEL9K_RBENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_RBENV_BACKGROUND=1
  typeset -g POWERLEVEL9K_RBENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_RBENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_RBENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_JAVA_VERSION_FOREGROUND=1
  typeset -g POWERLEVEL9K_JAVA_VERSION_BACKGROUND=7
  typeset -g POWERLEVEL9K_JAVA_VERSION_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_JAVA_VERSION_FULL=false
  typeset -g POWERLEVEL9K_PACKAGE_FOREGROUND=0
  typeset -g POWERLEVEL9K_PACKAGE_BACKGROUND=6
  typeset -g POWERLEVEL9K_RVM_FOREGROUND=0
  typeset -g POWERLEVEL9K_RVM_BACKGROUND=240
  typeset -g POWERLEVEL9K_RVM_SHOW_GEMSET=false
  typeset -g POWERLEVEL9K_RVM_SHOW_PREFIX=false
  typeset -g POWERLEVEL9K_FVM_FOREGROUND=0
  typeset -g POWERLEVEL9K_FVM_BACKGROUND=4
  typeset -g POWERLEVEL9K_LUAENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_LUAENV_BACKGROUND=4
  typeset -g POWERLEVEL9K_LUAENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_LUAENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_LUAENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_JENV_FOREGROUND=1
  typeset -g POWERLEVEL9K_JENV_BACKGROUND=7
  typeset -g POWERLEVEL9K_JENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_JENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_JENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_PLENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_PLENV_BACKGROUND=4
  typeset -g POWERLEVEL9K_PLENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PLENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PLENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_PERLBREW_FOREGROUND=67
  typeset -g POWERLEVEL9K_PERLBREW_PROJECT_ONLY=true
  typeset -g POWERLEVEL9K_PERLBREW_SHOW_PREFIX=false
  typeset -g POWERLEVEL9K_PHPENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_PHPENV_BACKGROUND=5
  typeset -g POWERLEVEL9K_PHPENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_PHPENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_PHPENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_SCALAENV_FOREGROUND=0
  typeset -g POWERLEVEL9K_SCALAENV_BACKGROUND=1
  typeset -g POWERLEVEL9K_SCALAENV_SOURCES=(shell local global)
  typeset -g POWERLEVEL9K_SCALAENV_PROMPT_ALWAYS_SHOW=false
  typeset -g POWERLEVEL9K_SCALAENV_SHOW_SYSTEM=true
  typeset -g POWERLEVEL9K_HASKELL_STACK_FOREGROUND=0
  typeset -g POWERLEVEL9K_HASKELL_STACK_BACKGROUND=3
  typeset -g POWERLEVEL9K_HASKELL_STACK_SOURCES=(shell local)
  typeset -g POWERLEVEL9K_HASKELL_STACK_ALWAYS_SHOW=true
  typeset -g POWERLEVEL9K_TERRAFORM_SHOW_DEFAULT=false
  typeset -g POWERLEVEL9K_TERRAFORM_CLASSES=(
      '*'         OTHER)
  typeset -g POWERLEVEL9K_TERRAFORM_OTHER_FOREGROUND=4
  typeset -g POWERLEVEL9K_TERRAFORM_OTHER_BACKGROUND=0
  typeset -g POWERLEVEL9K_TERRAFORM_VERSION_FOREGROUND=4
  typeset -g POWERLEVEL9K_TERRAFORM_VERSION_BACKGROUND=0
  typeset -g POWERLEVEL9K_TERRAFORM_VERSION_SHOW_ON_COMMAND='terraform|tf'
  typeset -g POWERLEVEL9K_KUBECONTEXT_SHOW_ON_COMMAND='kubectl|helm|kubens|kubectx|oc|istioctl|kogito|k9s|helmfile|flux|fluxctl|stern|kubeseal|skaffold'
  typeset -g POWERLEVEL9K_KUBECONTEXT_CLASSES=(
      '*'       DEFAULT)
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_FOREGROUND=7
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_BACKGROUND=5
  POWERLEVEL9K_KUBECONTEXT_DEFAULT_CONTENT_EXPANSION+='${P9K_KUBECONTEXT_CLOUD_CLUSTER:-${P9K_KUBECONTEXT_NAME}}'
  POWERLEVEL9K_KUBECONTEXT_DEFAULT_CONTENT_EXPANSION+='${${:-/$P9K_KUBECONTEXT_NAMESPACE}:#/default}'
  typeset -g POWERLEVEL9K_AWS_SHOW_ON_COMMAND='aws|awless|terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_AWS_CLASSES=(
      '*'       DEFAULT)
  typeset -g POWERLEVEL9K_AWS_DEFAULT_FOREGROUND=7
  typeset -g POWERLEVEL9K_AWS_DEFAULT_BACKGROUND=1
  typeset -g POWERLEVEL9K_AWS_CONTENT_EXPANSION='${P9K_AWS_PROFILE//\%/%%}${P9K_AWS_REGION:+ ${P9K_AWS_REGION//\%/%%}}'
  typeset -g POWERLEVEL9K_AWS_EB_ENV_FOREGROUND=2
  typeset -g POWERLEVEL9K_AWS_EB_ENV_BACKGROUND=0
  typeset -g POWERLEVEL9K_AZURE_SHOW_ON_COMMAND='az|terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_AZURE_FOREGROUND=7
  typeset -g POWERLEVEL9K_AZURE_BACKGROUND=4
  typeset -g POWERLEVEL9K_GCLOUD_SHOW_ON_COMMAND='gcloud|gcs|gsutil'
  typeset -g POWERLEVEL9K_GCLOUD_FOREGROUND=7
  typeset -g POWERLEVEL9K_GCLOUD_BACKGROUND=4
  typeset -g POWERLEVEL9K_GCLOUD_PARTIAL_CONTENT_EXPANSION='${P9K_GCLOUD_PROJECT_ID//\%/%%}'
  typeset -g POWERLEVEL9K_GCLOUD_COMPLETE_CONTENT_EXPANSION='${P9K_GCLOUD_PROJECT_NAME//\%/%%}'
  typeset -g POWERLEVEL9K_GCLOUD_REFRESH_PROJECT_NAME_SECONDS=60
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_SHOW_ON_COMMAND='terraform|pulumi|terragrunt'
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_CLASSES=(
      '*'             DEFAULT)
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_DEFAULT_FOREGROUND=7
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_DEFAULT_BACKGROUND=4
  typeset -g POWERLEVEL9K_GOOGLE_APP_CRED_DEFAULT_CONTENT_EXPANSION='${P9K_GOOGLE_APP_CRED_PROJECT_ID//\%/%%}'
  typeset -g POWERLEVEL9K_TOOLBOX_FOREGROUND=0
  typeset -g POWERLEVEL9K_TOOLBOX_BACKGROUND=3
  typeset -g POWERLEVEL9K_TOOLBOX_CONTENT_EXPANSION='${P9K_TOOLBOX_NAME:#fedora-toolbox-*}'
  typeset -g POWERLEVEL9K_PUBLIC_IP_FOREGROUND=7
  typeset -g POWERLEVEL9K_PUBLIC_IP_BACKGROUND=0
  typeset -g POWERLEVEL9K_VPN_IP_FOREGROUND=0
  typeset -g POWERLEVEL9K_VPN_IP_BACKGROUND=6
  typeset -g POWERLEVEL9K_VPN_IP_INTERFACE='(gpd|wg|(.*tun)|tailscale)[0-9]*'
  typeset -g POWERLEVEL9K_VPN_IP_SHOW_ALL=false
  typeset -g POWERLEVEL9K_IP_BACKGROUND=4
  typeset -g POWERLEVEL9K_IP_FOREGROUND=0
  typeset -g POWERLEVEL9K_IP_CONTENT_EXPANSION='${P9K_IP_RX_RATE:+⇣$P9K_IP_RX_RATE }${P9K_IP_TX_RATE:+⇡$P9K_IP_TX_RATE }$P9K_IP_IP'
  typeset -g POWERLEVEL9K_IP_INTERFACE='[ew].*'
  typeset -g POWERLEVEL9K_PROXY_FOREGROUND=4
  typeset -g POWERLEVEL9K_PROXY_BACKGROUND=0
  typeset -g POWERLEVEL9K_BATTERY_LOW_THRESHOLD=20
  typeset -g POWERLEVEL9K_BATTERY_LOW_FOREGROUND=1
  typeset -g POWERLEVEL9K_BATTERY_{CHARGING,CHARGED}_FOREGROUND=2
  typeset -g POWERLEVEL9K_BATTERY_DISCONNECTED_FOREGROUND=3
  typeset -g POWERLEVEL9K_BATTERY_STAGES='\uf58d\uf579\uf57a\uf57b\uf57c\uf57d\uf57e\uf57f\uf580\uf581\uf578'
  typeset -g POWERLEVEL9K_BATTERY_VERBOSE=false
  typeset -g POWERLEVEL9K_BATTERY_BACKGROUND=0
  typeset -g POWERLEVEL9K_WIFI_FOREGROUND=0
  typeset -g POWERLEVEL9K_WIFI_BACKGROUND=4
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=208
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=234
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%m/%d %R}' 
  typeset -g POWERLEVEL9K_TIME_UPDATE_ON_COMMAND=true
  function prompt_example() {
    p10k segment -b 1 -f 3 -i '⭐' -t 'hello, %n'
  }
  function instant_prompt_example() {
    prompt_example
  }
  typeset -g POWERLEVEL9K_EXAMPLE_FOREGROUND=3
  typeset -g POWERLEVEL9K_EXAMPLE_BACKGROUND=1
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
  (( ! $+functions[p10k] )) || p10k reload
}
typeset -g POWERLEVEL9K_CONFIG_FILE=${${(%):-%x}:a}
(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_EOF
  sudo_if_needed chown "$TARGET_USER:$TARGET_USER" "$p10k_path"
}

main() {
  detect_platform
  local plat_msg="${OS}/${ARCH}"
  if [[ -n "${LINUX_ID}" ]]; then plat_msg+=" (${LINUX_ID})"; fi
  info "Detected platform: ${plat_msg}"
  setup_hostname
  create_or_select_user
  prepare_user_ssh_and_dirs
  install_zsh_and_plugins
  install_miniconda
  choose_p10k_color
  setup_git
  info "All done. Open a new terminal or 'sudo -iu $TARGET_USER zsh' to start using zsh."
}

main "$@"


