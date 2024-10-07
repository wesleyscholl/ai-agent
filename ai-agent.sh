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
description=$(echo $ticket | jq -r '.issues[0].fields.description.content[0].content[0].text')
acceptance_requirements=$(echo $ticket | jq -r '.issues[0].fields.customfield_12700.content[0].content[0].text')
# comments=$(echo $ticket | jq -r '.issues[0].fields.comment.comments[] | select(.body != "") | ("- " ) + .body')
# steps_to_reproduce=$(echo $ticket | jq -r '.issues[0].fields.customfield_13380')

echo $description
echo $acceptance_requirements
# echo $comments
# echo $steps_to_reproduce

# Prepare the Gemini API request to generate a branch name
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

# Trim whitespace from the ticket name
ticket_name_short=$(echo $ticket_name_short | tr -d '[:space:]')

# Combine the ticket number and ticket name into a single string - <Ticket Number>-<Ticket Name>
branch_name="$ticket_number-$ticket_name_short"

echo $branch_name

# Create a new branch using the shortened ticket name
git checkout -b $branch_name

# Push the new branch to the remote repository
git push --set-upstream origin $branch_name

# Update ticket status to "In Progress"
curl -X POST \
  --url "{$JIRA_BASE_URL}{$JIRA_API_VERSION}/issue/{$ticket_number}/transitions" \
  --user $JIRA_USERNAME:$JIRA_API_TOKEN \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{"transition":{"id":"11"}}'
  
# Get the repo context
repo_context=$(git ls-tree -r --name-only HEAD | while read file; do echo "\"$file\": \"$(git show HEAD:$file)\""; done | paste -sd, -)

# Encode the repo context using base64
repo_context_encoded=$(echo "$repo_context" | base64)

# Construct the request body
request_body='{
  "contents": [{"parts": [{"text": "'"$repo_context_encoded"' "}]}]
}'

# Upload the repo context using the POST method
response=$(curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d "$request_body" \
  "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=${GEMINI_API_KEY}"
)

# Extract the cached content ID from the response
cached_content_id=$(echo "$response" | jq -r '.name')

# echo $repo_data

# Send the repo context, ticket information, and prompt to the LLM API with specific instructions
gemini_prompt='{
  "tools": [{"code_execution": {}}],
  "contents":[{"parts": [{"text": "Using the ticket name, description, acceptance requirements, and repo data send git changes (with file names) to complete the Jira ticket in a structured JSON format. For each file, provide the file path (filepath), a diff that represents the changes, and the updated_content for the entire file. Escape all potentially problematic characters. Respond in this format: changes: [{file1.py: {filepath: file1.py, diff: git diff, updated_content: updates}, file2.txt: {filepath: file2.txt, diff: git diff, updated_content: updates}}]. -- Ticket name: '"$ticket_name"' -- Ticket Description: '"$description"' -- Acceptance Requirements: '"$acceptance_requirements"' -- Repo Context: '"$cached_content_id"' -- Do not include any other text in the repsonse."}]}],
  "safetySettings": [{"category": "HARM_CATEGORY_DANGEROUS_CONTENT","threshold": "BLOCK_NONE"}]
}'

# Get the Gemini API changes response
response=$(curl -s \
  -H 'Content-Type: application/json' \
  -d $gemini_prompt \
  -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=${GEMINI_API_KEY}"
  )

echo $response

# Check if the response is empty
if [ -z "$response" ]; then
    echo "Error: Gemini API request failed. Please try again."
    exit 1
fi

# Check if the response contains the expected structure - 'changes' key with file names as sub-keys
if [ -z $(echo $response | jq -r '.candidates[0].content.parts[0].text | fromjson | .changes') ]; then
    echo "Error: Gemini API response does not contain the expected structure. Please try again."
    exit 1
else
    # for each object within changes, check for keys and values: 'filepath', 'diff', and 'updated_content'
    for file in $(echo $response | jq -r '.candidates[0].content.parts[0].text | fromjson | .changes | keys[]'); do
        if [ -z $(echo $response | jq -r ".candidates[0].content.parts[0].text | fromjson | .changes | .$file | .filepath") ] || 
           [ -z $(echo $response | jq -r ".candidates[0].content.parts[0].text | fromjson | .changes | .$file | .diff") ] || 
           [ -z $(echo $response | jq -r ".candidates[0].content.parts[0].text | fromjson | .changes | .$file | .updated_content") ]; then
            echo "Error: Gemini API response does not contain the expected structure - filepath, diff and updated_content. Please try again."
            exit 1
        fi
    done
fi

# Parse the response to get the file names, diffs, and updated content
file_names=$(echo $response | jq -r '.candidates[0].content.parts[0].text | fromjson | .changes | keys[]')
file_diffs=$(echo $response | jq -r '.candidates[0].content.parts[0].text | fromjson | .changes | .[] | .diff')
file_contents=$(echo $response | jq -r '.candidates[0].content.parts[0].text | fromjson | .changes | .[] | .updated_content')

echo $file_names
echo $file_diffs
echo $file_contents


# Loop through the files and apply the changes
for file in $file_names; do
    # Get the updated content for the file
    updated_content=$(echo $file_contents | jq -r ".$file.updated_content")

    # Write the updated content to the file
    echo "$updated_content" > $file
done

# Run the git commit push script with the alias 'cm'
cm

# Wait for the changes to be pushed to the remote repository
sleep 5

# Run unit tests to ensure the changes are valid and don't break the codebase
# TODO: Add unit test runner

# # Update ticket status to "Code Review"
curl -X POST \
  --url "{$JIRA_BASE_URL}{$JIRA_API_VERSION}/issue/{$ticket_number}/transitions" \
  --user $JIRA_USERNAME:$JIRA_API_TOKEN \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{"transition":{"id":"71"}}'

# Run the jira pr script with the alias 'pr'
pr main

# Wait for the pull request to be created
sleep 5

echo "Pull request created successfully."
