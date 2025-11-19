#!/bin/bash

set -euo pipefail

# Usage check
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <JF_GIT_REPO> <GIT_BRANCH>"
    echo "Example: $0 your-org/your-repo main"
    exit 1
fi

JF_GIT_REPO="$1"
GIT_BRANCH="$2"

# Create config directory and file
mkdir -p .frogbot

cat > .frogbot/frogbot-config.yml <<EOF
- params:
    git:
      repoName: "${JF_GIT_REPO}"
      branches:
        - "${GIT_BRANCH}"
EOF

export JF_GIT_REPO
echo "✅ Created .frogbot/frogbot-config.yml"

# Get the latest Frogbot release tag from GitHub
LATEST_VERSION=$(curl -s https://api.github.com/repos/jfrog/frogbot/releases/latest | grep tag_name | cut -d '"' -f 4)

if [[ -z "$LATEST_VERSION" ]]; then
    echo "❌ Failed to fetch latest Frogbot version."
    exit 1
fi

VERSION_NUMBER=${LATEST_VERSION#v}
echo "✅ Latest Frogbot version: $VERSION_NUMBER"

# Download and run Frogbot
curl -fLg "https://releases.jfrog.io/artifactory/frogbot/v2/${VERSION_NUMBER}/getFrogbot.sh" | sh

# Run the scan
./frogbot scan-repository