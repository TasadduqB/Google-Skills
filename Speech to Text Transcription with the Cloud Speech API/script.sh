# 1. Export your API Key
export API_KEY="key"

# --- TASK 2 & 3: English Transcription ---
echo "Processing English Transcription..."

# Create request.json for English
cat <<EOF > request.json
{
  "config": {
      "encoding":"FLAC",
      "languageCode": "en-US"
  },
  "audio": {
      "uri":"gs://cloud-samples-data/speech/brooklyn_bridge.flac"
  }
}
EOF

# Call API and save to result.json
curl -s -X POST -H "Content-Type: application/json" --data-binary @request.json \
"https://speech.googleapis.com/v1/speech:recognize?key=${API_KEY}" > result.json

# Print English Result
cat result.json
echo "--------------------------------------"

# --- TASK 4: French Transcription ---
echo "Processing French Transcription..."

# Update request.json for French
cat <<EOF > request.json
 {
  "config": {
      "encoding":"FLAC",
      "languageCode": "fr"
  },
  "audio": {
      "uri":"gs://cloud-samples-data/speech/corbeau_renard.flac"
  }
}
EOF

# Call API and overwrite result.json (Required for the final check)
curl -s -X POST -H "Content-Type: application/json" --data-binary @request.json \
"https://speech.googleapis.com/v1/speech:recognize?key=${API_KEY}" > result.json

# Print French Result
cat result.json
echo "--------------------------------------"
echo "Lab Completed. You can now verify all progress."
