# Fails on first 3 attempts, succeeds on 4th
# Achieved by persisting a tmp file in ./tmp/
# Called by 2.json workflow
echo "Script 2.sh started"
TMP_DIR="./tmp"
TMP_FILE="$TMP_DIR/attempt_count.txt"
mkdir -p $TMP_DIR
if [ ! -f $TMP_FILE ]; then
    echo "Running first attempt"
    echo "0" > $TMP_FILE
    exit 1
fi
ATTEMPT_COUNT=$(cat $TMP_FILE)
if [ "$ATTEMPT_COUNT" -lt 3 ]; then
    ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
    echo "Failing attempt $ATTEMPT_COUNT"
    echo "$ATTEMPT_COUNT" > $TMP_FILE
    exit 1
else
    echo "Running attempt 4 - Success!"
    rm $TMP_FILE
    rm -rf $TMP_DIR
    exit 0
fi
