#!/usr/bin/env bash
# Example master startup wrapper. Replace with real UI/API start command.
source /opt/ai-master-venv/bin/activate
cd /opt/ai-ui || exit 1
npm install --no-audit --no-fund
npm run start
