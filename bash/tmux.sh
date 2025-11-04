
# tmux Quick Reference & Usage Guide

This document provides a quick reference for common `tmux` commands and usage patterns, including session management, window and pane operations, and useful tips for collaborative or advanced workflows.

---

## Starting a Shared tmux Session

To start a new tmux session with a shared socket (useful for collaboration):

```sh
tmux -S /tmp/hossam.shared new-session
chmod 777 /tmp/hossam.shared  # Make the socket accessible to others
```

---

## Session, Window, and Pane Management

- **List all sessions:**
	```sh
	tmux list-sessions
	# or
	tmux ls
	```

- **List all windows in the current session:**
	```sh
	tmux list-windows
	# or
	tmux lsw
	```

- **List all panes in the current window:**
	```sh
	tmux list-panes
	```

- **Split the current pane:**
	```sh
	tmux split-pane
	```

- **Rename the current window:**
	```sh
	tmux rename-window <new-name>
	```

---

## Advanced Operations

- **Capture the contents of a pane:**
	```sh
	tmux capture-pane -p -t <pane-index>
	```

- **Send keys to a pane or window:**
	```sh
	tmux send-keys -t <target-pane> "your command here"
	```

---

## Key Bindings and Help

- **List all key bindings:**
	```sh
	tmux list-keys
	```

- **Open the tmux manual:**
	```sh
	man tmux
	```

---

## Miscellaneous

- **List tmux processes:**
	```sh
	ps uxw -C tmux
	```

---

## Example: Start and Share a tmux Session

```sh
tmux -S /tmp/hossam.shared new-session
chmod 777 /tmp/hossam.shared
# Others can now join with:
tmux -S /tmp/hossam.shared attach
```

---

For more, see the [tmux man page](https://man7.org/linux/man-pages/man1/tmux.1.html) or run `man tmux` in your terminal.
