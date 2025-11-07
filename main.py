#!/usr/bin/env python3

"""Interactive server initialization workflow driven by simple-term-menu.

This script follows the expectations outlined in plan.md.  It keeps the heavy
lifting inside Python so we can centralise prompts, logging, and dry-run logic
before touching the host system.  Task implementations intentionally run in
dry-run mode unless the caller explicitly opts in with --force to avoid
accidental changes while the workflow is still under active development."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import getpass
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Iterable, List, Optional, Sequence


# -- simple-term-menu bootstrap -------------------------------------------------

def _ensure_simple_term_menu() -> None:
	"""Make sure TerminalMenu is importable.

	The bash wrapper prefers shipping a native binary; this helper verifies that
	the Python package is available and directs the operator to install it when
	it is not present.  The rest of the code relies on the Python API uniformly."""

	try:  # Fast path when the package is already there.
		import simple_term_menu  # type: ignore  # noqa: F401
		return
	except ModuleNotFoundError:
		message = (
			"simple-term-menu is not installed. Install it with:\n"
			"  pip install simple-term-menu"
		)
		raise SystemExit(message)


_ensure_simple_term_menu()
from simple_term_menu import TerminalMenu  # type: ignore  # noqa: E402


# -- data definitions -----------------------------------------------------------


class Context:
	ROOT = "root"
	EXISTING_USER = "user"
	LOCAL = "local"


CONTEXT_OPTIONS: Sequence[str] = (
	"Server setup in root",
	"Server setup in existing user",
	"Local setup",
)

CONTEXT_VALUE_BY_INDEX = {
	0: Context.ROOT,
	1: Context.EXISTING_USER,
	2: Context.LOCAL,
}

CONTEXT_INDEX_BY_VALUE = {v: k for k, v in CONTEXT_VALUE_BY_INDEX.items()}


@dataclasses.dataclass(slots=True)
class TaskDefinition:
	key: str
	title: str
	description: str


TASKS: Sequence[TaskDefinition] = (
	TaskDefinition("os", "OS settings (hostname + user)", "Manage hostname and users"),
	TaskDefinition("ssh", "SSH setup", "Populate authorised keys and secure SSH"),
	TaskDefinition("zsh", "Customized zsh", "Install zsh, plugins, and dotfiles"),
	TaskDefinition("conda", "Miniconda", "Install Miniconda and base environment"),
	TaskDefinition("git", "Git setup", "Configure git identity"),
)

TASK_INDEX_BY_KEY = {task.key: idx for idx, task in enumerate(TASKS)}


DEFAULTS_BY_CONTEXT = {
	Context.ROOT: [TASK_INDEX_BY_KEY["os"], TASK_INDEX_BY_KEY["ssh"], TASK_INDEX_BY_KEY["zsh"], TASK_INDEX_BY_KEY["conda"]],
	Context.EXISTING_USER: [TASK_INDEX_BY_KEY["ssh"], TASK_INDEX_BY_KEY["zsh"], TASK_INDEX_BY_KEY["conda"]],
	Context.LOCAL: [TASK_INDEX_BY_KEY["zsh"], TASK_INDEX_BY_KEY["conda"]],
}


@dataclasses.dataclass(slots=True)
class OSInfo:
	name: str
	version: str


@dataclasses.dataclass(slots=True)
class PathsConfig:
	home_dir: pathlib.Path
	ssh_authorized_keys: pathlib.Path
	zshrc: pathlib.Path
	p10k: pathlib.Path
	data_dirs: Sequence[pathlib.Path]


@dataclasses.dataclass(slots=True)
class ExecutionOptions:
	dry_run: bool
	sudo_allowed: bool
	force: bool
	auto_confirm: bool


MARKER_DIR_NAME = ".server_init_markers"


def task_marker(paths: PathsConfig, key: str) -> pathlib.Path:
	return paths.home_dir / MARKER_DIR_NAME / f"{key}.done"


def is_task_marked_complete(paths: PathsConfig, key: str) -> bool:
	return task_marker(paths, key).exists()


def mark_task_complete(paths: PathsConfig, key: str, options: ExecutionOptions) -> None:
	marker = task_marker(paths, key)
	if options.dry_run:
		print(f"(dry-run) Would record completion marker at {marker}.")
		return
	marker.parent.mkdir(parents=True, exist_ok=True)
	marker.write_text(_dt.datetime.now().isoformat(), encoding="utf-8")
	print(f"Recorded completion marker at {marker}.")


# -- helpers --------------------------------------------------------------------


def detect_os() -> OSInfo:
	name = platform.system()
	version = platform.version()
	return OSInfo(name=name, version=version)


def detect_arch() -> str:
	return platform.machine()


def prompt_yes_no(message: str, *, default: bool = False, auto_confirm: bool = False) -> bool:
	"""Ask the user to confirm an action."""

	if auto_confirm:
		return True

	default_hint = "Y/n" if default else "y/N"
	prompt = f"{message} [{default_hint}] "
	while True:
		try:
			answer = input(prompt).strip().lower()
		except EOFError:
			print()
			return default
		if not answer:
			return default
		if answer in {"y", "yes"}:
			return True
		if answer in {"n", "no"}:
			return False
		print("Please answer yes or no.")


def defaults_for_context(context: str) -> List[int]:
	return list(DEFAULTS_BY_CONTEXT.get(context, []))


def order_tasks_from_indices(indices: Iterable[int]) -> List[TaskDefinition]:
	ordered_keys = [task.key for task in TASKS]
	selected_keys = {TASKS[i].key for i in indices}
	return [TASKS[ordered_keys.index(key)] for key in ordered_keys if key in selected_keys]


def should_skip(task_key: str, context: str) -> bool:
	if context == Context.EXISTING_USER and task_key == "os":
		return True
	if context == Context.LOCAL and task_key == "ssh":
		return True
	return False


def detect_default_paths(context: str, target_user: Optional[str] = None) -> PathsConfig:
	if context == Context.ROOT:
		home = pathlib.Path("/root")
	else:
		home = pathlib.Path(pathlib.Path.home())
	if target_user and context == Context.ROOT and target_user != "root":
		# Allow pointing to a fresh user created during the OS task; fall back to /home/<user>.
		home = pathlib.Path("/home") / target_user

	ssh_keys = home / ".ssh" / "authorized_keys"
	return PathsConfig(
		home_dir=home,
		ssh_authorized_keys=ssh_keys,
		zshrc=home / ".zshrc",
		p10k=home / ".p10k.zsh",
		data_dirs=(home / "toolchain", home / "temp", home / "workspace"),
	)


def confirm_paths(defaults: PathsConfig, auto_confirm: bool) -> PathsConfig:
	if auto_confirm:
		return defaults

	print("\nReview target paths (press ENTER to keep defaults):")

	def _ask(path: pathlib.Path, label: str) -> pathlib.Path:
		value = input(f"{label} [{path}]: ").strip()
		return pathlib.Path(value) if value else path

	home = _ask(defaults.home_dir, "Home directory")
	ssh_keys = _ask(defaults.ssh_authorized_keys, "authorized_keys path")
	zshrc = _ask(defaults.zshrc, ".zshrc path")
	p10k = _ask(defaults.p10k, ".p10k.zsh path")

	data_dirs: List[pathlib.Path] = []
	for idx, default_dir in enumerate(defaults.data_dirs, start=1):
		data_dirs.append(_ask(default_dir, f"Data dir #{idx}"))

	return PathsConfig(home, ssh_keys, zshrc, p10k, tuple(data_dirs))


class CommandRunner:
	"""Wrapper that logs and optionally executes shell commands."""

	def __init__(self, *, log_file: pathlib.Path, dry_run: bool, sudo_allowed: bool) -> None:
		self.log_file = log_file
		self.dry_run = dry_run
		self.sudo_allowed = sudo_allowed
		self._log_file_handle = log_file.open("a", encoding="utf-8")

	def close(self) -> None:
		self._log_file_handle.close()

	def _write(self, text: str) -> None:
		self._log_file_handle.write(text)
		self._log_file_handle.flush()

	def run(
		self,
		command: Sequence[str],
		*,
		sudo: bool = False,
		cwd: Optional[pathlib.Path] = None,
		env: Optional[dict[str, str]] = None,
		check: bool = True,
	) -> subprocess.CompletedProcess[str] | None:
		timestamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
		cmd_list = list(command)
		if sudo:
			if not self.sudo_allowed:
				raise RuntimeError("Attempted to use sudo without permission")
			cmd_list = ["sudo", "--"] + cmd_list

		joined = shlex.join(cmd_list)
		cwd_str = str(cwd) if cwd else os.getcwd()
		env_keys = sorted((env or {}).keys())
		self._write(f"\n[{timestamp}] CMD: {joined}\n")
		self._write(f"cwd={cwd_str} sudo={sudo} env_overrides={env_keys}\n")

		if self.dry_run:
			self._write("(dry-run) Command not executed.\n")
			return None

		proc = subprocess.run(
			cmd_list,
			cwd=str(cwd) if cwd else None,
			env={**os.environ, **(env or {})},
			capture_output=True,
			text=True,
			check=False,
		)

		self._write(f"exit_code={proc.returncode}\n")
		if proc.stdout:
			self._write("--- stdout ---\n" + proc.stdout)
		if proc.stderr:
			self._write("--- stderr ---\n" + proc.stderr)

		if check and proc.returncode != 0:
			raise RuntimeError(f"Command failed with exit code {proc.returncode}: {joined}")
		return proc


def fetch_github_keys(username: str) -> List[str]:
	url = f"https://github.com/{username}.keys"
	request = urllib.request.Request(url, headers={"User-Agent": "server-init/1.0"})
	try:
		with urllib.request.urlopen(request, timeout=10) as response:
			status = getattr(response, "status", response.getcode())
			if status != 200:
				print(f"Failed to fetch keys for GitHub user '{username}' (HTTP {status}).")
				return []
			data = response.read().decode("utf-8", errors="ignore")
	except urllib.error.URLError as exc:
		print(f"Failed to fetch keys for GitHub user '{username}': {exc}")
		return []
	keys = [line.strip() for line in data.splitlines() if line.strip()]
	if not keys:
		print(f"No public keys found for GitHub user '{username}'.")
	return keys


# -- menu helpers ---------------------------------------------------------------


def _run_menu(options: Sequence[str], *, title: str, cursor_index: int = 0) -> int:
	menu = TerminalMenu(options, title=title, cursor_index=cursor_index)
	index = menu.show()
	if index is None:
		raise SystemExit("User aborted selection.")
	return index


def _run_multi_menu(
	options: Sequence[str],
	*,
	title: str,
	preselected: Sequence[int],
) -> List[int]:
	menu = TerminalMenu(
		options,
		title=title,
		multi_select=True,
		show_multi_select_hint=True,
		preselected_entries=preselected,
	)
	indices = menu.show()
	if indices is None:
		raise SystemExit("User aborted selection.")
	return list(indices)


# -- task implementations -------------------------------------------------------


def task_os_settings(runner: CommandRunner, options: ExecutionOptions, paths: PathsConfig) -> None:
	current_hostname = platform.node()
	print(f"\n[OS settings] Current hostname: {current_hostname}")

	if prompt_yes_no(
		"Change hostname?",
		default=False,
		auto_confirm=options.auto_confirm,
	):
		new_hostname = input("New hostname: ").strip()
		if new_hostname:
			runner.run(["hostnamectl", "set-hostname", new_hostname], sudo=True)
		else:
			print("Hostname unchanged (empty value).")

	is_root = hasattr(os, "geteuid") and os.geteuid() == 0
	current_user = getpass.getuser()
	if is_root:
		if prompt_yes_no(
			"Create a new user account?",
			default=True,
			auto_confirm=options.auto_confirm,
		):
			username = input("Username for the new account: ").strip()
			if not username:
				print("No username provided; skipping user creation.")
			else:
				sudo_ask = prompt_yes_no(
					"Grant sudo privileges to the new user?",
					default=True,
					auto_confirm=options.auto_confirm,
				)
				runner.run(["adduser", username], sudo=True, check=False)
				if sudo_ask:
					runner.run(["usermod", "-aG", "sudo", username], sudo=True)
	else:
		if not prompt_yes_no(
			f"Continue with current user '{current_user}'?",
			default=True,
			auto_confirm=options.auto_confirm,
		):
			print("Manual switch to another user is required before rerunning the script.")

	mark_task_complete(paths, "os", options)


def task_ssh_setup(runner: CommandRunner, options: ExecutionOptions, paths: PathsConfig) -> None:
	print("\n[SSH setup] Preparing ~/.ssh/authorized_keys flow.")
	if not options.dry_run:
		paths.ssh_authorized_keys.parent.mkdir(parents=True, exist_ok=True)
		paths.ssh_authorized_keys.touch(exist_ok=True)
	runner.run(["chmod", "700", str(paths.ssh_authorized_keys.parent)], sudo=False)
	runner.run(["chmod", "600", str(paths.ssh_authorized_keys)], sudo=False)

	default_username = (
		os.environ.get("GITHUB_USERNAME")
		or os.environ.get("GH_USERNAME")
		or os.environ.get("GH_USER")
		or ""
	)
	github_username = default_username
	if not options.auto_confirm:
		prompt = "GitHub username for SSH keys"
		if default_username:
			prompt += f" [{default_username}]"
		prompt += ": "
		user_input = input(prompt).strip()
		if user_input:
			github_username = user_input
	elif not github_username:
		print("Auto-confirm enabled but no GitHub username provided via environment; skipping key download.")

	if github_username:
		keys = fetch_github_keys(github_username)
		if keys:
			existing_keys: set[str] = set()
			if paths.ssh_authorized_keys.exists():
				existing_content = paths.ssh_authorized_keys.read_text(encoding="utf-8", errors="ignore")
				existing_keys = {
					line.strip()
					for line in existing_content.splitlines()
					if line.strip() and not line.startswith("#")
				}
			new_keys = [key for key in keys if key not in existing_keys]
			if not new_keys:
				print(f"All keys for GitHub user '{github_username}' are already present in {paths.ssh_authorized_keys}.")
			else:
				timestamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
				if options.dry_run:
					print(f"(dry-run) Would append {len(new_keys)} keys for '{github_username}' to {paths.ssh_authorized_keys}.")
				else:
					with paths.ssh_authorized_keys.open("a", encoding="utf-8") as fh:
						fh.write(f"\n# GitHub keys for {github_username} added {timestamp}\n")
						for key in new_keys:
							fh.write(f"{key}\n")
					print(f"Added {len(new_keys)} keys for GitHub user '{github_username}'.")
	else:
		print("No GitHub username provided; skipping public key download.")

	mark_task_complete(paths, "ssh", options)


def task_custom_zsh(runner: CommandRunner, options: ExecutionOptions, paths: PathsConfig) -> None:
	print("\n[Customized zsh] Installing zsh and plugins (logged only by default).")
	commands = [
		(["apt", "update"], True),
		(["apt", "install", "-y", "zsh"], True),
		([
			"git",
			"clone",
			"--depth=1",
			"https://github.com/romkatv/powerlevel10k.git",
			str(paths.home_dir / ".zsh" / "powerlevel10k"),
		], False),
		([
			"git",
			"clone",
			"https://github.com/zsh-users/zsh-autosuggestions",
			str(paths.home_dir / ".zsh" / "zsh-autosuggestions"),
		], False),
		([
			"git",
			"clone",
			"https://github.com/zsh-users/zsh-syntax-highlighting.git",
			str(paths.home_dir / ".zsh" / "zsh-syntax-highlighting"),
		], False),
		# fzf installation (user space)
		([
			"git",
			"clone",
			"--depth",
			"1",
			"https://github.com/junegunn/fzf.git",
			str(paths.home_dir / "toolchain" / "fzf"),
		], False),
		([
			"bash",
			str(paths.home_dir / "toolchain" / "fzf" / "install"),
			"--all",
			"--no-update-rc",
		], False),
		# Atuin installation (pipe script)
		([
			"bash",
			"-lc",
			"curl -fsSL https://raw.githubusercontent.com/atuinsh/atuin/main/install.sh | bash",
		], False),
	]
	for cmd, sudo in commands:
		runner.run(cmd, sudo=sudo)

	current_shell = os.environ.get("SHELL", "")
	zsh_path = shutil.which("zsh")
	if not zsh_path:
		zsh_path = "/usr/bin/zsh"
	target_user = paths.home_dir.name or getpass.getuser()
	if current_shell.endswith("zsh") and target_user == getpass.getuser():
		print("Default shell already set to zsh; skipping chsh.")
	else:
		chsh_cmd: List[str] = ["chsh", "-s", zsh_path]
		sudo_for_chsh = False
		if target_user and target_user != getpass.getuser():
			chsh_cmd.append(target_user)
			sudo_for_chsh = True
		runner.run(chsh_cmd, sudo=sudo_for_chsh)

	if not options.dry_run:
		paths.home_dir.mkdir(parents=True, exist_ok=True)
		(paths.home_dir / ".zsh").mkdir(parents=True, exist_ok=True)
		for directory in paths.data_dirs:
			directory.mkdir(parents=True, exist_ok=True)

		repo_root = pathlib.Path(__file__).resolve().parent
		zshrc_src = repo_root / ".zshrc"
		p10k_src = repo_root / ".p10k_simplified_cmt.zsh"
		if zshrc_src.exists():
			shutil.copy2(zshrc_src, paths.zshrc)
		if p10k_src.exists():
			shutil.copy2(p10k_src, paths.p10k)

	# Theme color customization: display palette (when possible), prompt, and update p10k
	print("\n[Customized zsh] Theme color customization for POWERLEVEL9K_OS_ICON_FOREGROUND")
	palette_cmd = (
		'for i in {0..255}; do print -Pn "%K{$i}  %k%F{$i}${(l:3::0:)i}%f " ${${(M)$((i%6)):#3}:+$\'\n\'}; done'
	)
	showed_palette = False
	if not options.dry_run and shutil.which("zsh"):
		try:
			proc = runner.run(["zsh", "-ic", palette_cmd], sudo=False, check=False)
			if proc and proc.stdout:
				# Print palette for user to see
				print(proc.stdout)
				showed_palette = True
		except Exception as e:  # pragma: no cover - palette best-effort
			print(f"Could not display color palette: {e}")
	else:
		print("(dry-run or zsh not available) Skipping palette display. You can preview later with:")
		print("  zsh -ic '" + palette_cmd + "'")

	# Prompt for color id (default 38)
	def _prompt_color(default: int = 38) -> int:
		while True:
			raw = input(f"Enter color id for OS icon foreground [0-255] (default {default}): ").strip()
			if not raw:
				return default
			if raw.isdigit():
				val = int(raw)
				if 0 <= val <= 255:
					return val
			print("Please enter a number between 0 and 255.")

	color_id = _prompt_color() if not options.auto_confirm else 38

	# Update ~/.p10k.zsh line: typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=<id>
	new_line = f"typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND={color_id}\n"
	if paths.p10k.exists():
		if options.dry_run:
			print(f"(dry-run) Would update {paths.p10k} with: {new_line.strip()}")
		else:
			ts = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
			backup = paths.p10k.with_suffix(paths.p10k.suffix + f".bak.{ts}")
			try:
				shutil.copy2(paths.p10k, backup)
			except Exception as e:  # pragma: no cover
				print(f"Warning: failed to create backup {backup}: {e}")

			content = paths.p10k.read_text(encoding="utf-8")
			pattern = re.compile(r"^\s*typeset\s+-g\s+POWERLEVEL9K_OS_ICON_FOREGROUND\s*=\s*\d+\s*$", re.MULTILINE)
			if pattern.search(content):
				content = pattern.sub(new_line.strip(), content)
			else:
				if not content.endswith("\n"):
					content += "\n"
				content += new_line
			paths.p10k.write_text(content, encoding="utf-8")
			print(f"Updated {paths.p10k} (backup at {backup}).")
	else:
		# Create a minimal file with the setting
		if options.dry_run:
			print(f"(dry-run) Would create {paths.p10k} with: {new_line.strip()}")
		else:
			paths.p10k.write_text(new_line, encoding="utf-8")
			print(f"Created {paths.p10k} with OS icon color {color_id}.")

	print(
		"Atuin reminder: set sync_address = \"http://170.9.246.109:11040\" in "
		f"{paths.home_dir / '.config' / 'atuin' / 'config.toml'} and run 'atuin login' to use PaperL's self-hosted server."
	)

	mark_task_complete(paths, "zsh", options)


def task_miniconda(runner: CommandRunner, options: ExecutionOptions, paths: PathsConfig, arch: str) -> None:
	print("\n[Miniconda] Checking/installing under ~/toolchain/miniconda3.")

	# Target prefix under toolchain
	prefix = paths.home_dir / "toolchain" / "miniconda3"
	conda_bin = prefix / "bin" / "conda"

	# Idempotency: if conda already exists at the target, skip the installer
	if conda_bin.exists():
		print(f"Miniconda already present at {prefix}. Skipping installer.")
	else:
		# Determine OS-specific installer URL
		system = platform.system()
		if system == "Darwin":
			if arch in {"arm64", "aarch64"}:
				url = "https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
			else:
				url = "https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
		elif system == "Linux":
			if arch in {"x86_64", "amd64"}:
				url = "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
			elif arch in {"aarch64", "arm64"}:
				url = "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
			else:
				print(f"Unsupported architecture '{arch}' for Miniconda on Linux.")
				return
		else:
			print(f"Unsupported OS '{system}' for automated Miniconda install.")
			return

		installer = paths.home_dir / "miniconda-installer.sh"
		runner.run(["wget", "-O", str(installer), url])
		# Ensure toolchain directory exists when not in dry-run
		if not options.dry_run:
			(paths.home_dir / "toolchain").mkdir(parents=True, exist_ok=True)
		runner.run(["bash", str(installer), "-b", "-p", str(prefix)])

	# Post-install configuration using the detected/target conda
	runner.run([str(conda_bin), "config", "--set", "auto_activate_base", "false"])

	env_dir = prefix / "envs" / "py12"
	if env_dir.exists():
		print(f"Conda environment 'py12' already exists at {env_dir}. Skipping creation.")
	else:
		tos_channels = [
			"https://repo.anaconda.com/pkgs/main",
			"https://repo.anaconda.com/pkgs/r",
		]
		accept_tos = prompt_yes_no(
			"Accept Anaconda Terms of Service for repo.anaconda.com channels?",
			default=True,
			auto_confirm=options.auto_confirm,
		)
		if not accept_tos:
			print("Cannot proceed with Miniconda environment creation without accepting the Terms of Service.")
			return

		for channel in tos_channels:
			if options.dry_run:
				print(f"(dry-run) Would run: {conda_bin} tos accept --override-channels --channel {channel}")
			else:
				runner.run(
					[
						str(conda_bin),
						"tos",
						"accept",
						"--override-channels",
						"--channel",
						channel,
					],
					sudo=False,
				)

		runner.run([str(conda_bin), "create", "-y", "-n", "py12", "python=3.12"])

	runner.run([str(conda_bin), "init", "zsh"])

	activation_line = "conda activate py12"
	if paths.zshrc.exists():
		existing = paths.zshrc.read_text(encoding="utf-8")
		if activation_line not in existing:
			if options.dry_run:
				print(f"(dry-run) Would append '{activation_line}' to {paths.zshrc}.")
			else:
				with paths.zshrc.open("a", encoding="utf-8") as fh:
					if not existing.endswith("\n"):
						fh.write("\n")
					fh.write(f"{activation_line}\n")
	else:
		if options.dry_run:
			print(f"(dry-run) Would create {paths.zshrc} with '{activation_line}'.")
		else:
			paths.zshrc.parent.mkdir(parents=True, exist_ok=True)
			paths.zshrc.write_text(f"{activation_line}\n", encoding="utf-8")
			print(f"Created {paths.zshrc} with '{activation_line}'.")

	mark_task_complete(paths, "conda", options)


def task_git_setup(runner: CommandRunner, options: ExecutionOptions, paths: PathsConfig) -> None:
	print("\n[Git setup] Capture git identity (interactive prompts will follow).")
	if options.auto_confirm:
		username = os.environ.get("GIT_AUTHOR_NAME", "")
		email = os.environ.get("GIT_AUTHOR_EMAIL", "")
	else:
		username = input("Git user.name (leave blank to skip): ").strip()
		email = input("Git user.email (leave blank to skip): ").strip()
	if username:
		runner.run(["git", "config", "--global", "user.name", username], sudo=False)
	if email:
		runner.run(["git", "config", "--global", "user.email", email], sudo=False)

	mark_task_complete(paths, "git", options)


TASK_IMPLEMENTATIONS = {
	"os": task_os_settings,
	"ssh": task_ssh_setup,
	"zsh": task_custom_zsh,
	"conda": task_miniconda,
	"git": task_git_setup,
}


# -- argument parsing -----------------------------------------------------------


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description="Server initialization orchestrator (Python + simple-term-menu)",
	)
	parser.add_argument(
		"--context",
		choices=list(CONTEXT_INDEX_BY_VALUE.keys()),
		help="Preset the context menu selection and skip the prompt when --yes is used.",
	)
	parser.add_argument(
		"--tasks",
		help="Comma separated list of tasks to preselect (os,ssh,zsh,conda,git).",
	)
	parser.add_argument("-y", "--yes", action="store_true", help="Assume yes for confirmation prompts.")
	parser.add_argument("--dry-run", action="store_true", help="Print and log commands without executing them.")
	parser.add_argument(
		"--force",
		action="store_true",
		help="Run tasks even if they were completed previously. Required to execute commands when not in --dry-run.",
	)
	parser.add_argument(
		"--log-file",
		type=pathlib.Path,
		help="Override the default log file path.",
	)
	parser.add_argument(
		"--no-menu",
		action="store_true",
		help="Skip TUI menus when context/tasks are fully specified via flags.",
	)
	parser.add_argument(
		"--resume-state",
		type=pathlib.Path,
		help="Path to server_init_state.json to resume previous run.",
	)
	parser.add_argument(
		"--write-state",
		type=pathlib.Path,
		help="Save execution journal to this path (defaults to .server_init_state.json in repo).",
	)
	return parser.parse_args(argv)


# -- state management ----------------------------------------------------------


def load_state(path: pathlib.Path | None) -> dict[str, bool]:
	if not path or not path.exists():
		return {}
	try:
		return json.loads(path.read_text(encoding="utf-8"))
	except json.JSONDecodeError:
		print(f"Failed to parse state file at {path}; starting fresh.")
		return {}


def save_state(path: pathlib.Path | None, state: dict[str, bool]) -> None:
	if not path:
		return
	path.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


# -- core workflow -------------------------------------------------------------


def resolve_context(args: argparse.Namespace, *, auto_confirm: bool, use_menu: bool) -> str:
	if args.context:
		value = args.context
	else:
		value = Context.ROOT

	if args.no_menu or not use_menu or (args.context and auto_confirm):
		return value

	cursor_index = CONTEXT_INDEX_BY_VALUE.get(value, 0)
	index = _run_menu(CONTEXT_OPTIONS, title="Choose context", cursor_index=cursor_index)
	return CONTEXT_VALUE_BY_INDEX[index]


def resolve_tasks(
	args: argparse.Namespace,
	*,
	context: str,
	auto_confirm: bool,
	use_menu: bool,
) -> List[int]:
	if args.tasks:
		requested = [token.strip().lower() for token in args.tasks.split(",") if token.strip()]
		invalid = [token for token in requested if token not in TASK_INDEX_BY_KEY]
		if invalid:
			raise SystemExit(f"Invalid task identifiers: {', '.join(invalid)}")
		indices = [TASK_INDEX_BY_KEY[token] for token in requested]
	else:
		indices = defaults_for_context(context)

	if args.no_menu or not use_menu or (args.tasks and auto_confirm):
		return indices

	options = [task.title for task in TASKS]
	return _run_multi_menu(
		options,
		title="Select tasks (SPACE to toggle, ENTER to confirm)",
		preselected=indices,
	)


def ensure_command_execution_safety(args: argparse.Namespace) -> ExecutionOptions:
	# Require --force to execute actual commands; otherwise enforce dry-run.
	dry_run = args.dry_run or not args.force
	if args.force and args.dry_run:
		print("--force provided together with --dry-run; commands will still not execute.")
	if not args.force and not args.dry_run:
		print("Commands will run in dry-run mode until --force is supplied.")

	sudo_allowed = prompt_yes_no(
		"Use elevated privileges for privileged operations?",
		default=False,
		auto_confirm=args.yes,
	)
	return ExecutionOptions(
		dry_run=dry_run,
		sudo_allowed=sudo_allowed,
		force=args.force,
		auto_confirm=args.yes,
	)


def prepare_logger(log_file: pathlib.Path | None) -> pathlib.Path:
	if log_file:
		log_path = log_file
	else:
		logs_dir = pathlib.Path.cwd() / "logs"
		logs_dir.mkdir(parents=True, exist_ok=True)
		timestamp = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
		log_path = logs_dir / f"server_init_{timestamp}.log"
	log_path.parent.mkdir(parents=True, exist_ok=True)
	log_path.touch(exist_ok=True)
	return log_path


def main(argv: Optional[Sequence[str]] = None) -> int:
	args = parse_args(argv)
	state_path = args.resume_state or pathlib.Path(".server_init_state.json")
	state = load_state(state_path)

	os_info = detect_os()
	arch = detect_arch()
	print(f"Detected OS: {os_info.name} {os_info.version}")
	print(f"Detected architecture: {arch}")

	use_menu = not args.no_menu
	context = resolve_context(args, auto_confirm=args.yes, use_menu=use_menu)
	selected_indices = resolve_tasks(args, context=context, auto_confirm=args.yes, use_menu=use_menu)

	options = ensure_command_execution_safety(args)

	current_user = getpass.getuser()
	target_for_paths = None if context == Context.ROOT else current_user
	paths = detect_default_paths(context, target_for_paths)
	paths = confirm_paths(paths, options.auto_confirm)

	log_path = prepare_logger(args.log_file)
	print(f"Logging commands to {log_path}")

	runner = CommandRunner(log_file=log_path, dry_run=options.dry_run, sudo_allowed=options.sudo_allowed)

	ordered_tasks = order_tasks_from_indices(selected_indices)
	completed: dict[str, bool] = {}
	completed.update(state)

	try:
		for task in ordered_tasks:
			if should_skip(task.key, context):
				print(f"Skipping {task.title} due to context rules.")
				continue
			if not args.force and is_task_marked_complete(paths, task.key):
				marker = task_marker(paths, task.key)
				print(f"Skipping {task.title} (already completed at {marker}).")
				completed[task.key] = True
				continue
			if completed.get(task.key) and not args.force:
				print(f"Skipping {task.title} (already completed; use --force to rerun).")
				continue
			print(f"\n=== Running task: {task.title} ===")
			impl = TASK_IMPLEMENTATIONS.get(task.key)
			if impl is None:
				print(f"No implementation for task '{task.key}'.")
				continue

			if task.key == "conda":
				impl(runner, options, paths, arch)  # type: ignore[arg-type]
			else:
				impl(runner, options, paths)  # type: ignore[misc]

			completed[task.key] = True
	finally:
		runner.close()

	save_state(args.write_state or state_path, completed)

	summary_lines = [
		"\nRun summary:",
		f"  Context: {context}",
		f"  Tasks requested: {[TASKS[i].key for i in selected_indices]}",
		f"  Tasks completed: {[key for key, done in completed.items() if done]}",
		f"  Log file: {log_path}",
	]
	print("\n".join(summary_lines))
	if options.dry_run:
		print("Next steps: review the log, adjust plan.md as tasks mature, re-run with --force to execute commands.")
	else:
		print("Next steps: review the log and rerun tasks if further adjustments are needed.")
	return 0


if __name__ == "__main__":
	sys.exit(main())

