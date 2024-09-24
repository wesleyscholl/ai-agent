#!/bin/zsh
source ~/.bash_profile

# Get the most recent ticket info with the jira rest api
ticket=$(curl -s -u $JIRA_USERNAME:$JIRA_API_TOKEN \
              -H "Accept: application/json" \
              "{$JIRA_BASE_URL}{$JIRA_API_VERSION}/search?jql=assignee=%22{$JIRA_USERNAME}%22+ORDER+BY+created+DESC&maxResults=1")

# Check if the response is empty
if [ -z "$ticket" ]; then
    echo "Error: API request for Jira ticket failed. Please try again."
    exit 1
fi
# Clean up the JSON response
ticket=$(echo "$ticket" | tr -d '\0-\37') 

echo $ticket

# Extract the ticket number from the response
ticket_number=$(echo $ticket | jq -r '.issues[0].key')

echo $ticket_number

# Extract the ticket name from the response
ticket_name=$(echo $ticket | jq -r '.issues[0].fields.summary')

echo $ticket_name

# Extract the ticket description from the response
description=$(echo $ticket | jq -r '.issues[0].fields.description')
acceptance_requirements=$(echo $ticket | jq -r '.issues[0].fields.customfield_12700')
comments=$(echo $ticket | jq -r '.issues[0].fields.comment.comments[] | select(.body != "") | ("- " ) + .body')
# steps_to_reproduce=$(echo $ticket | jq -r '.issues[0].fields.customfield_13380')

echo $description
echo $acceptance_requirements
echo $comments
# echo $steps_to_reproduce

# Prepare the Gemini API request - Combine into a single string - <Ticket Name> - Replace all spaces with dashes and remove all non-alphanumeric characters, limiting to 20 characters cut at the last word, remove all | pipes, remove all spaces first
gemini_request='{
  "contents":[{"parts":[{"text": "Write a valid git branch title (no more than 20 characters total) using this ticket name: '"$ticket_name"' Valid branch names are connected with dashes <branch-name>. The repository name can only contain ASCII letters, digits, and the characters ., -, and _. Do not include any other text in the repsonse."}]}],
  "safetySettings": [{"category": "HARM_CATEGORY_DANGEROUS_CONTENT","threshold": "BLOCK_NONE"}],
  "generationConfig": {
    "temperature": 0.2,
    "maxOutputTokens": 20
  }
}'

# Get branch name from Gemini API
ticket_name_short=$(curl -s \
  -H 'Content-Type: application/json' \
  -d "$gemini_request" \
  -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=${GEMINI_API_KEY}" \
  | jq -r '.candidates[0].content.parts[0].text'
  )

echo $ticket_name_short

# Check if the ticket name is empty
if [ -z "$ticket_name_short" ]; then
    echo "Error: API request for branch name failed. Please try again."
    exit 1
fi

# Combine the ticket number and ticket name into a single string - <Ticket Number>-<Ticket Name>
branch_name="$ticket_number-$ticket_name_short"

echo $branch_name

# Create a new branch using the shortened ticket name
git checkout -b $branch_name

# Set branch upstream to origin/$branch_name
git branch --set-upstream-to $branch_name origin/$branch_name

# Push the new branch to the remote repository
git push -u origin $ticket_name_short


# Get the current full git repo context inluding all file contents
# repo_data=""

# for file in $(git ls-tree -r --name-only HEAD); do
#     repo_data="$repo_data"  # Append to the existing variable
#     repo_data="$repo_data"File: $file\n"  
#     repo_data="$repo_data"$(git show HEAD:$file)\n"  # Add file contents
# done

# echo "$repo_data"












# - Parse the ticket description, acceptance criteria, name, other details
# - Clone corresponding repo from ticket - Url could be 2nd argument/parameter
# - Checkout new branch using the name of the ticket, shortened
# - Send ticket details and repo context to LLM API with specific instructions 
# - Specific instructions, to return file names to modify, full code for files to modify (with new code), the response structure needs to be predictable

