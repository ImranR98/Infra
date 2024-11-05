here() { cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd; }
source "$(here)"/../helpers.sh # TODO: The '../' here and in the next few lines will need to be removed after the files are moved
if [ -f "$(here)"/../VARS.production.sh ]; then
    source "$(here)"/../VARS.production.sh
elif [ -f "$(here)"/../VARS.staging.sh ]; then
    source "$(here)"/../VARS.staging.sh
elif [ -f "$(here)"/../VARS.sh ]; then
    source "$(here)"/../VARS.sh
else
    echo "No VARS.sh file found!" >&2
    exit 1
fi
source "$(here)"/../fixed.VARS.sh