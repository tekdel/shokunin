# Profiles Plan (Future Implementation)

Add ability to **add** personal/work-specific configs from a private repository. Profiles are additive - you can apply both.

## How It Will Work

```
~/projects/shokunin/           # Public repo (core tools)
~/projects/shokunin-private/   # Private repo (personal + work additions)
```

```bash
./profile init git@github.com:user/shokunin-private.git  # Clone private repo
./profile personal    # Add personal stuff (idempotent)
./profile work        # Add work stuff (idempotent)
```

Both can be applied - they accumulate, don't conflict.

## Private Repo Structure

```
shokunin-private/
├── personal/
│   ├── packages.txt         # Personal-only packages
│   └── repos.txt            # Personal private repos to clone
│
└── work/
    ├── packages.txt         # slack-desktop, etc.
    ├── repos.txt            # Work repos → clone to ~/work/
    └── gitconfig            # Work git identity (name, email)
```

## Git Identity

Work git config uses `includeIf` - automatically uses work identity in `~/work/`:

```ini
# Added to ~/.gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
```

## Commands

| Command | Action |
|---------|--------|
| `./profile init <url>` | Clone private repo to ~/projects/shokunin-private |
| `./profile personal` | Add personal packages + clone personal repos |
| `./profile work` | Add work packages + clone work repos + setup git identity |
| `./profile status` | Show what's been applied |
| `./profile update` | Pull latest from private repo |

## Idempotent Behavior

- Packages: `pacman/paru --needed` skips already installed
- Repos: Skip if directory exists
- Git config: Add includeIf only if not present

## Implementation

When ready to implement:
1. Create `profile` script in shokunin root (~100 lines)
2. Add section to README.md about profiles
3. Bump version
