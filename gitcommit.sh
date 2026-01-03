#!/bin/bash

# Get current date and time for commit message
commit_msg=$(date "+%Y-%m-%d %H:%M:%S")

# Add all changed files to the staging area
git add *

# Commit the changes with the current date-time as the message
git commit -m "$commit_msg"

# Push the changes to the remote repository
git push

