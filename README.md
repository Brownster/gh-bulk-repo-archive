# gh-bulk-repo-archive
Bulk Archive GH repos

# Save it
nano bulk-archive-repos.sh
# (paste the script)
chmod +x bulk-archive-repos.sh

# Install helper (if needed)
sudo dnf install newt           # for whiptail
# optional fallback:
sudo dnf install fzf

# Run it (24 months default)
./bulk-archive-repos.sh

# Customise (examples):
OWNER=username ./bulk-archive-repos.sh
MONTHS_OLD=18 ./bulk-archive-repos.sh
INCLUDE_FORKS=true ./bulk-archive-repos.sh
DRY_RUN=true ./bulk-archive-repos.sh

