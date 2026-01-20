# 1. Export your API Key
export API_KEY="key"

# Set Region
export REGION=us-central1
gcloud config set compute/region $REGION

# 2. Task 2: Translate Text
echo "--- Translating Text ---"
TEXT="My%20name%20is%20Steve"
curl "https://translation.googleapis.com/language/translate/v2?target=es&key=${API_KEY}&q=${TEXT}"

# 3. Task 3: Detect Language
echo -e "\n\n--- Detecting Languages ---"
TEXT_ONE="Meu%20nome%20é%20Steven"
TEXT_TWO="日本のグーグルのオフィスは、東京の六本木ヒルズにあります"

curl -X POST "https://translation.googleapis.com/language/translate/v2/detect?key=${API_KEY}" \
-d "q=${TEXT_ONE}" \
-d "q=${TEXT_TWO}"

echo -e "\n\n--- Lab Tasks Complete! Check your progress. ---"
